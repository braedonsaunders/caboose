import Foundation
import zlib
import CabooseZstd

/// One compressed record holding one entire, unchanged CGLV DATA envelope. Algorithm 1 is an
/// independent raw-DEFLATE stream per record; algorithm 2 is the next piece of one zstd stream
/// per session, ending at a flush point. WebSocket extensions remain forbidden.
enum LiveGPUCompression {
    enum Algorithm: UInt16 { case deflate = 1, zstdStream = 2 }
    static let offer = offer(.deflate) // algorithm 1, 65,600 bytes
    /// The windows algorithm 2 may negotiate, as base-2 logarithms (1 MiB to 1 GiB).
    static let windowLogs: ClosedRange<UInt32> = 20...30
    /// A TRANSPORT_CONFIG or TRANSPORT_READY payload: {1, 65600} for algorithm 1, and
    /// {2, 65600, window log, 0} for algorithm 2, the broker's largest window in CONFIG and the
    /// one the phone takes in READY.
    static func offer(_ algorithm: Algorithm, windowLog: UInt32 = 27) -> Data {
        var data = Data()
        let fields: [UInt32] = algorithm == .deflate ? [1, 65_600] : [2, 65_600, windowLog, 0]
        for var field in fields { field = field.littleEndian; withUnsafeBytes(of: &field) { data.append(contentsOf: $0) } }
        return data
    }
    /// The algorithm and, for algorithm 2, the window of a valid payload.
    static func configuration(ofOffer payload: Data) -> (algorithm: Algorithm, windowLog: UInt32?)? {
        let fields = stride(from: 0, to: payload.count, by: 4).map { UInt32(number(payload, $0, min(4, payload.count - $0))) }
        switch payload.count {
        case 8 where fields == [1, 65_600]: return (.deflate, nil)
        case 16 where fields[0] == 2 && fields[1] == 65_600 && windowLogs.contains(fields[2]) && fields[3] == 0:
            return (.zstdStream, fields[2])
        default: return nil
        }
    }
    static func algorithm(ofOffer payload: Data) -> Algorithm? { configuration(ofOffer: payload)?.algorithm }
    /// The phone's TRANSPORT_READY for a valid CONFIG: algorithm 1 echoed, algorithm 2 with the
    /// window the phone takes, never more than offered. Nil for an offer it cannot meet.
    static func answer(toOffer payload: Data, windowLog wanted: UInt32) -> (payload: Data, windowLog: UInt32?)? {
        guard let (algorithm, offered) = configuration(ofOffer: payload) else { return nil }
        guard let offered else { return (payload, nil) }
        let taken = min(wanted, offered)
        guard windowLogs.contains(taken) else { return nil }
        return (offer(algorithm, windowLog: taken), taken)
    }
    /// The window the phone takes: 128 MiB (log 27) with room to spare, as with the
    /// increased memory limit, otherwise 64 MiB (log 26), and 8 MiB when memory is short.
    static func preferredWindowLog(available: Int) -> UInt32 {
        if available >= 3 << 30 { return 27 }
        if available >= 512 << 20 { return 26 }
        return 23
    }
    static let maximumDecoded = 65_600
    static let magic = Data([0x43, 0x47, 0x4c, 0x5a])

    static func isCompressed(_ data: Data) -> Bool { data.prefix(4) == magic }
    static func number(_ data: Data, _ offset: Int, _ count: Int) -> Int {
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
    init(windowLog: UInt32) throws {
        guard LiveGPUCompression.windowLogs.contains(windowLog) else { throw LiveGPUCompression.invalid() }
        guard let stream = caboose_zstd_stream_create(Int32(windowLog)) else { throw LiveGPUBindingError.system(operation: "zstd", code: ENOMEM) }
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
