import Foundation
import zlib

/// One independent raw-DEFLATE record. WebSocket extensions remain forbidden.
/// The compressed message contains one entire, unchanged CGLV DATA envelope.
enum LiveGPUCompression {
    static let offer = Data([1, 0, 0, 0, 0x40, 0, 1, 0]) // algorithm 1, 65,600 bytes
    static let maximumDecoded = 65_600
    static let magic = Data([0x43, 0x47, 0x4c, 0x5a])

    static func isCompressed(_ data: Data) -> Bool { data.prefix(4) == magic }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    static func decodedSize(_ data: Data) throws -> Int {
        guard data.count >= 17, isCompressed(data), number(data, 4, 2) == 1,
              number(data, 6, 2) == 1 else { throw invalid() }
        let decoded = number(data, 8, 4), compressed = number(data, 12, 4)
        guard (65...maximumDecoded).contains(decoded), compressed > 0,
              compressed == data.count - 16, data.count < decoded else { throw invalid() }
        return decoded
    }
    /// Includes retained wire and inflate output with overflow sentinel. The
    /// existing decoder separately retains at most one bounded partial envelope.
    /// Admission occurs before the worker closure retains the compressed message.
    static func admissionCharge(_ data: Data) throws -> Int {
        try data.count + decodedSize(data) + 1
    }
    static func requireWholeEnvelope(_ data: Data, dataOnly: Bool = false) throws {
        guard data.count >= 64, data.prefix(4) == Data([0x43, 0x47, 0x4c, 0x56]),
              number(data, 4, 2) == 1, number(data, 12, 4) == 0,
              number(data, 8, 4) == data.count - 64 else { throw invalid() }
        if dataOnly {
            guard number(data, 6, 2) == 7, (1...65_536).contains(data.count - 64) else { throw invalid() }
        }
    }
    static func decode(_ data: Data) throws -> Data {
        let size = try decodedSize(data)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw invalid()
        }
        defer { inflateEnd(&stream) }
        // One extra byte distinguishes a full valid output from an expanding stream.
        var output = Data(count: size + 1)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: 16))
                stream.avail_in = uInt(data.count - 16)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(size + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0, stream.total_out == size else { throw invalid() }
        output.removeLast()
        try requireWholeEnvelope(output, dataOnly: true)
        return output
    }
    private static func invalid() -> LiveGPUBindingError { .protocolViolation("invalid compressed DATA") }
}

/// Synchronized, nonblocking admission metadata; decoding remains on the worker.
protocol LiveGPUIngressAccounting: AnyObject {
    func ingressCharge(_ data: Data) throws -> Int
}
