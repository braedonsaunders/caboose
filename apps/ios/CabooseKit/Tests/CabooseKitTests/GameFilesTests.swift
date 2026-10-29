import Foundation
import Testing
@testable import CabooseKit

/// The rules a handed-off game's files follow (docs/game-handoff.md): where its URLs point,
/// what each response says, where the device keeps the files, and where saves go.
@Suite struct GameFilesTests {
    let root = ".local/share/caboose/games/powder-toy/web"

    @Test func pathsResolveAgainstTheRoot() {
        #expect(GameFiles.resolve("/index.html", root: root) == .file("\(root)/index.html"))
        #expect(GameFiles.resolve("/data/levels/1.json", root: root) == .file("\(root)/data/levels/1.json"))
        #expect(GameFiles.resolve("//data/./levels//1.json", root: root) == .file("\(root)/data/levels/1.json"))
        #expect(GameFiles.resolve("/data/../index.html", root: root) == .file("\(root)/index.html"))
        #expect(GameFiles.resolve("/index.html", root: "") == .file("index.html"))
        #expect(GameFiles.resolve("/a b/ü.js", root: "web/") == .file("web/a b/ü.js"))
    }

    @Test func escapesAreForbiddenAndTheOriginIsNotFound() {
        #expect(GameFiles.resolve("/../secret", root: root) == .forbidden)
        #expect(GameFiles.resolve("/data/../../web/index.html", root: root) == .forbidden)
        #expect(GameFiles.resolve("/..", root: root) == .forbidden)
        #expect(GameFiles.resolve("/index.html\u{0}.png", root: root) == .forbidden)
        #expect(GameFiles.resolve("/", root: root) == .notFound)
        #expect(GameFiles.resolve("", root: root) == .notFound)
        #expect(GameFiles.resolve("/data/..", root: root) == .notFound)
    }

    @Test func singleByteRangesParse() {
        #expect(GameByteRange(header: "bytes=0-99") == .from(0, through: 99))
        #expect(GameByteRange(header: "bytes=100-") == .from(100, through: nil))
        #expect(GameByteRange(header: "bytes=-500") == .suffix(500))
        #expect(GameByteRange(header: " Bytes=5-9 ") == .from(5, through: 9))
        for header in ["bytes=0-1,4-5", "bytes=9-3", "bytes=-", "bytes=a-b", "items=0-1", "bytes=0x1-2", "0-1", "bytes=١-٢"] {
            #expect(GameByteRange(header: header) == nil, "\(header)")
        }
    }

    @Test func rangesClampToTheFile() {
        #expect(GameByteRange.from(0, through: 99).bytes(ofSize: 50) == 0 ... 49)
        #expect(GameByteRange.from(10, through: nil).bytes(ofSize: 50) == 10 ... 49)
        #expect(GameByteRange.from(50, through: nil).bytes(ofSize: 50) == nil)
        #expect(GameByteRange.suffix(10).bytes(ofSize: 50) == 40 ... 49)
        #expect(GameByteRange.suffix(500).bytes(ofSize: 50) == 0 ... 49)
        #expect(GameByteRange.suffix(0).bytes(ofSize: 50) == nil)
        #expect(GameByteRange.from(0, through: 0).bytes(ofSize: 0) == nil)
    }

    @Test func contentTypesComeFromTheExtension() {
        #expect(GameFiles.contentType(of: "web/powder.wasm") == "application/wasm")
        #expect(GameFiles.contentType(of: "web/POWDER.WASM") == "application/wasm")
        #expect(GameFiles.contentType(of: "web/powder.js") == "text/javascript")
        #expect(GameFiles.contentType(of: "web/worker.mjs") == "text/javascript")
        #expect(GameFiles.contentType(of: "index.html") == "text/html")
        #expect(GameFiles.contentType(of: "a/b.json") == "application/json")
        #expect(GameFiles.contentType(of: "a/b.data") == "application/octet-stream")
        #expect(GameFiles.contentType(of: "a/.hidden") == "application/octet-stream")
        #expect(GameFiles.contentType(of: "a/README") == "application/octet-stream")
    }

    @Test func everyResponseIsCrossOriginIsolated() {
        let headers = GameFiles.responseHeaders(for: "web/powder.wasm", length: 1234, contentRange: "bytes 0-1233/5000")
        #expect(headers["Cross-Origin-Opener-Policy"] == "same-origin")
        #expect(headers["Cross-Origin-Embedder-Policy"] == "require-corp")
        #expect(headers["Cross-Origin-Resource-Policy"] == "same-origin")
        #expect(headers["Content-Type"] == "application/wasm")
        #expect(headers["Content-Length"] == "1234")
        #expect(headers["Content-Range"] == "bytes 0-1233/5000")
        #expect(headers["Accept-Ranges"] == "bytes")
        #expect(headers["Cache-Control"] == "no-store")
        #expect(headers["X-Content-Type-Options"] == "nosniff")
        #expect(GameFiles.responseHeaders(for: "index.html", length: nil)["Content-Length"] == nil)
    }

    @Test func theCacheKeyNamesOneComputersFileAtOneVersion() {
        let key = GameFiles.cacheKey(computer: "c1", path: "web/powder.wasm", etag: "\"a\"")
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit))
        #expect(key == GameFiles.cacheKey(computer: "c1", path: "web/powder.wasm", etag: "\"a\""))
        #expect(key != GameFiles.cacheKey(computer: "c2", path: "web/powder.wasm", etag: "\"a\""))
        #expect(key != GameFiles.cacheKey(computer: "c1", path: "web/powder.js", etag: "\"a\""))
        #expect(key != GameFiles.cacheKey(computer: "c1", path: "web/powder.wasm", etag: "\"b\""))
        // The parts are kept apart: moving a character from one to the next is another key.
        #expect(GameFiles.cacheKey(computer: "ab", path: "c", etag: "d") != GameFiles.cacheKey(computer: "a", path: "bc", etag: "d"))
    }

    @Test func conflictCopiesGoBesideTheOriginal() {
        #expect(GameFiles.conflictPath(".local/share/TPT/save.cps", device: "iPhone") == ".local/share/TPT/save (iPhone).cps")
        #expect(GameFiles.conflictPath("powder.pref", device: "iPad") == "powder (iPad).pref")
        #expect(GameFiles.conflictPath("saves/archive.tar.gz", device: "iPhone") == "saves/archive.tar (iPhone).gz")
        #expect(GameFiles.conflictPath("saves/.config", device: "iPhone") == "saves/.config (iPhone)")
        #expect(GameFiles.conflictPath("saves/SAVEGAME", device: "iPad") == "saves/SAVEGAME (iPad)")
    }

    @Test func savePathsMapBetweenTheGameAndTheComputer() {
        let saves = [GameSave(mount: "/powder", path: ".local/share/The Powder Toy"), GameSave(mount: "/powder/stamps", path: "Stamps")]
        #expect(GameFiles.hostPath("/powder/powder.pref", saves: saves) == ".local/share/The Powder Toy/powder.pref")
        #expect(GameFiles.hostPath("/powder/Saves/a.cps", saves: saves) == ".local/share/The Powder Toy/Saves/a.cps")
        #expect(GameFiles.hostPath("/powder/stamps/s.stm", saves: saves) == "Stamps/s.stm") // the deepest mount
        #expect(GameFiles.hostPath("/powder", saves: saves) == nil)
        #expect(GameFiles.hostPath("/powderkeg/x", saves: saves) == nil)
        #expect(GameFiles.hostPath("/tmp/x", saves: saves) == nil)
        #expect(GameFiles.hostPath("/powder/../etc/passwd", saves: saves) == nil)
        #expect(GameFiles.hostPath("/powder/./x", saves: saves) == nil)
        #expect(GameFiles.hostPath("/powder//x", saves: saves) == nil)
        #expect(GameFiles.hostPath("powder/x", saves: saves) == nil)

        #expect(GameFiles.virtualPath(".local/share/The Powder Toy/Saves/a.cps", in: saves[0]) == "/powder/Saves/a.cps")
        #expect(GameFiles.virtualPath(".local/share/The Powder Toy", in: saves[0]) == nil)
        #expect(GameFiles.virtualPath(".local/share/The Powder Toyz/a", in: saves[0]) == nil)
        #expect(GameFiles.virtualPath("a.sav", in: GameSave(mount: "/home", path: "")) == "/home/a.sav")
        #expect(GameFiles.ancestors(of: "a/b/c") == ["a", "a/b"])
        #expect(GameFiles.ancestors(of: "a") == [])
    }

    @Test func theHostIsBehindTheDisplaySocket() throws {
        let secure = try #require(GameHostAccess(displayURL: URL(string: "wss://computer.example:8443/v1/display")!, token: "tok"))
        #expect(secure.baseURL.absoluteString == "https://computer.example:8443")
        #expect(secure.fileURL("stat", path: "web/a b&c.js").absoluteString
            == "https://computer.example:8443/v1/fs/stat?path=web/a%20b%26c.js")
        let request = secure.request("content", path: "x", method: "PUT")
        #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let prefixed = try #require(GameHostAccess(displayURL: URL(string: "ws://10.0.0.2/caboose/v1/display?seat=owner")!, token: "tok"))
        #expect(prefixed.baseURL.absoluteString == "http://10.0.0.2/caboose")
        #expect(prefixed.fileURL("list", path: "").absoluteString == "http://10.0.0.2/caboose/v1/fs/list?path=")
        #expect(GameHostAccess(displayURL: URL(string: "file:///v1/display")!, token: "tok") == nil)
        // One computer, one cache, whichever address it was reached through.
        #expect(secure.computerKey == prefixed.computerKey)
        #expect(secure.computerKey != GameHostAccess(baseURL: secure.baseURL, token: "other").computerKey)
    }

}

@Suite struct GameCacheTests {
    func makeCache(budget: Int) throws -> GameCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("game-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return GameCache(directory: directory, budget: budget)
    }

    @Test func storedFilesAreFoundByKey() throws {
        let cache = try makeCache(budget: 1000)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        #expect(cache.file("a") == nil)
        cache.store(Data("hello".utf8), as: "a")
        #expect(cache.data("a") == Data("hello".utf8))
        // A second copy of the same version keeps the first.
        cache.store(Data("other".utf8), as: "a")
        #expect(cache.data("a") == Data("hello".utf8))
        let staged = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(staged == ["a"])
    }

    @Test func theLeastRecentlyUsedGoFirst() throws {
        let cache = try makeCache(budget: 250)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let hundred = Data(repeating: 1, count: 100)
        for (index, key) in ["used", "old"].enumerated() {
            cache.store(hundred, as: key)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)],
                                                  ofItemAtPath: cache.directory.appendingPathComponent(key).path)
        }
        _ = cache.data("used") // stored first, used since
        cache.store(hundred, as: "new") // over the budget: the least recently used goes
        #expect(cache.file("old") == nil)
        #expect(cache.file("used") != nil && cache.file("new") != nil)
    }

    @Test func abandonedDownloadsAreCleared() throws {
        let cache = try makeCache(budget: 1000)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let fresh = cache.stagingFile(), stale = cache.stagingFile()
        try Data([1]).write(to: fresh)
        try Data([1]).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: stale.path)
        cache.evict()
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}

@Suite struct GameGamepadTests {
    @Test func stateIsOneValuePerStandardButtonAndAxis() {
        var state = GameGamepadState()
        state[.south] = 1
        state[.rightTrigger] = 0.4
        state[.home] = 3
        state[.leftX] = -2
        state[.rightY] = .nan
        let values = state.normalized
        #expect(values.buttons.count == 17 && values.axes.count == 4)
        #expect(values.buttons[0] == 1 && values.buttons[7] == 0.4 && values.buttons[16] == 1 && values.buttons[1] == 0)
        #expect(values.axes == [-1, 0, 0, 0])
        #expect(GameGamepadState(buttons: Array(repeating: 1, count: 30), axes: [0.5]).normalized.buttons.count == 17)
    }

    @Test func theCallCarriesTheStateOrDisconnects() {
        let update = GameGamepadScript.call(GameGamepadState(buttons: [1], axes: [0, 0.5]))
        #expect(update.body.contains("update(buttons, axes)"))
        #expect((update.arguments["axes"] as? [Double]) == [0, 0.5, 0, 0])
        #expect((update.arguments["buttons"] as? [Double])?.first == 1)
        let off = GameGamepadScript.call(nil)
        #expect(off.body.contains("disconnect()") && off.arguments.isEmpty)
    }
}
