import Foundation

/// CGLV framing is accepted only on the authenticated live transport. It does not
/// authenticate arbitrary bytes and never shares the legacy display parser.
struct LiveGPUEnvelope: Equatable {
    static let headerSize = 64
    static let maxPayload = 262_080
    enum Kind: UInt16, CaseIterable {
        case session = 1, sessionReady, processOpen, processReady, streamOpen, streamReady
        case data, fin, processStop, processRetired, revoke, revoked
    }
    let kind: Kind
    let executor: Data
    let generation: UInt64
    let process: UInt64
    let stream: UInt64
    let sequence: UInt64
    let payload: Data

    // Frozen private hello v2 and source fingerprint from live-vectors.json.
    static let hello = Data([0x43,0x42,0x47,0x4c,0x52,0x45,0x46,0x31,0x02,0,0,0,0x10,0,0,0,
        0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
        0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0])

    func validate(length: Int) throws {
        func require(_ ok: Bool) throws { if !ok { throw LiveGPUBindingError.protocolViolation("invalid envelope scope or length") } }
        try require(executor.count == 16 && executor.contains(where: { $0 != 0 }) && generation > 0 && sequence > 0)
        try require(length <= Self.maxPayload && length >= 0)
        switch kind {
        case .session, .sessionReady, .revoke, .revoked: try require(process == 0 && stream == 0)
        case .processOpen, .processReady, .processStop, .processRetired: try require(process > 0 && stream == 0)
        default: try require(process > 0 && stream > 0)
        }
        switch kind {
        case .session, .sessionReady: try require(length == 48)
        case .data: try require(length > 0)
        default: try require(length == 0)
        }
    }
    func encoded() throws -> Data {
        try validate(length: payload.count)
        var result = Data([0x43, 0x47, 0x4c, 0x56])
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        append(UInt16(1)); append(kind.rawValue); append(UInt32(payload.count)); append(UInt32(0))
        result.append(executor)
        append(generation); append(process); append(stream); append(sequence)
        result.append(payload)
        return result
    }
}

/// One bounded partial frame; delivery is synchronous and errors permanently poison it.
final class LiveGPUEnvelopeDecoder {
    private var identity: (Data, UInt64)?
    private var sequence: UInt64 = 1
    private var exhausted = false
    private var buffer = Data()
    private var header: LiveGPUEnvelope?
    private var length = 0
    private var ended = false
    var bufferedBytes: Int { buffer.count }
    init(executor: Data? = nil, generation: UInt64? = nil) throws {
        guard (executor == nil) == (generation == nil) else { throw LiveGPUBindingError.protocolViolation("incomplete identity") }
        if let executor, let generation { identity = (executor, generation) }
    }
    func feed(_ bytes: Data, deliver: (LiveGPUEnvelope) throws -> Void) throws {
        guard !ended else { throw LiveGPUBindingError.protocolViolation("decoder ended") }
        do {
            guard bytes.count <= 262_144 else { throw LiveGPUError.messageTooLarge }
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let target = header == nil ? 64 : length
                let take = min(target - buffer.count, bytes.endIndex - offset)
                buffer.append(bytes[offset..<(offset + take)]); offset += take
                if buffer.count != target { continue }
                if header == nil {
                    func number<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
                        (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(buffer[at + $1]) << ($1 * 8) }
                    }
                    guard buffer.prefix(4) == Data([0x43,0x47,0x4c,0x56]), number(4, UInt16.self) == 1,
                          number(12, UInt32.self) == 0, let kind = LiveGPUEnvelope.Kind(rawValue: number(6, UInt16.self)) else {
                        throw LiveGPUBindingError.protocolViolation("invalid CGLV header")
                    }
                    length = Int(number(8, UInt32.self))
                    let frame = LiveGPUEnvelope(kind: kind, executor: Data(buffer[16..<32]), generation: number(32, UInt64.self),
                        process: number(40, UInt64.self), stream: number(48, UInt64.self), sequence: number(56, UInt64.self), payload: Data())
                    try frame.validate(length: length)
                    guard !exhausted, frame.sequence == sequence else { throw LiveGPUBindingError.protocolViolation("sequence mismatch") }
                    if let identity {
                        guard identity.0 == frame.executor, identity.1 == frame.generation else { throw LiveGPUBindingError.protocolViolation("identity mismatch") }
                    } else {
                        guard kind == .session else { throw LiveGPUBindingError.protocolViolation("SESSION required") }
                        identity = (frame.executor, frame.generation)
                    }
                    header = frame; buffer.removeAll(keepingCapacity: true)
                    if length > 0 { continue }
                }
                let h = header!
                let frame = LiveGPUEnvelope(kind: h.kind, executor: h.executor, generation: h.generation,
                    process: h.process, stream: h.stream, sequence: h.sequence, payload: buffer)
                buffer = Data(); header = nil
                if sequence == UInt64.max { exhausted = true } else { sequence += 1 }
                try deliver(frame)
            }
        } catch { ended = true; buffer = Data(); header = nil; throw error }
    }
    func finish() throws {
        guard !ended else { throw LiveGPUBindingError.protocolViolation("decoder ended") }
        ended = true
        let partial = header != nil || !buffer.isEmpty
        buffer = Data(); header = nil
        if partial { throw LiveGPUBindingError.protocolViolation("truncated envelope") }
    }
}
