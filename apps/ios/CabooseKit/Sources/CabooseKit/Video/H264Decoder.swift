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

/// Decodes one window's H.264 or HEVC stream into IOSurface-backed BGRA pixel buffers that
/// Metal can sample without a copy. Xpra is asked for no B-frames, so output order is
/// decode order and every frame is displayed as soon as it decodes. HEVC is what a GPU
/// encoder sends at 4K (Xpra's NVENC H.264 path stops at level 5.0, below 4K frame sizes).
public final class H264Decoder {
    public let codec: VideoCodec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    public init(codec: VideoCodec = .h264) { self.codec = codec }

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    /// Decodes one access unit synchronously and returns the picture it produced, if any.
    public func decode(_ accessUnit: Data) throws -> CVPixelBuffer? {
        var vcl: [Data] = []
        var parametersChanged = false
        for unit in AnnexB.nalUnits(in: accessUnit) {
            switch codec {
            case .h264:
                switch AnnexB.type(of: unit) {
                case 7: if unit != sps { sps = unit; parametersChanged = true }
                case 8: if unit != pps { pps = unit; parametersChanged = true }
                case 1, 5: vcl.append(unit)
                default: continue // SEI, AUD and filler carry nothing the decoder needs here.
                }
            case .hevc:
                switch AnnexB.hevcType(of: unit) {
                case 32: if unit != vps { vps = unit; parametersChanged = true }
                case 33: if unit != sps { sps = unit; parametersChanged = true }
                case 34: if unit != pps { pps = unit; parametersChanged = true }
                case 0 ... 31: vcl.append(unit)
                default: continue
                }
            }
        }
        if parametersChanged || session == nil { try rebuildSession() }
        guard !vcl.isEmpty, let session, let format else { return nil }

        var avcc = Data()
        for unit in vcl {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        let sample = try makeSampleBuffer(avcc, format: format)
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

    private func rebuildSession() throws {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps, let pps else { throw H264DecoderError.noParameterSets }
            sets = [sps, pps]
        case .hevc:
            guard let vps, let sps, let pps else { throw H264DecoderError.noParameterSets }
            sets = [vps, sps, pps]
        }
        invalidate()
        var description: CMFormatDescription?
        let copies = sets.map { [UInt8]($0) }
        let status = copies.withPointers { pointers in
            let sizes = copies.map(\.count)
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw H264DecoderError.formatDescription(status) }
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
        format = description
        session = created
    }

    private func makeSampleBuffer(_ avcc: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw H264DecoderError.sampleBuffer(status) }
        status = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard status == noErr else { throw H264DecoderError.sampleBuffer(status) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw H264DecoderError.sampleBuffer(status) }
        return sample
    }
}

private extension Array where Element == [UInt8] {
    /// Calls `body` with a stable pointer to each array's bytes.
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func nest(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> R {
            guard index < count else { return body(pointers) }
            return self[index].withUnsafeBufferPointer { nest(index + 1, pointers + [$0.baseAddress!]) }
        }
        return nest(0, [])
    }
}
