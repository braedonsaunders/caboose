import Foundation

/// Opt-in metadata only; never receives packets, log strings, errors or peer text.
public enum AudioDiagnostics {
    public static let setting = "CabooseAudioDiagnosticsEnabled"
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: setting) }
    private static let writer = AudioDiagnosticWriter()

    static func record(_ record: @autoclosure () -> AudioDiagnosticRecord) {
        guard enabled else { return }
        writer.submit(record())
    }
}

struct AudioDiagnosticRecord: Encodable {
    enum Kind: String, Encodable { case interval, restart, startup }
    var kind: Kind
    var monotonicSeconds: Double
    var wallUnixSeconds: Double
    var packets: Int
    var failures: Int
    var restarts: Int
    var delayMicros: Int64
    var requestedRate: Double
    var observedRate: Double?
    var projectedMicros: Int64?
    var renderedMicros: Int64?
    var timestampRegressions: Int
    var rendererStatus: Int? = nil
    var frameMin: Int? = nil
    var frameMax: Int? = nil
    var arrivalMaxSeconds: Double? = nil
    var interval: AudioTimingInterval? = nil
    var rawPTSMicros: Int64? = nil
    var placedPTSMicros: Int64? = nil
    var receiptToDispatchMS: Int? = nil
    var queueMS: Int? = nil
    var decodeMS: Int? = nil
    var preparationMS: Int? = nil
    var enqueueMS: Int? = nil
    var totalMS: Int? = nil
    var finishedMonotonicSeconds: Double? = nil
    var automaticFlush: AudioAutomaticFlushState.Summary? = nil
    var startup: AudioStartupBucket? = nil
    var clockGeneration: UInt64? = nil
    var rateProvenance: AudioRateProvenanceState.Snapshot? = nil
}

/// A fixed-size mailbox plus history. At most one drain is queued/running, even if
/// storage stalls. Producers only copy numeric records under a short memory lock.
struct AudioDiagnosticBuffer {
    static let maximumRecords = 64
    static let maximumBytes = 128 * 1024
    private(set) var records: [AudioDiagnosticRecord] = []
    private(set) var revision: UInt64 = 0
    private(set) var scheduled = false

    mutating func append(_ record: AudioDiagnosticRecord) -> Bool {
        records.append(record)
        if records.lazy.filter({ $0.kind == .startup }).count > AudioStartupAccumulator.maximumBuckets,
           let oldest = records.firstIndex(where: { $0.kind == .startup }) {
            records.remove(at: oldest)
        }
        if records.count > Self.maximumRecords { records.removeFirst(records.count - Self.maximumRecords) }
        revision &+= 1
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// False keeps the same drain alive for the latest snapshot; no second work item.
    mutating func finish(revision written: UInt64) -> Bool {
        guard written == revision else { return false }
        scheduled = false
        return true
    }

    /// Called only by the writer. Invalid numeric records cannot poison later reports.
    /// Remove oldest records to meet the byte cap, including JSON punctuation.
    static func snapshot(_ records: [AudioDiagnosticRecord], maximumBytes: Int = AudioDiagnosticBuffer.maximumBytes) -> Data? {
        guard maximumBytes >= 2 else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bounded = Array(records.suffix(maximumRecords))
        while bounded.lazy.filter({ $0.kind == .startup }).count > AudioStartupAccumulator.maximumBuckets,
              let oldest = bounded.firstIndex(where: { $0.kind == .startup }) {
            bounded.remove(at: oldest)
        }
        var encoded = bounded.compactMap { try? encoder.encode($0) }
        var size = 2 + encoded.reduce(0) { $0 + $1.count } + max(0, encoded.count - 1)
        while size > maximumBytes, !encoded.isEmpty {
            let removed = encoded.removeFirst()
            size -= removed.count + (encoded.isEmpty ? 0 : 1)
        }
        var data = Data([0x5b])
        for (index, record) in encoded.enumerated() {
            if index > 0 { data.append(0x2c) }
            data.append(record)
        }
        data.append(0x5d)
        return data
    }
}

private final class AudioDiagnosticWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "caboose.display.audio-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var buffer = AudioDiagnosticBuffer()

    func submit(_ record: AudioDiagnosticRecord) {
        lock.lock()
        let schedule = buffer.append(record)
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let records = buffer.records
            let revision = buffer.revision
            lock.unlock()
            // Preferences, encoding, directory creation and atomic replacement run here,
            // never on the sound queue. Disabling prevents pending snapshots being saved.
            if AudioDiagnostics.enabled, let data = AudioDiagnosticBuffer.snapshot(records),
               let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let directory = caches.appendingPathComponent("CabooseDiagnostics", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("audio-timing.json"), options: .atomic)
                } catch {
                    // Diagnostics never change playback or recovery, including on I/O failure.
                }
            }
            lock.lock()
            let finished = buffer.finish(revision: revision)
            lock.unlock()
            if finished { return }
        }
    }
}
