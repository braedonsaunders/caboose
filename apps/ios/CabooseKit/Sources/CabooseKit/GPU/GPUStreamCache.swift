import Foundation

/// GPU stream bytes kept on the device (docs/gpu-stream.md, "The device's copy"), so that a new
/// replay of a stream that is still live (after the app relaunched, or after a replay was lost)
/// takes the stream's start from here and only its tail from the computer.
///
/// A stream is kept as `<directory>/<server epoch>/<stream id>`, with `<stream id>.json` beside
/// it recording the stream's epoch, id and nonce and how many of its bytes, from the first, the
/// data holds. The record is replaced atomically, after the data is synchronized, and data past
/// its recorded length is never used. The cache is bounded: one stream keeps at most
/// `streamLimit` bytes, and the least recently used streams are removed so that all of them fit
/// `budget`. A stream that is open (being written or read) is never removed by another; one
/// that cannot have room stops being cached. It lives in Caches, which the system may purge.
///
/// The app clears it on signing out and on switching computers; a server hello with another
/// epoch removes the other epochs' streams.
public final class GPUStreamCache: @unchecked Sendable {
    public static let shared = GPUStreamCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CabooseGPUStreams"))

    /// What a stream's record says.
    struct Record: Codable, Equatable {
        var epoch: String
        var id: Int
        var nonce: String
        /// Bytes of the stream, from its first, that the data holds.
        var length: UInt64
    }

    public let directory: URL
    /// Bytes recorded for a stream between two records while it is written.
    let commitInterval: UInt64
    private let lock = NSLock()
    private var budgetBytes: UInt64
    private var streamLimitBytes: UInt64
    /// Bytes every stream's data takes, once counted.
    private var total: UInt64?
    /// Exclusive writer token by key; eviction leaves these streams alone.
    private var open: [String: Int] = [:]
    /// Accounted file lengths, including growth reserved before a write completes.
    private var accounted: [String: UInt64] = [:]
    // Internal I/O boundary permits deterministic partial-write failure checks.
    var writeData: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    /// Monotonic writer token: removal invalidates only the writer that owned that key.
    private var generation = 0

    /// - Parameters:
    ///   - budget: bytes kept at most, over every stream (4 GiB unless set).
    ///   - streamLimit: bytes kept at most of one stream (2 GiB unless set, caboose-display's
    ///     default spool limit; a stream past the computer's own spool limit ends there).
    public init(directory: URL, budget: UInt64 = 4 << 30, streamLimit: UInt64 = 2 << 30, commitInterval: UInt64 = 4 << 20) {
        self.directory = directory
        budgetBytes = budget
        streamLimitBytes = streamLimit
        self.commitInterval = max(1, commitInterval)
    }

    /// Bytes kept at most, over every stream. Lowering it takes effect as streams grow.
    public var budget: UInt64 {
        get { lock.withLock { budgetBytes } }
        set { lock.withLock { budgetBytes = newValue } }
    }

    /// Bytes kept at most of one stream.
    public var streamLimit: UInt64 {
        get { lock.withLock { streamLimitBytes } }
        set { lock.withLock { streamLimitBytes = newValue } }
    }

    /// A server epoch is a directory name only when it is plainly one: 1–64 letters, digits,
    /// `-` and `_` (caboose-display sends 16 hexadecimal characters). Another server's streams
    /// are not cached.
    static func isUsable(epoch: String) -> Bool {
        (1 ... 64).contains(epoch.utf8.count) && epoch.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    private static func key(epoch: String, id: Int) -> String { "\(epoch)/\(id)" }

    private func dataURL(_ key: String) -> URL { directory.appendingPathComponent(key) }
    private func recordURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    // MARK: Streams

    /// Opens stream `id` of server `epoch`, named `nonce`, for a replay: what the device holds of
    /// it (`Stream.cached`), and its writer. A stream kept under another nonce, or one whose
    /// record does not match its place or its data, is discarded first. Nil when nothing can be
    /// kept for it (an epoch that is not a plain name, or a file that cannot be made).
    public func open(epoch: String, id: Int, nonce: String) -> Stream? {
        guard Self.isUsable(epoch: epoch), id >= 0, !nonce.isEmpty else { return nil }
        let key = Self.key(epoch: epoch, id: id)
        lock.lock()
        defer { lock.unlock() }
        // A second writer could truncate or replace a file the first replay is using.
        guard open[key] == nil else { return nil }
        countIfNeeded()
        let fresh = Record(epoch: epoch, id: id, nonce: nonce, length: 0)
        var record = fresh
        if let kept = readRecord(key), kept.epoch == epoch, kept.id == id, kept.nonce == nonce,
           let size = dataSize(key), size >= kept.length {
            record = kept
        } else {
            removeFiles(key)
        }
        let url = dataURL(key)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forUpdating: url)
            // Data past the recorded length was never recorded as complete: it goes.
            let before = dataSize(key) ?? 0
            try handle.truncate(atOffset: record.length)
            total = (total ?? 0) - min(total ?? 0, before) + record.length
            accounted[key] = record.length
            if record == fresh { try write(record, key) }
            touch(url)
            generation += 1
            open[key] = generation
            return Stream(cache: self, key: key, record: record, handle: handle, generation: generation)
        } catch {
            removeFiles(key)
            return nil
        }
    }

    /// Removes stream `id` of server `epoch`: the stream is over, or what is kept of it cannot be
    /// replayed.
    public func remove(epoch: String, id: Int) {
        guard Self.isUsable(epoch: epoch) else { return }
        lock.withLock {
            let key = Self.key(epoch: epoch, id: id)
            open[key] = nil
            removeFiles(key)
        }
    }

    /// Removes every stream of every epoch but `epoch` (all of them for nil): ids and nonces name
    /// streams only within one server process.
    public func retain(epoch: String?) {
        lock.withLock {
            let epochs = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for other in epochs where other != epoch {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(other).path)) ?? [] {
                    let key = other + "/" + (name.hasSuffix(".json") ? String(name.dropLast(5)) : name)
                    open[key] = nil
                    removeFiles(key)
                }
            }
        }
    }

    /// Removes everything, open streams included: they record nothing more.
    public func removeAll() {
        lock.withLock {
            generation += 1
            open.removeAll()
            accounted.removeAll()
            try? FileManager.default.removeItem(at: directory)
            total = 0
        }
    }

    /// Bytes kept, over every stream.
    var usedBytes: UInt64 { lock.withLock { countIfNeeded(); return total ?? 0 } }

    // MARK: Under the lock

    /// Room for `bytes` more of stream `key`, now `length` long: within the stream's limit, and
    /// within the budget once the least recently used streams that are not open are removed.
    fileprivate func reserve(_ bytes: UInt64, for key: String, length: UInt64, generation: Int) -> Bool {
        lock.withLock {
            guard open[key] == generation, length + bytes <= streamLimitBytes else { return false }
            countIfNeeded()
            var used = total ?? 0
            if used + bytes > budgetBytes {
                for (victim, _) in leastRecentlyUsed() where victim != key && open[victim] == nil {
                    removeFiles(victim)
                    used = total ?? 0
                    if used + bytes <= budgetBytes { break }
                }
            }
            guard used + bytes <= budgetBytes else { return false }
            total = used + bytes
            accounted[key, default: length] += bytes
            return true
        }
    }

    /// Records `record` for stream `key` atomically: a temporary file renamed over the record.
    fileprivate func commit(_ record: Record, for key: String, generation: Int) throws {
        try lock.withLock {
            guard open[key] == generation else { throw CocoaError(.fileNoSuchFile) }
            try write(record, key)
        }
    }

    /// Stream `key` stopped growing at `length`: its data shrinks to that.
    fileprivate func settle(_ key: String, at length: UInt64, previous: UInt64, generation: Int) {
        lock.withLock {
            guard open[key] == generation else { return }
            if let counted = total, previous > length { total = counted - min(counted, previous - length) }
            accounted[key] = length
        }
    }

    /// Stream `key`, opened in `generation`, closes; with `discard`, what is kept of it goes too,
    /// unless its ownership was invalidated meanwhile (another stream may hold its place).
    fileprivate func close(_ key: String, discard: Bool, generation: Int) {
        lock.withLock {
            guard open[key] == generation else { return }
            open[key] = nil
            if discard { removeFiles(key) }
        }
    }

    /// What is kept of stream `key`, still open once by the caller, goes.
    fileprivate func discard(_ key: String, generation: Int) {
        lock.withLock {
            if open[key] == generation { removeFiles(key) }
        }
    }

    private func write(_ record: Record, _ key: String) throws {
        try JSONEncoder().encode(record).write(to: recordURL(key), options: .atomic)
    }

    private func readRecord(_ key: String) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(key)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func dataSize(_ key: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: dataURL(key).path)[.size] as? NSNumber)?.uint64Value
    }

    private func removeFiles(_ key: String) {
        if let size = accounted.removeValue(forKey: key), let counted = total { total = counted - min(counted, size) }
        try? FileManager.default.removeItem(at: dataURL(key))
        try? FileManager.default.removeItem(at: recordURL(key))
        let epoch = dataURL(key).deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: epoch.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: epoch)
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Every stream's data, least recently used (written or opened) first.
    private func leastRecentlyUsed() -> [(key: String, used: Date)] {
        var streams: [(key: String, used: Date)] = []
        for epoch in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let folder = directory.appendingPathComponent(epoch)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasSuffix(".json") {
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                streams.append((epoch + "/" + name, attributes?[.modificationDate] as? Date ?? .distantPast))
            }
        }
        return streams.sorted { $0.used < $1.used }
    }

    private func countIfNeeded() {
        guard total == nil else { return }
        for (key, _) in leastRecentlyUsed() { accounted[key] = dataSize(key) ?? 0 }
        total = accounted.values.reduce(0, +)
    }
}

extension GPUStreamCache {
    /// One stream, open for a replay: what the device holds of it, and the writer that keeps
    /// what arrives. Writes come in stream order from one queue at a time; the rest may be called
    /// from anywhere.
    public final class Stream: @unchecked Sendable {
        private let cache: GPUStreamCache
        private let key: String
        private let generation: Int
        private let lock = NSLock()
        private var record: Record
        private var handle: FileHandle?
        /// Bytes of the stream the data holds, recorded or not.
        private var length: UInt64
        private var closed = false

        /// Bytes of the stream, from its first, that the device held when it was opened: what a new
        /// replay can take from here.
        public let cached: UInt64
        /// The stream's data; only its first `cached` bytes are to be read.
        public var dataURL: URL { cache.directory.appendingPathComponent(key) }

        fileprivate init(cache: GPUStreamCache, key: String, record: Record, handle: FileHandle, generation: Int) {
            self.cache = cache
            self.key = key
            self.record = record
            self.handle = handle
            self.generation = generation
            length = record.length
            cached = record.length
        }

        deinit { close() }

        /// Whether what arrives is still being kept.
        public var isKeeping: Bool { lock.withLock { handle != nil } }

        /// Bytes recorded as complete.
        var recordedLength: UInt64 { lock.withLock { record.length } }

        /// Keeps `data`, the stream's bytes at `offset`. Bytes already kept are written again
        /// (they are the same). A gap past what is kept, or no room, stops the keeping, with
        /// what is recorded kept; a write that fails stops it and discards the stream.
        public func write(_ data: Data, at offset: UInt64) {
            lock.withLock {
                guard let handle, !data.isEmpty else { return }
                guard offset <= length else { return stop(discard: false) }
                let end = offset + UInt64(data.count)
                if end > length, !cache.reserve(end - length, for: key, length: length, generation: generation) {
                    return stop(discard: false)
                }
                do {
                    try handle.seek(toOffset: offset)
                    try cache.writeData(handle, data)
                } catch {
                    return stop(discard: true)
                }
                length = max(length, end)
                if length - record.length >= cache.commitInterval { commitLocked() }
            }
        }

        /// Records what has been written so far.
        public func commit() { lock.withLock { commitLocked() } }

        /// Records what has been written and closes the stream; it keeps nothing more.
        public func close() {
            lock.withLock {
                guard !closed else { return }
                commitLocked()
                try? handle?.close()
                handle = nil
                closed = true
                cache.close(key, discard: false, generation: generation)
            }
        }

        /// Closes the stream and removes everything kept of it.
        public func discard() {
            lock.withLock {
                guard !closed else { return }
                try? handle?.close()
                handle = nil
                closed = true
                cache.close(key, discard: true, generation: generation)
            }
        }

        private func commitLocked() {
            guard let handle, length != record.length else { return }
            var next = record
            next.length = length
            do {
                try handle.synchronize()
                try cache.commit(next, for: key, generation: generation)
                record = next
            } catch {
                stop(discard: true)
            }
        }

        /// Stops keeping: what is recorded stays unless `discard`, and the data shrinks to it.
        private func stop(discard: Bool) {
            guard let handle else { return }
            var discard = discard
            if !discard, (try? handle.truncate(atOffset: record.length)) == nil { discard = true }
            if !discard {
                cache.settle(key, at: record.length, previous: length, generation: generation)
                length = record.length
            }
            try? handle.close()
            self.handle = nil
            if discard { cache.discard(key, generation: generation) }
        }
    }
}
