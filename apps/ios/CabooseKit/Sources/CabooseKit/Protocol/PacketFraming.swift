import Foundation

/// One Xpra packet: a type name and its positional arguments.
public struct XpraPacket: Equatable, Sendable {
    public var type: String
    public var arguments: [RValue]

    public init(_ type: String, _ arguments: [RValue] = []) {
        self.type = type
        self.arguments = arguments
    }

    public subscript(index: Int) -> RValue? {
        arguments.indices.contains(index) ? arguments[index] : nil
    }
}

public enum PacketFramingError: Error, Equatable {
    case badMagic(UInt8)
    case unsupportedFlags(UInt8)
    case compressed(level: UInt8)
    case oversized(Int)
    case notAPacket
    case chunkOutOfRange(index: Int, count: Int)
}

/// Xpra's 8-byte packet header followed by the payload:
///
///     'P' | protocol flags | compression | chunk index | payload size (UInt32, big-endian)
///
/// A packet with large binary arguments is sent as raw chunks (index > 0, the bytes of
/// argument `index`) followed by the main rencoded packet (index 0) in which those
/// arguments are placeholders. Caboose asks the server for no compression, so a
/// compressed packet is a protocol error rather than something to decode.
public enum PacketFraming {
    public static let headerSize = 8
    public static let magic = UInt8(ascii: "P")
    public static let flagRencodePlus: UInt8 = 0x10
    public static let flagFlush: UInt8 = 0x08
    public static let maxPayload = 256 * 1024 * 1024

    public static func encode(_ packet: XpraPacket) -> Data {
        let payload = Rencode.encode(.list([RValue(packet.type)] + packet.arguments))
        var out = Data(capacity: headerSize + payload.count)
        out.append(magic)
        out.append(flagRencodePlus)
        out.append(0) // no compression
        out.append(0) // main packet
        Rencode.appendBigEndian(UInt32(payload.count), into: &out)
        out.append(payload)
        return out
    }
}

/// Incremental parser for a byte stream of framed packets. WebSocket message
/// boundaries carry no meaning in Xpra, so bytes are accumulated and split here.
public struct PacketParser {
    private var buffer = Data()
    private var chunks: [Int: Data] = [:]

    public init() {}

    public mutating func append(_ data: Data) throws -> [XpraPacket] {
        buffer.append(data)
        var packets: [XpraPacket] = []
        while buffer.count >= PacketFraming.headerSize {
            let header = [UInt8](buffer.prefix(PacketFraming.headerSize))
            guard header[0] == PacketFraming.magic else { throw PacketFramingError.badMagic(header[0]) }
            let flags = header[1]
            let compression = header[2]
            let index = Int(header[3])
            let size = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
            guard size <= PacketFraming.maxPayload else { throw PacketFramingError.oversized(size) }
            guard buffer.count >= PacketFraming.headerSize + size else { break }
            let start = buffer.startIndex + PacketFraming.headerSize
            let payload = Data(buffer[start ..< start + size])
            buffer.removeSubrange(buffer.startIndex ..< start + size)
            guard compression == 0 else { throw PacketFramingError.compressed(level: compression) }
            if index > 0 {
                chunks[index] = payload
                continue
            }
            guard flags & ~PacketFraming.flagFlush == PacketFraming.flagRencodePlus else {
                throw PacketFramingError.unsupportedFlags(flags)
            }
            guard case .list(var items) = try Rencode.decode(payload), let type = items.first?.string else {
                throw PacketFramingError.notAPacket
            }
            for (chunkIndex, chunk) in chunks {
                guard chunkIndex < items.count else {
                    throw PacketFramingError.chunkOutOfRange(index: chunkIndex, count: items.count)
                }
                items[chunkIndex] = .bytes(chunk)
            }
            chunks.removeAll(keepingCapacity: true)
            packets.append(XpraPacket(type, Array(items.dropFirst())))
        }
        return packets
    }
}
