import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum H264DecoderError: Error {
    case noParameterSets
    case formatDescription(OSStatus)
    case session(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)
}

/// Splits an Annex-B byte stream (start-code delimited) into NAL unit payloads.
public enum AnnexB {
    public static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var index = 0
        var start: Int?
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let begin = start {
                    var end = index
                    if end > begin, bytes[end - 1] == 0 { end -= 1 } // four-byte start code
                    if end > begin { units.append(Data(bytes[begin ..< end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let begin = start, begin < bytes.count { units.append(Data(bytes[begin...])) }
        return units
    }

    public static func type(of unit: Data) -> UInt8 { (unit.first ?? 0) & 0x1F }

    /// An HEVC NAL unit's type: six bits after the forbidden bit.
    public static func hevcType(of unit: Data) -> UInt8 { ((unit.first ?? 0) >> 1) & 0x3F }
}

/// The video codecs the client decodes in hardware, by Xpra's encoding names.
public enum VideoCodec: String, Sendable {
    case h264
    case hevc = "h265"
}

/// A per-window hardware video decoder: one access unit in, the picture it produced out.
public protocol PictureDecoder: AnyObject {
    func decode(_ accessUnit: Data) throws -> CVPixelBuffer?
    func invalidate()
}

/// Decodes one window's H.264 or HEVC stream into IOSurface-backed BGRA pixel buffers that
/// Metal can sample without a copy. Xpra is asked for no B-frames, so output order is
/// decode order and every frame is displayed as soon as it decodes. HEVC is what a GPU
/// encoder sends at 4K (Xpra's NVENC H.264 path stops at level 5.0, below 4K frame sizes).
public final class H264Decoder: PictureDecoder {
    public let codec: VideoCodec
    private var session: VTDecompressionSession?
    private let bitstream: NALFormatter

    public init(codec: VideoCodec = .h264) {
        self.codec = codec
        bitstream = NALFormatter(codec: codec)
    }

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// Decodes one access unit synchronously and returns the picture it produced, if any.
    public func decode(_ accessUnit: Data) throws -> CVPixelBuffer? {
        let (bytes, changed) = try bitstream.sample(from: accessUnit)
        if changed || session == nil {
            guard let format = bitstream.format else { throw H264DecoderError.noParameterSets }
            invalidate()
            session = try VideoToolboxSession.make(format)
        }
        guard let bytes, let session, let format = bitstream.format else { return nil }
        let sample = try VideoToolboxSession.sampleBuffer(bytes, format: format)
        return try VideoToolboxSession.decode(sample, in: session) { invalidate() }
    }
}

/// The parts of a VideoToolbox decoder every codec shares: a real-time hardware session
/// whose output Metal samples without a copy, and samples wrapped for it.
enum VideoToolboxSession {
    static func make(_ description: CMVideoFormatDescription) throws -> VTDecompressionSession {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard sessionStatus == noErr, let created else { throw H264DecoderError.session(sessionStatus) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return created
    }

    /// One sample of `bytes`; `timing` stamps it for a player (decoders take it untimed).
    static func sampleBuffer(_ bytes: Data, format: CMVideoFormatDescription, timing: CMSampleTimingInfo? = nil) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw H264DecoderError.sampleBuffer(status) }
        status = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: bytes.count)
        }
        guard status == noErr else { throw H264DecoderError.sampleBuffer(status) }
        var sample: CMSampleBuffer?
        var size = bytes.count
        if var timing {
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample)
        } else {
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &sample)
        }
        guard status == noErr, let sample else { throw H264DecoderError.sampleBuffer(status) }
        return sample
    }

    /// Decodes one sample synchronously; the picture, or nil when the decoder held it back.
    static func decode(_ sample: CMSampleBuffer, in session: VTDecompressionSession, invalidate: () -> Void) throws -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, imageBuffer, _, _ in
            decodeStatus = status
            output = imageBuffer
        }
        guard status == noErr else {
            if status == kVTInvalidSessionErr { invalidate() }
            throw H264DecoderError.decode(status)
        }
        guard decodeStatus == noErr else { throw H264DecoderError.decode(decodeStatus) }
        return output
    }
}
