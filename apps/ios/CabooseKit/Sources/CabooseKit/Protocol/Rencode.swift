import Foundation

/// A value in Xpra's `rencodeplus` serialisation.
///
/// rencodeplus keeps text and binary apart on the wire: UTF-8 text uses the fixed
/// short form or `<length>:`, byte arrays always use `<length>/` followed by raw bytes.
public indirect enum RValue: Equatable, Sendable {
    case int(Int64)
    /// An integer too large for 64 bits, kept as its decimal text.
    case bigInt(String)
    case float(Double)
    case bool(Bool)
    case none
    case string(String)
    case bytes(Data)
    case list([RValue])
    case dict([RPair])

    public init(_ string: String) { self = .string(string) }
}

public struct RPair: Equatable, Sendable {
    public var key: RValue
    public var value: RValue
    public init(_ key: RValue, _ value: RValue) {
        self.key = key
        self.value = value
    }
}

extension RValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self.init(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(arrayLiteral elements: RValue...) { self = .list(elements) }
    public init(dictionaryLiteral elements: (String, RValue)...) {
        self = .dict(elements.map { RPair(RValue($0.0), $0.1) })
    }
    public init(nilLiteral: ()) { self = .none }
}

public extension RValue {
    var string: String? {
        switch self {
        case .string(let text): return text
        case .bytes(let data): return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .bytes(let data): return data
        case .string(let text): return Data(text.utf8)
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .bool(let value): return value ? 1 : 0
        case .float(let value): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .float(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        default: return nil
        }
    }

    var list: [RValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var pairs: [RPair]? {
        if case .dict(let pairs) = self { return pairs }
        return nil
    }

    /// Dictionary lookup by text key; Xpra dictionaries are keyed by strings.
    subscript(key: String) -> RValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.key.string == key }?.value
    }

    subscript(index: Int) -> RValue? {
        guard case .list(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The dictionary as `[String: RValue]`, dropping non-text keys.
    var stringKeyed: [String: RValue] {
        var result: [String: RValue] = [:]
        for pair in pairs ?? [] {
            if let key = pair.key.string { result[key] = pair.value }
        }
        return result
    }
}

public enum RencodeError: Error, Equatable {
    case truncated
    case invalidTypeCode(UInt8, offset: Int)
    case invalidLength(offset: Int)
    case invalidInteger(offset: Int)
    case trailingBytes(Int)
}

/// The rencode wire format as used by Xpra's `rencodeplus` (big-endian, float64 by default).
public enum Rencode {
    static let chrList: UInt8 = 59
    static let chrDict: UInt8 = 60
    static let chrInt: UInt8 = 61
    static let chrInt1: UInt8 = 62
    static let chrInt2: UInt8 = 63
    static let chrInt4: UInt8 = 64
    static let chrInt8: UInt8 = 65
    static let chrFloat32: UInt8 = 66
    static let chrFloat64: UInt8 = 44
    static let chrTrue: UInt8 = 67
    static let chrFalse: UInt8 = 68
    static let chrNone: UInt8 = 69
    static let chrTerm: UInt8 = 127
    static let intPosFixedCount: UInt8 = 44
    static let intNegFixedStart: UInt8 = 70
    static let intNegFixedCount: UInt8 = 32
    static let dictFixedStart: UInt8 = 102
    static let dictFixedCount: UInt8 = 25
    static let strFixedStart: UInt8 = 128
    static let strFixedCount: UInt8 = 64
    static let listFixedStart: UInt8 = 192
    static let listFixedCount: UInt8 = 64

    // MARK: Encoding

    public static func encode(_ value: RValue) -> Data {
        var out = Data()
        out.reserveCapacity(256)
        encode(value, into: &out)
        return out
    }

    static func encode(_ value: RValue, into out: inout Data) {
        switch value {
        case .int(let x): encodeInt(x, into: &out)
        case .bigInt(let text):
            out.append(chrInt)
            out.append(contentsOf: text.utf8)
            out.append(chrTerm)
        case .float(let x):
            out.append(chrFloat64)
            appendBigEndian(x.bitPattern, into: &out)
        case .bool(let x): out.append(x ? chrTrue : chrFalse)
        case .none: out.append(chrNone)
        case .string(let text):
            let utf8 = Data(text.utf8)
            if utf8.count < Int(strFixedCount) {
                out.append(strFixedStart + UInt8(utf8.count))
            } else {
                out.append(contentsOf: String(utf8.count).utf8)
                out.append(UInt8(ascii: ":"))
            }
            out.append(utf8)
        case .bytes(let data):
            out.append(contentsOf: String(data.count).utf8)
            out.append(UInt8(ascii: "/"))
            out.append(data)
        case .list(let items):
            if items.count < Int(listFixedCount) {
                out.append(listFixedStart + UInt8(items.count))
                for item in items { encode(item, into: &out) }
            } else {
                out.append(chrList)
                for item in items { encode(item, into: &out) }
                out.append(chrTerm)
            }
        case .dict(let pairs):
            if pairs.count < Int(dictFixedCount) {
                out.append(dictFixedStart + UInt8(pairs.count))
            } else {
                out.append(chrDict)
            }
            for pair in pairs {
                encode(pair.key, into: &out)
                encode(pair.value, into: &out)
            }
            if pairs.count >= Int(dictFixedCount) { out.append(chrTerm) }
        }
    }

    static func encodeInt(_ x: Int64, into out: inout Data) {
        if x >= 0 && x < Int64(intPosFixedCount) {
            out.append(UInt8(x))
        } else if x < 0 && x >= -Int64(intNegFixedCount) {
            out.append(UInt8(Int64(intNegFixedStart) - 1 - x))
        } else if x >= Int64(Int8.min) && x <= Int64(Int8.max) {
            out.append(chrInt1)
            out.append(UInt8(bitPattern: Int8(x)))
        } else if x >= Int64(Int16.min) && x <= Int64(Int16.max) {
            out.append(chrInt2)
            appendBigEndian(UInt16(bitPattern: Int16(x)), into: &out)
        } else if x >= Int64(Int32.min) && x <= Int64(Int32.max) {
            out.append(chrInt4)
            appendBigEndian(UInt32(bitPattern: Int32(x)), into: &out)
        } else {
            out.append(chrInt8)
            appendBigEndian(UInt64(bitPattern: x), into: &out)
        }
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ value: T, into out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> RValue {
        var reader = Reader(bytes: [UInt8](data))
        let value = try reader.value()
        if reader.offset != reader.bytes.count { throw RencodeError.trailingBytes(reader.bytes.count - reader.offset) }
        return value
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw RencodeError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw RencodeError.truncated }
            defer { offset += count }
            return bytes[offset ..< offset + count]
        }

        mutating func bigEndian<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let slice = try take(MemoryLayout<T>.size)
            return slice.reduce(T.zero) { ($0 << 8) | T($1) }
        }

        mutating func value() throws -> RValue {
            let start = offset
            let code = try byte()
            switch code {
            case 0 ..< intPosFixedCount:
                return .int(Int64(code))
            case chrFloat64:
                return .float(Double(bitPattern: try bigEndian(UInt64.self)))
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                var length = Int(code - UInt8(ascii: "0"))
                var separator: UInt8 = 0
                while true {
                    let next = try byte()
                    if next == UInt8(ascii: ":") || next == UInt8(ascii: "/") { separator = next; break }
                    guard (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(next), length < Int.max / 10 else {
                        throw RencodeError.invalidLength(offset: start)
                    }
                    length = length * 10 + Int(next - UInt8(ascii: "0"))
                }
                let body = Data(try take(length))
                if separator == UInt8(ascii: "/") { return .bytes(body) }
                return try text(body, offset: start)
            case chrList:
                var items: [RValue] = []
                while try peek() != chrTerm { items.append(try value()) }
                offset += 1
                return .list(items)
            case chrDict:
                var pairs: [RPair] = []
                while try peek() != chrTerm {
                    let key = try value()
                    pairs.append(RPair(key, try value()))
                }
                offset += 1
                return .dict(pairs)
            case chrInt:
                var text = ""
                while true {
                    let next = try byte()
                    if next == chrTerm { break }
                    guard next == UInt8(ascii: "-") || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(next) else {
                        throw RencodeError.invalidInteger(offset: start)
                    }
                    text.append(Character(UnicodeScalar(next)))
                }
                if let value = Int64(text) { return .int(value) }
                guard !text.isEmpty else { throw RencodeError.invalidInteger(offset: start) }
                return .bigInt(text)
            case chrInt1: return .int(Int64(Int8(bitPattern: try byte())))
            case chrInt2: return .int(Int64(Int16(bitPattern: try bigEndian(UInt16.self))))
            case chrInt4: return .int(Int64(Int32(bitPattern: try bigEndian(UInt32.self))))
            case chrInt8: return .int(Int64(bitPattern: try bigEndian(UInt64.self)))
            case chrFloat32: return .float(Double(Float(bitPattern: try bigEndian(UInt32.self))))
            case chrTrue: return .bool(true)
            case chrFalse: return .bool(false)
            case chrNone: return .none
            case intNegFixedStart ..< intNegFixedStart + intNegFixedCount:
                return .int(Int64(intNegFixedStart) - 1 - Int64(code))
            case dictFixedStart ..< dictFixedStart + dictFixedCount:
                let count = Int(code - dictFixedStart)
                var pairs: [RPair] = []
                pairs.reserveCapacity(count)
                for _ in 0 ..< count {
                    let key = try value()
                    pairs.append(RPair(key, try value()))
                }
                return .dict(pairs)
            case strFixedStart ..< strFixedStart + strFixedCount:
                return try text(Data(try take(Int(code - strFixedStart))), offset: start)
            case listFixedStart...:
                let count = Int(code - listFixedStart)
                var items: [RValue] = []
                items.reserveCapacity(count)
                for _ in 0 ..< count { items.append(try value()) }
                return .list(items)
            default:
                throw RencodeError.invalidTypeCode(code, offset: start)
            }
        }

        /// Text that is not valid UTF-8 is kept as bytes rather than rejected.
        func text(_ body: Data, offset: Int) throws -> RValue {
            if let text = String(data: body, encoding: .utf8) { return .string(text) }
            return .bytes(body)
        }

        func peek() throws -> UInt8 {
            guard offset < bytes.count else { throw RencodeError.truncated }
            return bytes[offset]
        }
    }
}
