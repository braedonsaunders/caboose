import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// AV1's open bitstream units: the low-overhead format Caboose Display sends, one temporal
/// unit per frame with the sequence header on keyframes.
public enum AV1OBU {
    public static let sequenceHeader: UInt8 = 1
    public static let temporalDelimiter: UInt8 = 2
    public static let padding: UInt8 = 15

    public struct Unit: Equatable {
        public var type: UInt8
        /// The header byte and extension byte, if any, as received.
        public var header: Data
        public var payload: Data

        /// The unit with a size field, as an MP4 sample carries it.
        var sized: Data {
            var out = Data(header)
            out[out.startIndex] |= 0x02 // obu_has_size_field
            out.append(AV1OBU.leb128(payload.count))
            out.append(payload)
            return out
        }
    }

    public enum Failure: Error, Equatable {
        case truncated
        case forbiddenBit
    }

    public static func units(in data: Data) throws -> [Unit] {
        let bytes = [UInt8](data)
        var units: [Unit] = []
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            guard first & 0x80 == 0 else { throw Failure.forbiddenBit }
            let type = (first >> 3) & 0x0F
            let hasExtension = first & 0x04 != 0, hasSize = first & 0x02 != 0
            let headerLength = hasExtension ? 2 : 1
            guard index + headerLength <= bytes.count else { throw Failure.truncated }
            let header = Data(bytes[index ..< index + headerLength])
            index += headerLength
            let size: Int
            if hasSize {
                var value = 0, shift = 0
                while true {
                    guard index < bytes.count, shift < 56 else { throw Failure.truncated }
                    let byte = bytes[index]
                    index += 1
                    value |= Int(byte & 0x7F) << shift
                    shift += 7
                    if byte & 0x80 == 0 { break }
                }
                size = value
            } else {
                size = bytes.count - index
            }
            guard size >= 0, index + size <= bytes.count else { throw Failure.truncated }
            units.append(Unit(type: type, header: header, payload: Data(bytes[index ..< index + size])))
            index += size
        }
        return units
    }

    static func leb128(_ value: Int) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}

/// What the `av1C` box needs from an AV1 sequence header (AV1 spec §5.5).
public struct AV1SequenceHeader: Equatable {
    public var profile: Int
    public var level: Int
    public var tier: Int
    public var highBitDepth: Bool
    public var twelveBit: Bool
    public var monochrome: Bool
    public var subsamplingX: Bool
    public var subsamplingY: Bool
    public var chromaSamplePosition: Int
    public var maxWidth: Int
    public var maxHeight: Int
    public var fullRange: Bool
    /// H.273 colour description: primaries, transfer characteristics, matrix (2 = unspecified).
    public var colorPrimaries: Int
    public var transferCharacteristics: Int
    public var matrixCoefficients: Int

    public enum Failure: Error { case truncated }

    public init(_ payload: Data) throws {
        var bits = BitReader(payload)
        profile = try bits.read(3)
        _ = try bits.read(1) // still_picture
        let reduced = try bits.read(1) == 1
        if reduced {
            level = try bits.read(5)
            tier = 0
        } else {
            var decoderModelInfo = false
            var bufferDelayLength = 0
            if try bits.read(1) == 1 { // timing_info_present_flag
                _ = try bits.read(32) // num_units_in_display_tick
                _ = try bits.read(32) // time_scale
                if try bits.read(1) == 1 { _ = try bits.uvlc() } // equal_picture_interval
                decoderModelInfo = try bits.read(1) == 1
                if decoderModelInfo {
                    bufferDelayLength = try bits.read(5) + 1
                    _ = try bits.read(32) // num_units_in_decoding_tick
                    _ = try bits.read(5) // buffer_removal_time_length_minus_1
                    _ = try bits.read(5) // frame_presentation_time_length_minus_1
                }
            }
            let initialDisplayDelay = try bits.read(1) == 1
            let operatingPoints = try bits.read(5) + 1
            var firstLevel = 0, firstTier = 0
            for point in 0 ..< operatingPoints {
                _ = try bits.read(12) // operating_point_idc
                let level = try bits.read(5)
                let tier = level > 7 ? try bits.read(1) : 0
                if point == 0 { firstLevel = level; firstTier = tier }
                if decoderModelInfo, try bits.read(1) == 1 {
                    _ = try bits.read(bufferDelayLength) // decoder_buffer_delay
                    _ = try bits.read(bufferDelayLength) // encoder_buffer_delay
                    _ = try bits.read(1) // low_delay_mode_flag
                }
                if initialDisplayDelay, try bits.read(1) == 1 { _ = try bits.read(4) }
            }
            level = firstLevel
            tier = firstTier
        }
        let widthBits = try bits.read(4) + 1, heightBits = try bits.read(4) + 1
        maxWidth = try bits.read(widthBits) + 1
        maxHeight = try bits.read(heightBits) + 1
        if !reduced, try bits.read(1) == 1 { // frame_id_numbers_present_flag
            _ = try bits.read(4)
            _ = try bits.read(3)
        }
        _ = try bits.read(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
        if !reduced {
            _ = try bits.read(4) // interintra, masked compound, warped motion, dual filter
            let orderHint = try bits.read(1) == 1
            if orderHint { _ = try bits.read(2) } // jnt_comp, ref_frame_mvs
            let forceScreenContentTools = try bits.read(1) == 1 ? 2 : try bits.read(1) // seq_choose_screen_content_tools
            if forceScreenContentTools > 0, try bits.read(1) == 0 { _ = try bits.read(1) } // integer mv
            if orderHint { _ = try bits.read(3) }
        }
        _ = try bits.read(3) // superres, cdef, restoration
        // color_config
        highBitDepth = try bits.read(1) == 1
        twelveBit = profile == 2 && highBitDepth ? try bits.read(1) == 1 : false
        monochrome = profile == 1 ? false : try bits.read(1) == 1
        var primaries = 2, transfer = 2, matrix = 2
        if try bits.read(1) == 1 {
            primaries = try bits.read(8)
            transfer = try bits.read(8)
            matrix = try bits.read(8)
        }
        colorPrimaries = primaries
        transferCharacteristics = transfer
        matrixCoefficients = matrix
        chromaSamplePosition = 0
        if monochrome {
            fullRange = try bits.read(1) == 1
            subsamplingX = true
            subsamplingY = true
        } else if primaries == 1, transfer == 13, matrix == 0 { // sRGB, 4:4:4
            fullRange = true
            subsamplingX = false
            subsamplingY = false
        } else {
            fullRange = try bits.read(1) == 1
            switch profile {
            case 0: subsamplingX = true; subsamplingY = true
            case 1: subsamplingX = false; subsamplingY = false
            default:
                if twelveBit {
                    subsamplingX = try bits.read(1) == 1
                    subsamplingY = subsamplingX ? try bits.read(1) == 1 : false
                } else {
                    subsamplingX = true
                    subsamplingY = false
                }
            }
            if subsamplingX, subsamplingY { chromaSamplePosition = try bits.read(2) }
        }
    }

    /// The `av1C` codec configuration record, with the sequence header OBU as its config OBU.
    public func configurationRecord(sequenceHeader obu: Data) -> Data {
        var out = Data([0x81, UInt8(profile << 5 | level & 0x1F)])
        var flags = UInt8(tier << 7)
        if highBitDepth { flags |= 0x40 }
        if twelveBit { flags |= 0x20 }
        if monochrome { flags |= 0x10 }
        if subsamplingX { flags |= 0x08 }
        if subsamplingY { flags |= 0x04 }
        flags |= UInt8(chromaSamplePosition & 0x03)
        out.append(flags)
        out.append(0) // no initial_presentation_delay
        out.append(obu)
        return out
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func read(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0 ..< count {
            guard position < bytes.count * 8 else { throw AV1SequenceHeader.Failure.truncated }
            let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            value = value << 1 | Int(bit)
            position += 1
        }
        return value
    }

    mutating func uvlc() throws -> Int {
        var leadingZeros = 0
        while try read(1) == 0 {
            leadingZeros += 1
            if leadingZeros >= 32 { return Int(UInt32.max) }
        }
        return try read(leadingZeros) + (1 << leadingZeros) - 1
    }
}

/// Decodes one window's AV1 stream in hardware, where the device has an AV1 decoder (A17 Pro,
/// M3 and later). The session is rebuilt whenever the sequence header changes.
public final class AV1Decoder: PictureDecoder {
    private var session: VTDecompressionSession?
    private let bitstream = OBUFormatter()

    /// Whether this device decodes AV1 in hardware; the client offers AV1 only then.
    public static var isSupported: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    public init() {}

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    public func decode(_ temporalUnit: Data) throws -> CVPixelBuffer? {
        let (bytes, changed) = try bitstream.sample(from: temporalUnit)
        guard let format = bitstream.format else { throw H264DecoderError.noParameterSets }
        if changed || session == nil {
            invalidate()
            session = try VideoToolboxSession.make(format)
        }
        guard let bytes, let session else { return nil }
        let buffer = try VideoToolboxSession.sampleBuffer(bytes, format: format)
        return try VideoToolboxSession.decode(buffer, in: session) { invalidate() }
    }
}
