import Foundation

/// A JSON value that keeps the order of an object's keys. A JSON Schema's property order is the
/// order a language model writes the properties in, so it must survive decoding.
public enum AIJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AIJSON])
    case object([(key: String, value: AIJSON)])

    public static func == (a: AIJSON, b: AIJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public subscript(key: String) -> AIJSON? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [AIJSON]? { if case .array(let value) = self { value } else { nil } }
    public var pairs: [(key: String, value: AIJSON)]? { if case .object(let value) = self { value } else { nil } }
    /// A whole number that fits an `Int`.
    public var integer: Int? {
        guard let number, number.rounded() == number, abs(number) < 9.0e15 else { return nil }
        return Int(number)
    }

    public struct ParseError: Error, Equatable { public let offset: Int }

    /// Parses JSON text (RFC 8259), at most `depth` levels deep.
    public static func parse(_ data: Data, depth: Int = 64) throws -> AIJSON {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self), maxDepth: depth)
            parser.skipSpace()
            let value = try parser.value(depth: 0)
            parser.skipSpace()
            guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
            return value
        }
    }

    public static func parse(_ text: String, depth: Int = 64) throws -> AIJSON { try parse(Data(text.utf8), depth: depth) }

    /// Compact JSON text, keys in their order.
    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value):
            if let integer { out += String(integer) } else if value.isFinite { out += String(value) } else { out += "null" }
        case .string(let value): Self.quote(value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() { if index > 0 { out += "," }; item.write(to: &out) }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                Self.quote(pair.key, into: &out); out += ":"; pair.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let maxDepth: Int
        var index = 0

        init(bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int) { self.bytes = bytes; self.maxDepth = maxDepth }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail() -> ParseError { ParseError(offset: index) }

        mutating func expect(_ literal: StaticString) throws {
            let count = literal.utf8CodeUnitCount
            guard index + count <= bytes.count else { throw fail() }
            for offset in 0..<count where bytes[index + offset] != literal.utf8Start[offset] { throw fail() }
            index += count
        }

        mutating func value(depth: Int) throws -> AIJSON {
            guard depth <= maxDepth, index < bytes.count else { throw fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var pairs: [(key: String, value: AIJSON)] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail() }
                    index += 1
                    skipSpace()
                    pairs.append((key, try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [AIJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw fail() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    throw fail()
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func number() throws -> Double {
            let start = index
            while index < bytes.count, (bytes[index] >= 0x30 && bytes[index] <= 0x39) || [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
                index += 1
            }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii), let value = Double(text), value.isFinite else { throw fail() }
            return value
        }

        mutating func string() throws -> String {
            index += 1
            let start = index
            // Most strings (and every base64 image) have no escapes: take them whole.
            while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
                guard bytes[index] >= 0x20 else { throw fail() }
                index += 1
            }
            guard index < bytes.count else { throw fail() }
            var result = String(decoding: bytes[start..<index], as: UTF8.self)
            if bytes[index] == UInt8(ascii: "\"") { index += 1; return result }
            var scalars = String.UnicodeScalarView()
            var chunk = index
            func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: bytes[chunk..<end], as: UTF8.self).unicodeScalars) }
            while true {
                guard index < bytes.count else { throw fail() }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { flush(index); index += 1; break }
                guard byte >= 0x20 else { throw fail() }
                if byte != UInt8(ascii: "\\") { index += 1; continue }
                flush(index)
                index += 1
                guard index < bytes.count else { throw fail() }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw fail() }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw fail()
                }
                chunk = index
            }
            result += String(scalars)
            return result
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii), let value = UInt32(text, radix: 16) else { throw fail() }
            index += 4
            return value
        }
    }
}
