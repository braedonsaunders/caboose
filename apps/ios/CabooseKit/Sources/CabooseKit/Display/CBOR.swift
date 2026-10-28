import Foundation

/// A CBOR value (RFC 8949), the metadata format of the Caboose Display Protocol.
///
/// Maps keep their pairs in order; tags are read through. `CBOR.encode` writes the protocol's canonical form —
/// definite lengths, shortest integers, every float as float64, map keys sorted by their
/// encoded bytes — so encoded messages compare byte for byte with the compositor's golden
/// vectors. Decoding accepts any valid key order and number width.
public enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    /// A negative integer, stored as its value (always below zero).
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null
    case undefined
    case double(Double)

    public static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        switch (lhs, rhs) {
        case (.unsigned(let a), .unsigned(let b)): a == b
        case (.negative(let a), .negative(let b)): a == b
        case (.bytes(let a), .bytes(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.map(let a), .map(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null), (.undefined, .undefined): true
        case (.double(let a), .double(let b)): a == b || (a.isNaN && b.isNaN)
        default: false
        }
    }

    // MARK: Reading

    public subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == .text(key) }?.1
    }

    public var int: Int? {
        switch self {
        case .unsigned(let value): value <= UInt64(Int.max) ? Int(value) : nil
        case .negative(let value): Int(value)
        case .double(let value): value.isFinite && value == value.rounded() && abs(value) < 9.0e15 ? Int(value) : nil
        default: nil
        }
    }

    public var uint64: UInt64? {
        switch self {
        case .unsigned(let value): value
        case .double(let value): value >= 0 && value.isFinite && value == value.rounded() && value < 1.8e19 ? UInt64(value) : nil
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let value): value
        case .unsigned(let value): Double(value)
        case .negative(let value): Double(value)
        default: nil
        }
    }

    public var string: String? { if case .text(let value) = self { value } else { nil } }
    public var data: Data? { if case .bytes(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [CBOR]? { if case .array(let value) = self { value } else { nil } }
    public var pairs: [(CBOR, CBOR)]? { if case .map(let value) = self { value } else { nil } }

    /// `[a, b, …]` of integers, e.g. a rect or a size.
    public var ints: [Int]? {
        guard let items = array else { return nil }
        let values = items.compactMap(\.int)
        return values.count == items.count ? values : nil
    }
}

extension CBOR: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self.init(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: CBOR...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, CBOR)...) { self = .map(elements.map { (.text($0.0), $0.1) }) }

    public init(_ value: Int) { self = value < 0 ? .negative(Int64(value)) : .unsigned(UInt64(value)) }
    public init(_ value: UInt64) { self = .unsigned(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: Bool) { self = .bool(value) }
}

public enum CBORError: Error, Equatable, CustomStringConvertible {
    case truncated
    case indefiniteLength
    case invalid(String)
    case tooDeep

    public var description: String {
        switch self {
        case .truncated: "CBOR value is truncated"
        case .indefiniteLength: "indefinite-length CBOR is not used by the protocol"
        case .invalid(let reason): "invalid CBOR: \(reason)"
        case .tooDeep: "CBOR nests too deeply"
        }
    }
}

extension CBOR {
    // MARK: Encoding

    /// The canonical encoding of one value.
    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        switch self {
        case .unsigned(let value):
            Self.head(0, value, into: &out)
        case .negative(let value):
            Self.head(1, UInt64(-(value + 1)), into: &out)
        case .bytes(let value):
            Self.head(2, UInt64(value.count), into: &out)
            out.append(value)
        case .text(let value):
            let utf8 = Data(value.utf8)
            Self.head(3, UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            Self.head(4, UInt64(items.count), into: &out)
            for item in items { item.encode(into: &out) }
        case .map(let pairs):
            Self.head(5, UInt64(pairs.count), into: &out)
            // RFC 8949 §4.2.1: keys sorted by their encoded bytes, bytewise.
            let encoded = pairs.map { ($0.0.encoded(), $0.1) }
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            for (key, value) in encoded {
                out.append(key)
                value.encode(into: &out)
            }
        case .bool(let value):
            out.append(value ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        case .undefined:
            out.append(0xF7)
        case .double(let value):
            out.append(0xFB)
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64, into out: inout Data) {
        let type = major << 5
        switch value {
        case 0 ..< 24:
            out.append(type | UInt8(value))
        case 24 ... 0xFF:
            out.append(type | 24)
            out.append(UInt8(value))
        case 0x100 ... 0xFFFF:
            out.append(type | 25)
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xFF))
        case 0x10000 ... 0xFFFF_FFFF:
            out.append(type | 26)
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        default:
            out.append(type | 27)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        }
    }

    // MARK: Decoding

    /// Decodes exactly one value that fills `data`.
    public static func decode(_ data: Data) throws -> CBOR {
        var reader = CBORReader(data)
        let value = try reader.value(depth: 0)
        guard reader.atEnd else { throw CBORError.invalid("\(reader.remaining) trailing bytes") }
        return value
    }
}

struct CBORReader {
    private let bytes: Data
    private var offset: Int
    static let maximumDepth = 32

    init(_ data: Data) {
        bytes = data
        offset = data.startIndex
    }

    var atEnd: Bool { offset == bytes.endIndex }
    var remaining: Int { bytes.endIndex - offset }

    private mutating func byte() throws -> UInt8 {
        guard offset < bytes.endIndex else { throw CBORError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw CBORError.truncated }
        defer { offset += count }
        return bytes.subdata(in: offset ..< offset + count)
    }

    private mutating func big(_ width: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0 ..< width { value = value << 8 | UInt64(try byte()) }
        return value
    }

    private mutating func argument(_ info: UInt8) throws -> UInt64 {
        switch info {
        case 0 ..< 24: UInt64(info)
        case 24: try big(1)
        case 25: try big(2)
        case 26: try big(4)
        case 27: try big(8)
        case 31: throw CBORError.indefiniteLength
        default: throw CBORError.invalid("reserved additional info \(info)")
        }
    }

    private mutating func length(_ info: UInt8) throws -> Int {
        let value = try argument(info)
        guard value <= UInt64(remaining) else { throw CBORError.truncated }
        return Int(value)
    }

    mutating func value(depth: Int) throws -> CBOR {
        guard depth < Self.maximumDepth else { throw CBORError.tooDeep }
        let initial = try byte()
        let major = initial >> 5, info = initial & 0x1F
        switch major {
        case 0:
            return .unsigned(try argument(info))
        case 1:
            let value = try argument(info)
            guard value < UInt64(Int64.max) else { throw CBORError.invalid("negative integer out of range") }
            return .negative(-1 - Int64(value))
        case 2:
            return .bytes(try take(try length(info)))
        case 3:
            guard let text = String(data: try take(try length(info)), encoding: .utf8) else {
                throw CBORError.invalid("text is not UTF-8")
            }
            return .text(text)
        case 4:
            let count = try length(info)
            var items: [CBOR] = []
            items.reserveCapacity(count)
            for _ in 0 ..< count { items.append(try value(depth: depth + 1)) }
            return .array(items)
        case 5:
            let count = try length(info)
            var pairs: [(CBOR, CBOR)] = []
            pairs.reserveCapacity(count)
            for _ in 0 ..< count { pairs.append((try value(depth: depth + 1), try value(depth: depth + 1))) }
            return .map(pairs)
        case 6:
            _ = try argument(info) // tags are read through: the protocol defines none
            return try value(depth: depth + 1)
        default:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            case 25: return .double(Self.half(UInt16(try big(2))))
            case 26: return .double(Double(Float(bitPattern: UInt32(try big(4)))))
            case 27: return .double(Double(bitPattern: try big(8)))
            case 31: throw CBORError.indefiniteLength
            default: throw CBORError.invalid("simple value \(info)")
            }
        }
    }

    /// IEEE 754 half precision, decoded by hand (`Float16` is missing on Intel Macs).
    static func half(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 == 0 ? 1 : -1
        let exponent = Int((bits >> 10) & 0x1F), fraction = Double(bits & 0x3FF)
        switch exponent {
        case 0: return sign * fraction * pow(2, -24)
        case 31: return fraction == 0 ? sign * .infinity : .nan
        default: return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
        }
    }
}
