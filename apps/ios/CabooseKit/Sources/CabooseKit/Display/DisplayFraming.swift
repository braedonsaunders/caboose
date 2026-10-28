import Foundation

/// The Caboose Display Protocol's framing (docs/display.md): a one-byte type, a little-endian
/// u32 length, then that many bytes of payload, which is one canonical CBOR map.
///
/// The host relays bytes, so WebSocket message boundaries carry no meaning: a message may
/// arrive split across several, and one may hold several.
public struct DisplayFrame: Equatable, Sendable {
    public var type: UInt8
    public var body: CBOR

    public init(type: UInt8, body: CBOR) {
        self.type = type
        self.body = body
    }
}

public enum DisplayFraming {
    /// The relay's WebSocket limit; nothing larger is ever sent.
    public static let maximumLength = 16 * 1024 * 1024 - headerLength
    static let headerLength = 5

    public static func encode(_ frame: DisplayFrame) -> Data {
        let payload = frame.body.encoded()
        var out = Data(capacity: headerLength + payload.count)
        out.append(frame.type)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public enum DisplayFramingError: Error, Equatable, LocalizedError {
    case tooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .tooLong(let length): "The computer's display sent a message of \(length) bytes, beyond the protocol's limit."
        }
    }
}

/// Reassembles display messages from a byte stream.
public struct DisplayFrameParser {
    private var buffer = Data()
    /// Messages whose payload was not a CBOR map, skipped.
    public private(set) var dropped = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [DisplayFrame] {
        buffer.append(data)
        var frames: [DisplayFrame] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= DisplayFraming.headerLength {
            let type = buffer[start]
            let length = Int(buffer[start + 1]) | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3]) << 16 | Int(buffer[start + 4]) << 24
            guard length <= DisplayFraming.maximumLength else { throw DisplayFramingError.tooLong(length) }
            let payloadStart = start + DisplayFraming.headerLength
            guard buffer.endIndex - payloadStart >= length else { break }
            let payload = buffer.subdata(in: payloadStart ..< payloadStart + length)
            start = payloadStart + length
            // A known type whose payload does not decode is dropped; the stream goes on.
            guard let body = try? CBOR.decode(payload), case .map = body else {
                dropped += 1
                continue
            }
            frames.append(DisplayFrame(type: type, body: body))
        }
        if start != buffer.startIndex { buffer = buffer.subdata(in: start ..< buffer.endIndex) }
        return frames
    }
}
