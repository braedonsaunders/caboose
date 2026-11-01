import Foundation
import zlib
import CabooseZstd

/// One compressed record holding one entire, unchanged CGLV DATA envelope. Algorithm 1 is an
/// independent raw-DEFLATE stream per record; algorithm 2 is the next piece of one zstd stream
/// per session, ending at a flush point. WebSocket extensions remain forbidden.
enum LiveGPUCompression {
    enum Algorithm: UInt16 { case deflate = 1, zstdStream = 2 }
    static let offer = offer(.deflate) // algorithm 1, 65,600 bytes
    static func offer(_ algorithm: Algorithm) -> Data { Data([UInt8(algorithm.rawValue), 0, 0, 0, 0x40, 0, 1, 0]) }
    static func algorithm(ofOffer payload: Data) -> Algorithm? {
        [Algorithm.deflate, .zstdStream].first { offer($0) == payload }
    }
    static let maximumDecoded = 65_600
    static let magic = Data([0x43, 0x47, 0x4c, 0x5a])

    static func isCompressed(_ data: Data) -> Bool { data.prefix(4) == magic }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    /// The record's declared decoded size. A DEFLATE record must be smaller than what it
    /// decodes to; a zstd stream record need not be, since every DATA envelope is one.
    static func decodedSize(_ data: Data, algorithm: Algorithm? = nil) throws -> Int {
        guard data.count >= 17, isCompressed(data), number(data, 4, 2) == 1,
              let found = Algorithm(rawValue: UInt16(number(data, 6, 2))), algorithm.map({ $0 == found }) ?? true
        else { throw invalid() }
        let decoded = number(data, 8, 4), compressed = number(data, 12, 4)
        guard (65...maximumDecoded).contains(decoded), compressed > 0,
              compressed == data.count - 16, found == .zstdStream || data.count < decoded else { throw invalid() }
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
        let size = try decodedSize(data, algorithm: .deflate)
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
    static func invalid() -> LiveGPUBindingError { .protocolViolation("invalid compressed DATA") }
}

/// The session's zstd stream (algorithm 2): its records decoded in sequence order, each once.
/// Serial worker only.
final class LiveGPUZstdStream {
    private let stream: OpaquePointer
    init() throws {
        guard let stream = caboose_zstd_stream_create() else { throw LiveGPUBindingError.system(operation: "zstd", code: ENOMEM) }
        self.stream = stream
    }
    deinit { caboose_zstd_stream_free(stream) }
    func decode(_ data: Data) throws -> Data {
        let size = try LiveGPUCompression.decodedSize(data, algorithm: .zstdStream)
        var output = Data(count: size)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                caboose_zstd_stream_decode(stream, input.baseAddress!.advanced(by: 16), data.count - 16,
                                           destination.baseAddress, size)
            }
        }
        guard result == 0 else { throw LiveGPUCompression.invalid() }
        try LiveGPUCompression.requireWholeEnvelope(output, dataOnly: true)
        return output
    }
}

/// Synchronized, nonblocking admission metadata; decoding remains on the worker.
protocol LiveGPUIngressAccounting: AnyObject {
    func ingressCharge(_ data: Data) throws -> Int
}
