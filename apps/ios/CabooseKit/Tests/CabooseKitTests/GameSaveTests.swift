import Foundation
import Testing
@testable import CabooseKit

/// The computer's file service as save sync sees it, in memory: every request is recorded,
/// and the test says which fail.
final class FakeFileService: GameFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, etag: String)] = [:]
    private var directories: Set<String> = [""]
    private var version = 0
    private var log: [String] = []
    /// Requests that fail as if the computer could not be reached, before any is answered.
    var unreachable = 0

    init(files: [String: Data] = [:]) {
        for (path, data) in files { write(path, data) }
    }

    var requests: [String] { lock.withLock { log } }
    func clearRequests() { lock.withLock { log.removeAll() } }
    func file(_ path: String) -> Data? { lock.withLock { files[path]?.data } }
    func etag(_ path: String) -> String? { lock.withLock { files[path]?.etag } }

    /// A change on the computer, underneath the device.
    func write(_ path: String, _ data: Data) {
        lock.withLock {
            version += 1
            files[path] = (data, "\"v\(version)\"")
            for ancestor in GameFiles.ancestors(of: path) { directories.insert(ancestor) }
        }
    }

    private func record(_ entry: String) throws {
        try lock.withLock {
            log.append(entry)
            if unreachable > 0 {
                unreachable -= 1
                throw GameFileError(status: nil, message: "offline")
            }
        }
    }

    func list(_ path: String) async throws -> [GameFileItem]? {
        try record("list \(path)")
        return lock.withLock {
            guard directories.contains(path) else { return nil }
            let prefix = path.isEmpty ? "" : path + "/"
            func child(_ item: String) -> String? {
                guard item.hasPrefix(prefix), item != path else { return nil }
                let rest = item.dropFirst(prefix.count)
                return rest.contains("/") || rest.isEmpty ? nil : String(rest)
            }
            let folders = directories.compactMap(child).map { GameFileItem(name: $0, kind: "directory", size: 0, mtime: 1000, etag: "\"d\"") }
            let plain = files.compactMap { key, value in
                child(key).map { GameFileItem(name: $0, kind: "file", size: value.data.count, mtime: 2000, etag: value.etag) }
            }
            return (folders + plain).sorted { $0.name < $1.name }
        }
    }

    func stat(_ path: String) async throws -> GameFileItem? {
        try record("stat \(path)")
        return lock.withLock { files[path].map { GameFileItem(name: path, kind: "file", size: $0.data.count, mtime: 0, etag: $0.etag) } }
    }

    func download(_ path: String) async throws -> (data: Data, etag: String?) {
        try record("get \(path)")
        return try lock.withLock {
            guard let file = files[path] else { throw GameFileError(status: 404, message: "missing") }
            return (file.data, file.etag)
        }
    }

    func put(_ path: String, data: Data, _ precondition: GamePrecondition) async throws -> GameWriteResult {
        switch precondition {
        case .create: try record("put \(path) new")
        case .match(let etag): try record("put \(path) \(etag)")
        }
        return lock.withLock {
            switch precondition {
            case .create where files[path] != nil: return .conflict
            case .match(let etag) where files[path]?.etag != etag: return .conflict
            default:
                version += 1
                files[path] = (data, "\"v\(version)\"")
                return .written(etag: "\"v\(version)\"")
            }
        }
    }

    func mkdir(_ path: String) async throws {
        try record("mkdir \(path)")
        lock.withLock { _ = directories.insert(path) }
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        try record("delete \(path)" + (ifMatch.map { " \($0)" } ?? ""))
        lock.withLock {
            files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            directories = directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
    }
}

@Suite struct GameSavePlannerTests {
    let saves = [GameSave(mount: "/powder", path: "TPT")]

    @Test func directoriesThenFilesThenRemovalsDeepestFirst() {
        let steps = GameSavePlanner.plan([
            GameSaveChange(path: "/powder/Saves/old/a.cps", kind: .removed),
            GameSaveChange(path: "/powder/Saves/old", kind: .removed),
            GameSaveChange(path: "/powder/Stamps/s.stm", kind: .removed),
            GameSaveChange(path: "/powder/Saves/new/b.cps", kind: .file(Data([2]))),
            GameSaveChange(path: "/powder/powder.pref", kind: .file(Data([1]))),
            GameSaveChange(path: "/powder/Logs", kind: .directory),
        ], saves: saves, etags: ["TPT/powder.pref": "\"p\"", "TPT/Stamps/s.stm": "\"s\""], directories: ["TPT", "TPT/Saves"])
        #expect(steps.map(\.operation) == [
            .mkdir("TPT/Logs"),
            .put("TPT/powder.pref", Data([1]), .match("\"p\"")),
            .mkdir("TPT/Saves/new"),
            .put("TPT/Saves/new/b.cps", Data([2]), .create),
            .delete("TPT/Stamps/s.stm", ifMatch: "\"s\""),
            .delete("TPT/Saves/old", ifMatch: nil), // its file goes with it
        ])
        #expect(steps.map(\.origin) == ["/powder/Logs", "/powder/powder.pref", "/powder/Saves/new/b.cps", "/powder/Saves/new/b.cps",
                                        "/powder/Stamps/s.stm", "/powder/Saves/old"])
    }

    @Test func theLastChangeToAPathWinsAndOthersAreIgnored() {
        let steps = GameSavePlanner.plan([
            GameSaveChange(path: "/powder/a", kind: .file(Data([1]))),
            GameSaveChange(path: "/powder/a", kind: .removed),
            GameSaveChange(path: "/powder/a", kind: .file(Data([3]))),
            GameSaveChange(path: "/tmp/outside", kind: .file(Data([4]))),
            GameSaveChange(path: "/powder/../escape", kind: .file(Data([5]))),
        ], saves: saves, etags: [:], directories: ["TPT"])
        #expect(steps.map(\.operation) == [.put("TPT/a", Data([3]), .create)])
    }

    @Test func missingParentsAreMadeOutermostFirst() {
        let steps = GameSavePlanner.plan([GameSaveChange(path: "/powder/x/y/z.sav", kind: .file(Data()))],
                                         saves: [GameSave(mount: "/powder", path: ".local/share/TPT")], etags: [:], directories: [])
        #expect(steps.map(\.operation) == [.mkdir(".local"), .mkdir(".local/share"), .mkdir(".local/share/TPT"),
                                          .mkdir(".local/share/TPT/x"), .mkdir(".local/share/TPT/x/y"),
                                          .put(".local/share/TPT/x/y/z.sav", Data(), .create)])
    }

    @Test func thePagesChangesParse() {
        let changes = GameSaveSync.changes([
            ["path": "/powder/a.cps", "kind": "file", "data": Data([1, 2]).base64EncodedString()],
            ["path": "/powder/dir", "kind": "directory"],
            ["path": "/powder/gone", "kind": "removed"],
            ["path": "/elsewhere/a", "kind": "file", "data": ""],
            ["path": "/powderkeg/a", "kind": "removed"],
            ["path": "/powder/bad", "kind": "file", "data": "not base64!"],
            ["path": "/powder/odd", "kind": "socket"],
            ["kind": "removed"],
        ], mount: "/powder")
        #expect(changes == [GameSaveChange(path: "/powder/a.cps", kind: .file(Data([1, 2]))),
                            GameSaveChange(path: "/powder/dir", kind: .directory),
                            GameSaveChange(path: "/powder/gone", kind: .removed)])
    }

    @Test func theSeedIsJSONTheShimReads() throws {
        var seed = GameSeed(mounts: ["/powder", "/empty"])
        seed.entries["/powder"] = ["/powder/a": .file(mtime: 5, data: Data([0xFF])), "/powder/d": .directory(mtime: 6)]
        let json = try #require(try JSONSerialization.jsonObject(with: Data(seed.json().utf8)) as? [String: Any])
        #expect(json["mounts"] as? [String] == ["/powder", "/empty"])
        let entries = try #require(json["entries"] as? [String: [String: [String: Any]]])
        #expect(entries["/empty"]?.isEmpty == true)
        #expect(entries["/powder"]?["/powder/a"]?["data"] as? String == "/w==")
        #expect(entries["/powder"]?["/powder/a"]?["mtime"] as? Double == 5)
        #expect(entries["/powder"]?["/powder/d"]?["dir"] as? Bool == true)
    }
}

@MainActor @Suite struct GameSaveSyncTests {
    let saves = [GameSave(mount: "/powder", path: ".local/share/TPT")]
    let host = GameHostAccess(baseURL: URL(string: "https://computer.example")!, token: "t")

    func makeSync(_ service: FakeFileService) -> GameSaveSync {
        let host = host
        return GameSaveSync(saves: saves, device: "iPhone", cache: nil, host: { host }, makeService: { _ in service })
    }

    @Test func loadingListsEverySaveAndDownloadsItsFiles() async throws {
        let service = FakeFileService(files: [".local/share/TPT/powder.pref": Data("p".utf8),
                                              ".local/share/TPT/Saves/a.cps": Data("a".utf8),
                                              ".local/share/Other/x": Data("x".utf8)])
        let sync = makeSync(service)
        let seed = try await sync.load()
        #expect(seed.mounts == ["/powder"])
        #expect(seed.entries["/powder"] == [
            "/powder/powder.pref": .file(mtime: 2000, data: Data("p".utf8)),
            "/powder/Saves": .directory(mtime: 1000),
            "/powder/Saves/a.cps": .file(mtime: 2000, data: Data("a".utf8)),
        ])
        #expect(sync.etags[".local/share/TPT/Saves/a.cps"] == service.etag(".local/share/TPT/Saves/a.cps"))
        #expect(sync.directories.isSuperset(of: [".local", ".local/share", ".local/share/TPT", ".local/share/TPT/Saves"]))
    }

    @Test func aSaveThatDoesNotExistYetIsEmptyAndMadeOnTheFirstWrite() async throws {
        let service = FakeFileService()
        let sync = makeSync(service)
        let seed = try await sync.load()
        #expect(seed.entries["/powder"] == [:])
        service.clearRequests()
        sync.record([GameSaveChange(path: "/powder/powder.pref", kind: .file(Data("1".utf8)))])
        await sync.flush()
        #expect(service.requests == ["mkdir .local", "mkdir .local/share", "mkdir .local/share/TPT",
                                     "put .local/share/TPT/powder.pref new"])
        #expect(service.file(".local/share/TPT/powder.pref") == Data("1".utf8))
        #expect(sync.isIdle)
    }

    @Test func writesCarryTheEtagLastSeen() async throws {
        let service = FakeFileService(files: [".local/share/TPT/powder.pref": Data("0".utf8)])
        let sync = makeSync(service)
        _ = try await sync.load()
        let first = try #require(service.etag(".local/share/TPT/powder.pref"))
        service.clearRequests()
        sync.record([GameSaveChange(path: "/powder/powder.pref", kind: .file(Data("1".utf8)))])
        await sync.flush()
        let second = try #require(service.etag(".local/share/TPT/powder.pref"))
        sync.record([GameSaveChange(path: "/powder/powder.pref", kind: .file(Data("2".utf8)))])
        sync.record([GameSaveChange(path: "/powder/powder.pref", kind: .removed)])
        sync.record([GameSaveChange(path: "/powder/powder.pref", kind: .file(Data("3".utf8)))])
        await sync.flush()
        #expect(service.requests == ["put .local/share/TPT/powder.pref \(first)", "put .local/share/TPT/powder.pref \(second)"])
        #expect(service.file(".local/share/TPT/powder.pref") == Data("3".utf8))
    }

    @Test func aChangeOnTheComputerKeepsBothVersions() async throws {
        let service = FakeFileService(files: [".local/share/TPT/save.cps": Data("device saw".utf8)])
        let sync = makeSync(service)
        _ = try await sync.load()
        service.write(".local/share/TPT/save.cps", Data("computer".utf8))
        sync.record([GameSaveChange(path: "/powder/save.cps", kind: .file(Data("device 1".utf8)))])
        await sync.flush()
        #expect(service.file(".local/share/TPT/save.cps") == Data("computer".utf8))
        #expect(service.file(".local/share/TPT/save (iPhone).cps") == Data("device 1".utf8))
        // Later writes of the file go on to its copy.
        sync.record([GameSaveChange(path: "/powder/save.cps", kind: .file(Data("device 2".utf8)))])
        await sync.flush()
        #expect(service.file(".local/share/TPT/save.cps") == Data("computer".utf8))
        #expect(service.file(".local/share/TPT/save (iPhone).cps") == Data("device 2".utf8))
        #expect(sync.conflicted == [".local/share/TPT/save.cps"])
    }

    @Test func aNewFileTheComputerMadeMeanwhileIsKeptToo() async throws {
        let service = FakeFileService()
        let sync = makeSync(service)
        _ = try await sync.load()
        service.write(".local/share/TPT/new.cps", Data("computer".utf8))
        sync.record([GameSaveChange(path: "/powder/new.cps", kind: .file(Data("device".utf8)))])
        await sync.flush()
        #expect(service.file(".local/share/TPT/new.cps") == Data("computer".utf8))
        #expect(service.file(".local/share/TPT/new (iPhone).cps") == Data("device".utf8))
    }

    @Test func whatCouldNotBeWrittenIsTriedAgain() async throws {
        let service = FakeFileService(files: [".local/share/TPT/a": Data("0".utf8)])
        let sync = makeSync(service)
        _ = try await sync.load()
        service.unreachable = 1
        sync.record([GameSaveChange(path: "/powder/a", kind: .file(Data("1".utf8))),
                     GameSaveChange(path: "/powder/b", kind: .file(Data("2".utf8)))])
        await sync.flush()
        #expect(service.file(".local/share/TPT/a") == Data("0".utf8))
        #expect(!sync.isIdle)
        await sync.flush()
        #expect(service.file(".local/share/TPT/a") == Data("1".utf8))
        #expect(service.file(".local/share/TPT/b") == Data("2".utf8))
        #expect(sync.isIdle)
    }

    @Test func removalsGoToTheTrashWithTheirEtag() async throws {
        let service = FakeFileService(files: [".local/share/TPT/Saves/a.cps": Data("a".utf8), ".local/share/TPT/Saves/b.cps": Data("b".utf8)])
        let sync = makeSync(service)
        _ = try await sync.load()
        let etag = try #require(service.etag(".local/share/TPT/Saves/a.cps"))
        service.clearRequests()
        sync.record([GameSaveChange(path: "/powder/Saves/a.cps", kind: .removed)])
        await sync.flush()
        #expect(service.requests == ["delete .local/share/TPT/Saves/a.cps \(etag)"])
        sync.record([GameSaveChange(path: "/powder/Saves/b.cps", kind: .removed), GameSaveChange(path: "/powder/Saves", kind: .removed)])
        await sync.flush()
        #expect(service.requests.last == "delete .local/share/TPT/Saves")
        // The directory is gone: a new save in it makes it again.
        sync.record([GameSaveChange(path: "/powder/Saves/c.cps", kind: .file(Data("c".utf8)))])
        await sync.flush()
        #expect(service.requests.suffix(2) == ["mkdir .local/share/TPT/Saves", "put .local/share/TPT/Saves/c.cps new"])
    }

    @Test func savesWaitUntilTheyAreFlushedOrTheirDelay() async throws {
        let service = FakeFileService()
        let sync = makeSync(service)
        _ = try await sync.load()
        service.clearRequests()
        sync.record([GameSaveChange(path: "/powder/a", kind: .file(Data()))])
        #expect(service.requests.isEmpty)
        #expect(!sync.isIdle)
        let deadline = Date().addingTimeInterval(4)
        while !sync.isIdle, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sync.isIdle)
        #expect(service.requests.last == "put .local/share/TPT/a new")
    }
}
