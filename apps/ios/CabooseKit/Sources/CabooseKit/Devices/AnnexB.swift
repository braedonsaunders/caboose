import Foundation

/// H.264 as the computer reads it: Annex-B, NAL units behind start codes.
extension AnnexB {
    static let startCode = Data([0, 0, 0, 1])

    /// VideoToolbox's output (NAL units behind big-endian `lengthSize`-byte lengths) as
    /// Annex-B, with `parameterSets` (SPS and PPS) first when given. Nil when a length runs
    /// past the end.
    public static func from(lengthPrefixed data: Data, lengthSize: Int = 4, parameterSets: [Data] = []) -> Data? {
        guard (1 ... 4).contains(lengthSize) else { return nil }
        var out = Data(capacity: data.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 64)
        for set in parameterSets {
            out.append(startCode)
            out.append(set)
        }
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard index + lengthSize <= bytes.count else { return nil }
            var length = 0
            for offset in 0 ..< lengthSize { length = length << 8 | Int(bytes[index + offset]) }
            index += lengthSize
            guard length > 0, index + length <= bytes.count else { return nil }
            out.append(startCode)
            out.append(contentsOf: bytes[index ..< index + length])
            index += length
        }
        return out
    }
}
