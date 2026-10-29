import Foundation

/// Game files kept on the device, each under `GameFiles.cacheKey` (one computer's file at one
/// etag), so a file that has not changed loads from the device on the next launch.
///
/// The cache is bounded: after each file is stored, the least recently used files are removed
/// until the rest fit `budget`. A file is used when it is stored or served. The system may
/// also purge `Caches` whenever it needs the space.
final class GameCache: @unchecked Sendable {
    static let shared = GameCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CabooseGames"),
        budget: 1 << 30)

    let directory: URL
    /// Bytes kept at most.
    let budget: Int
    private let lock = NSLock()
    private static let stagingPrefix = ".staging-"

    init(directory: URL, budget: Int) {
        self.directory = directory
        self.budget = budget
    }

    /// The cached file for a key, if there is one.
    func file(_ key: String) -> URL? {
        let url = directory.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Marks a file as just used.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// A new file's place while it downloads, in the cache's own directory so it moves in atomically.
    func stagingFile() -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
    }

    /// Moves a complete download in under `key`. Another copy that got there first is kept.
    @discardableResult
    func store(_ staged: URL, as key: String) -> URL? {
        let target = directory.appendingPathComponent(key)
        do {
            try FileManager.default.moveItem(at: staged, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        }
        touch(target)
        evict()
        return target
    }

    func store(_ data: Data, as key: String) {
        let staged = stagingFile()
        guard (try? data.write(to: staged)) != nil else { return }
        store(staged, as: key)
    }

    func data(_ key: String) -> Data? {
        guard let url = file(key), let data = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return data
    }

    /// Removes the least recently used files beyond the budget, and downloads abandoned an hour ago.
    func evict(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, used: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let used = values.contentModificationDate ?? .distantPast
            if url.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                if now.timeIntervalSince(used) > 3600 { try? FileManager.default.removeItem(at: url) }
                continue
            }
            files.append((url, values.fileSize ?? 0, used))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.used < $1.used }) where total > budget {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
