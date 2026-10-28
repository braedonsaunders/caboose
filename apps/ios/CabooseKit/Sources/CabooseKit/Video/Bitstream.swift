import CoreMedia
import CoreVideo
import Foundation

/// One codec's in-band bitstream as Core Media takes it: a format description, rebuilt when
/// the parameters in the stream change, and each access unit as an MP4-style sample. Window
/// decoders and video layers both read streams through these.
public protocol BitstreamFormatter: AnyObject {
    /// The format from the latest parameter sets or sequence header, once the stream has had them.
    var format: CMVideoFormatDescription? { get }
    /// One access unit: the sample bytes (nil when it carries no picture) and whether the
    /// format changed with it.
    func sample(from accessUnit: Data) throws -> (bytes: Data?, formatChanged: Bool)
}

/// H.264 and HEVC in Annex-B: parameter sets in-band, pictures re-framed with 4-byte lengths.
public final class NALFormatter: BitstreamFormatter {
    public let codec: VideoCodec
    public private(set) var format: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    public init(codec: VideoCodec) { self.codec = codec }

    public func sample(from accessUnit: Data) throws -> (bytes: Data?, formatChanged: Bool) {
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
        if parametersChanged { try rebuildFormat() }
        guard !vcl.isEmpty else { return (nil, parametersChanged) }
        var avcc = Data()
        for unit in vcl {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        return (avcc, parametersChanged)
    }

    private func rebuildFormat() throws {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps, let pps else { return } // the rest arrives with the next unit
            sets = [sps, pps]
        case .hevc:
            guard let vps, let sps, let pps else { return }
            sets = [vps, sps, pps]
        }
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
        format = description
    }
}

/// AV1 temporal units: the sequence header becomes the `av1C` configuration (with its colour
/// description, so HDR is tagged), and every OBU is re-framed with a size field.
public final class OBUFormatter: BitstreamFormatter {
    public private(set) var format: CMVideoFormatDescription?
    public private(set) var sequence: AV1SequenceHeader?
    private var sequenceHeader: Data?

    public init() {}

    public func sample(from temporalUnit: Data) throws -> (bytes: Data?, formatChanged: Bool) {
        var sample = Data()
        var changed = false
        for unit in try AV1OBU.units(in: temporalUnit) {
            switch unit.type {
            case AV1OBU.temporalDelimiter, AV1OBU.padding:
                continue // an MP4 sample carries neither
            case AV1OBU.sequenceHeader:
                let sized = unit.sized
                if sized != sequenceHeader {
                    let header = try AV1SequenceHeader(unit.payload)
                    format = try Self.format(header, obu: sized)
                    sequence = header
                    sequenceHeader = sized
                    changed = true
                }
                sample.append(sized)
            default:
                sample.append(unit.sized)
            }
        }
        return (sample.isEmpty ? nil : sample, changed)
    }

    static func format(_ header: AV1SequenceHeader, obu: Data) throws -> CMVideoFormatDescription {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": header.configurationRecord(sequenceHeader: obu)] as CFDictionary,
            kCMFormatDescriptionExtension_FullRangeVideo: header.fullRange,
        ]
        if let primaries = CVColorPrimariesGetStringForIntegerCodePoint(Int32(header.colorPrimaries))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = CVTransferFunctionGetStringForIntegerCodePoint(Int32(header.transferCharacteristics))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(header.matrixCoefficients))?.takeUnretainedValue() {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
            width: Int32(header.maxWidth), height: Int32(header.maxHeight),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw H264DecoderError.formatDescription(status) }
        return description
    }
}

extension Array where Element == [UInt8] {
    /// Calls `body` with a stable pointer to each array's bytes.
    func withPointers<R>(_ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func nest(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> R {
            guard index < count else { return body(pointers) }
            return self[index].withUnsafeBufferPointer { nest(index + 1, pointers + [$0.baseAddress!]) }
        }
        return nest(0, [])
    }
}
