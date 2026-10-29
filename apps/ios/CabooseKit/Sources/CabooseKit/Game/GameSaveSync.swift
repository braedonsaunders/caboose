import Foundation

/// Keeps a game's saves on the computer (docs/game-handoff.md, "Saves").
///
/// Before the page loads, `load()` lists every save `path` recursively and downloads its files
/// into the seed the page's IndexedDB shim answers IDBFS from. Each IDBFS write that reaches
/// `record` goes out within `delay` plus the time the writes take, through the planner:
/// `If-Match` with the etag last seen, `If-None-Match: *` for a new file. A file whose
/// computer copy changed underneath (412) gets the device's version written beside it under
/// `GameFiles.conflictPath`, then and on every later write, so neither is lost. A batch that
/// cannot reach the computer is tried again every `retry` until the game ends.
@MainActor
final class GameSaveSync {
    static let delay: Duration = .seconds(1)
    static let retry: Duration = .seconds(5)
    /// Downloads at once while loading.
    static let parallelDownloads = 6

    let saves: [GameSave]
    private let host: () -> GameHostAccess?
    private let makeService: (GameHostAccess) -> any GameFileService
    private let cache: GameCache?
    private let device: String
    /// The etag last seen for each host file, from listing, writing or stat.
    private(set) var etags: [String: String] = [:]
    /// Host directories known to exist.
    private(set) var directories: Set<String> = []
    /// Host files whose computer copy changed underneath the device: writes go to their conflict copy.
    private(set) var conflicted: Set<String> = []
    private var pending: [GameSaveChange] = []
    private var sleeper: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var finished = false

    init(saves: [GameSave], device: String, cache: GameCache? = .shared, host: @escaping () -> GameHostAccess?,
         makeService: @escaping (GameHostAccess) -> any GameFileService = { GameFileClient(host: $0) }) {
        self.saves = saves
        self.device = device
        self.cache = cache
        self.host = host
        self.makeService = makeService
    }

    /// Whether writes are waiting or under way.
    var isIdle: Bool { pending.isEmpty && writer == nil }

    // MARK: Loading

    /// Every save's directories and files as they are on the computer now; a save whose
    /// directory does not exist yet is empty.
    func load() async throws -> GameSeed {
        guard let host = host() else { throw Self.noHost }
        let service = makeService(host)
        var seed = GameSeed(mounts: saves.map(\.mount))
        for save in saves {
            let root = GameFiles.join(save.path, "")
            var entries: [String: GameSeed.Entry] = [:]
            var files: [(virtual: String, path: String, item: GameFileItem)] = []
            var queue = [root]
            while let directory = queue.popLast() {
                guard let items = try await service.list(directory) else { continue }
                directories.insert(directory)
                if directory == root { directories.formUnion(GameFiles.ancestors(of: root)) }
                for item in items {
                    let path = GameFiles.join(directory, item.name)
                    guard let virtual = GameFiles.virtualPath(path, in: save) else { continue }
                    if item.isDirectory {
                        entries[virtual] = .directory(mtime: item.mtime)
                        queue.append(path)
                    } else if item.kind == "file" {
                        files.append((virtual, path, item))
                    }
                }
            }
            for (path, file) in try await download(files.map { (path: $0.path, item: $0.item) }, service: service, computer: host.computerKey) {
                guard let listed = files.first(where: { $0.path == path }) else { continue }
                if let etag = file.etag { etags[path] = etag }
                entries[listed.virtual] = .file(mtime: listed.item.mtime, data: file.data)
            }
            seed.entries[save.mount, default: [:]].merge(entries) { $1 }
        }
        return seed
    }

    /// Downloads files, at most `parallelDownloads` at once, through the cache.
    private func download(_ files: [(path: String, item: GameFileItem)], service: any GameFileService,
                          computer: String) async throws -> [(String, (data: Data, etag: String?))] {
        let cache = cache
        return try await withThrowingTaskGroup(of: (String, (data: Data, etag: String?)).self) { group in
            var results: [(String, (data: Data, etag: String?))] = []
            var next = files.makeIterator()
            func add(_ file: (path: String, item: GameFileItem)) {
                group.addTask {
                    let key = file.item.etag.isEmpty ? nil : GameFiles.cacheKey(computer: computer, path: file.path, etag: file.item.etag)
                    if let key, let data = cache?.data(key) { return (file.path, (data, file.item.etag)) }
                    let fetched = try await service.download(file.path)
                    let etag = fetched.etag ?? (file.item.etag.isEmpty ? nil : file.item.etag)
                    if let etag { cache?.store(fetched.data, as: GameFiles.cacheKey(computer: computer, path: file.path, etag: etag)) }
                    return (file.path, (fetched.data, etag))
                }
            }
            for _ in 0 ..< Self.parallelDownloads { if let file = next.next() { add(file) } }
            while let result = try await group.next() {
                results.append(result)
                if let file = next.next() { add(file) }
            }
            return results
        }
    }

    // MARK: Writing

    /// Changes the page made to a save database; written to the computer within `delay`.
    func record(_ changes: [GameSaveChange]) {
        guard !changes.isEmpty else { return }
        pending.append(contentsOf: changes)
        schedule(after: Self.delay)
    }

    /// Writes everything waiting now and waits for it. A write that cannot reach the computer
    /// is tried again later; the wait does not.
    func flush() async {
        if writer == nil, !pending.isEmpty { schedule(after: .zero) }
        sleeper?.cancel()
        if let writer { await writer.value }
    }

    /// The game ended: one last flush, and no retries after it.
    func finish() async {
        finished = true
        await flush()
    }

    private func schedule(after delay: Duration) {
        guard writer == nil, !finished || delay == .zero else { return }
        let sleeper = Task { _ = try? await Task.sleep(for: delay) }
        self.sleeper = sleeper
        writer = Task { [weak self] in
            await sleeper.value
            guard let self else { return }
            await drain()
        }
    }

    private func drain() async {
        var failed = false
        while !pending.isEmpty, !failed {
            guard let host = host() else {
                failed = true
                break
            }
            let service = makeService(host)
            let batch = pending
            pending.removeAll()
            let steps = GameSavePlanner.plan(batch, saves: saves, etags: etags, directories: directories)
            for (index, step) in steps.enumerated() {
                do {
                    try await perform(step.operation, service: service)
                } catch {
                    // Give back what was not written, ahead of anything newer.
                    let undone = Set(steps[index...].map(\.origin))
                    pending = batch.filter { undone.contains($0.path) } + pending
                    failed = true
                    break
                }
            }
        }
        writer = nil
        sleeper = nil
        if failed, !pending.isEmpty { schedule(after: Self.retry) }
    }

    private func perform(_ operation: GameSaveOperation, service: any GameFileService) async throws {
        switch operation {
        case .mkdir(let path):
            try await service.mkdir(path)
            directories.insert(path)
        case .put(let path, let data, let precondition):
            if conflicted.contains(path) { return try await writeConflictCopy(path, data, service: service) }
            switch try await service.put(path, data: data, precondition) {
            case .written(let etag):
                etags[path] = try await self.etag(etag, of: path, service: service)
            case .conflict:
                conflicted.insert(path)
                try await writeConflictCopy(path, data, service: service)
            }
        case .delete(let path, let ifMatch):
            try await service.delete(path, ifMatch: ifMatch)
            let inside = path + "/"
            etags = etags.filter { $0.key != path && !$0.key.hasPrefix(inside) }
            directories = directories.filter { $0 != path && !$0.hasPrefix(inside) }
            conflicted = conflicted.filter { $0 != path && !$0.hasPrefix(inside) }
        }
    }

    /// The device's version of a file the computer changed underneath it, beside the original.
    /// It replaces an earlier conflict copy of the same file, which was the device's too.
    private func writeConflictCopy(_ path: String, _ data: Data, service: any GameFileService) async throws {
        let copy = GameFiles.conflictPath(path, device: device)
        var precondition = etags[copy].map(GamePrecondition.match) ?? .create
        for _ in 0 ..< 2 {
            switch try await service.put(copy, data: data, precondition) {
            case .written(let etag):
                etags[copy] = try await self.etag(etag, of: copy, service: service)
                return
            case .conflict:
                precondition = try await service.stat(copy).map { .match($0.etag) } ?? .create
            }
        }
        throw GameFileError(status: 412, message: "The computer kept changing \(copy).")
    }

    /// The etag a write answered with, or the file's own when the answer had none.
    private func etag(_ answered: String?, of path: String, service: any GameFileService) async throws -> String? {
        if let answered { return answered }
        return try await service.stat(path)?.etag
    }

    // MARK: The page's messages

    /// The changes in a `changes` message from the page's shim, for database `mount`: entries
    /// outside the mount, or that do not parse, are dropped.
    nonisolated static func changes(_ list: [[String: Any]], mount: String) -> [GameSaveChange] {
        let prefix = GameFiles.mountPrefix(mount)
        return list.compactMap { entry in
            guard let path = entry["path"] as? String, path.hasPrefix(prefix), let kind = entry["kind"] as? String else { return nil }
            switch kind {
            case "file":
                guard let base64 = entry["data"] as? String, let data = Data(base64Encoded: base64) else { return nil }
                return GameSaveChange(path: path, kind: .file(data))
            case "directory": return GameSaveChange(path: path, kind: .directory)
            case "removed": return GameSaveChange(path: path, kind: .removed)
            default: return nil
            }
        }
    }

    static let noHost = GameFileError(status: nil, message: "This display connection has no way to reach the computer's files.")
}
