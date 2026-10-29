import Foundation
import Network
import Testing
@testable import CabooseKit

/// A game's files in memory, as the computer's `/v1/fs` would give them: every `stream` is
/// recorded, with the `Range` it carried.
final class MemoryGameFiles: GameFileSource, @unchecked Sendable {
    let computerKey = "memory-computer"
    private let lock = NSLock()
    private var files: [String: (data: Data, etag: String)]
    private var log: [String] = []

    init(_ files: [String: Data]) {
        self.files = files.mapValues { ($0, "\"\($0.count)\"") }
    }

    /// `content <path>` or `content <path> <range>`, one for each download.
    var streams: [String] { lock.withLock { log } }

    func stat(_ path: String) async throws -> GameFileItem? {
        lock.withLock {
            if let file = files[path] {
                return GameFileItem(name: String(path.split(separator: "/").last ?? ""), kind: "file", size: file.data.count, mtime: 0, etag: file.etag)
            }
            let inside = path + "/"
            return files.keys.contains { $0.hasPrefix(inside) } ? GameFileItem(name: path, kind: "directory", size: 0, mtime: 0, etag: "") : nil
        }
    }

    func stream(_ path: String, range: String?, teeInto file: URL?) -> any GameTransfer {
        let found = lock.withLock {
            log.append(["content", path, range].compactMap { $0 }.joined(separator: " "))
            return files[path]
        }
        return MemoryTransfer(found, range: range, teeInto: file)
    }
}

/// The computer's answer for one file, delivered in two chunks.
final class MemoryTransfer: GameTransfer, @unchecked Sendable {
    let events: AsyncThrowingStream<GameTransferEvent, Error>
    let stagedFile: URL?
    let teed: Bool

    init(_ file: (data: Data, etag: String)?, range: String?, teeInto url: URL?) {
        stagedFile = url
        let place = URL(string: "https://computer.example/v1/fs/content")!
        var body = Data()
        let response: HTTPURLResponse
        if let file {
            if let range, let bytes = GameByteRange(header: range)?.bytes(ofSize: file.data.count) {
                body = file.data[bytes]
                response = HTTPURLResponse(url: place, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Length": String(body.count), "Content-Range": "bytes \(bytes.lowerBound)-\(bytes.upperBound)/\(file.data.count)",
                ])!
            } else if range != nil {
                response = HTTPURLResponse(url: place, statusCode: 416, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": "bytes */\(file.data.count)"])!
            } else {
                body = file.data
                response = HTTPURLResponse(url: place, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(body.count), "ETag": file.etag])!
            }
        } else {
            response = HTTPURLResponse(url: place, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        }
        teed = url.map { (try? body.write(to: $0)) != nil } ?? false
        let half = body.startIndex + body.count / 2
        let chunks = [body[..<half], body[half...]].map { Data($0) }
        events = AsyncThrowingStream { continuation in
            continuation.yield(.response(response))
            for chunk in chunks where !chunk.isEmpty { continuation.yield(.data(chunk)) }
            continuation.finish()
        }
    }
}

/// What a sink was given.
@MainActor
final class RecordedResponse: GameResponseSink {
    var isLive = true
    var status: Int?
    var headers: [String: String] = [:]
    var body = Data()
    var finished = false
    var aborted = false

    func start(_ status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }

    func send(_ data: Data) async { body.append(data) }
    func finish() { finished = true }
    func abort() { aborted = true }
}

/// Waits, for up to three seconds, for `condition`.
@MainActor func eventually(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        if Date() > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func temporaryGameCache() throws -> GameCache {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("game-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return GameCache(directory: directory, budget: 1 << 24)
}

/// A game's loopback origin (docs/game-handoff.md, "Files"): its URLs, the requests it takes,
/// and what it answers.
@Suite struct GameHTTPTests {
    let origin = GameOrigin(port: 49152, token: "0123456789abcdef0123456789abcdef")
    let root = ".local/share/caboose/games/powder-toy/web"

    func make(_ target: String, method: String = "GET", fields: [String: String] = [:]) -> GameHTTP.Request {
        var all = ["host": [origin.authority]]
        for (name, value) in fields { all[name.lowercased()] = [value] }
        return GameHTTP.Request(method: method, target: target, version: "HTTP/1.1", fields: all)
    }

    func parse(_ text: String) -> GameHTTP.Parse { GameHTTP.parse(Data(text.utf8)) }

    @Test func tokensAreUnguessableHex() {
        let tokens = (0 ..< 32).map { _ in GameOrigin.newToken() }
        #expect(tokens.allSatisfy { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
        #expect(Set(tokens).count == tokens.count)
        #expect(GameHTTP.sameToken("0123456789abcdef0123456789abcdef", origin.token))
        #expect(!GameHTTP.sameToken("0123456789abcdef0123456789abcdee", origin.token))
        #expect(!GameHTTP.sameToken("0123456789abcdef", origin.token))
        #expect(!GameHTTP.sameToken("", origin.token))
    }

    @Test func theOriginIsTheGamesAlone() throws {
        let entry = try #require(origin.url("pages/index.html"))
        #expect(entry.absoluteString == "http://127.0.0.1:49152/0123456789abcdef0123456789abcdef/pages/index.html")
        #expect(origin.url("a b/ü.js")?.absoluteString == "http://127.0.0.1:49152/0123456789abcdef0123456789abcdef/a%20b/%C3%BC.js")
        #expect(origin.contains(entry))
        #expect(origin.contains(URL(string: "http://127.0.0.1:49152/0123456789abcdef0123456789abcdef/worker.js?x=1")!))
        for other in ["http://127.0.0.1:49153/0123456789abcdef0123456789abcdef/index.html",
                      "https://127.0.0.1:49152/0123456789abcdef0123456789abcdef/index.html",
                      "http://localhost:49152/0123456789abcdef0123456789abcdef/index.html",
                      "http://127.0.0.1:49152/index.html",
                      "http://127.0.0.1:49152/0123456789abcdef0123456789abcdef",
                      "http://127.0.0.1:49152/0123456789abcdef0123456789abcdeff/index.html",
                      "https://example.com/0123456789abcdef0123456789abcdef/index.html"] {
            #expect(!origin.contains(URL(string: other)!), "\(other)")
        }
    }

    @Test func requestHeadsParse() throws {
        let parsed = parse("GET /t/index.html?v=2 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nRange:  bytes=0-9 \r\nAccept: */*\r\nAccept: text/html\r\n\r\n")
        guard case .request(let request) = parsed else { Issue.record("\(parsed)"); return }
        #expect(request.method == "GET" && request.target == "/t/index.html?v=2" && request.version == "HTTP/1.1")
        #expect(request.value("host") == "127.0.0.1:1" && request.value("RANGE") == "bytes=0-9")
        #expect(request.value("accept") == nil) // sent twice
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .incomplete)
        #expect(parse("") == .incomplete)
        guard case .request = parse("HEAD / HTTP/1.0\r\n\r\n") else { Issue.record("HTTP/1.0"); return }
    }

    @Test func malformedHeadsAreRefused() {
        for (head, status) in [
            ("GET /\r\n\r\n", 400),
            ("GET  / HTTP/1.1\r\n\r\n", 400),
            ("G(T / HTTP/1.1\r\n\r\n", 400),
            ("GET / HTTP/2\r\n\r\n", 505),
            ("GET / FTP/1.1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost : 127.0.0.1\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n", 400),
            ("GET / HTTP/1.1\nHost: a\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: a\rb\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: ü\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nHost: a\u{0}\r\n\r\n", 400),
            ("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello", 400),
            ("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
        ] {
            #expect(parse(head) == .reject(status), "\(head.debugDescription)")
        }
        guard case .request = parse("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n") else { Issue.record("empty body"); return }
    }

    @Test func anOversizedHeadIsRefused() {
        let big = "GET / HTTP/1.1\r\nCookie: " + String(repeating: "a", count: GameHTTP.maxHeadBytes) + "\r\n\r\n"
        #expect(parse(big) == .reject(431))
        // Refused as soon as the bound is passed, before the head ends.
        #expect(GameHTTP.parse(Data(String(repeating: "a", count: 101).utf8), limit: 100) == .reject(431))
        #expect(GameHTTP.parse(Data(String(repeating: "a", count: 100).utf8), limit: 100) == .incomplete)
        let exact = "GET / HTTP/1.1\r\n\r\n"
        guard case .request = GameHTTP.parse(Data(exact.utf8), limit: exact.utf8.count) else { Issue.record("at the bound"); return }
        #expect(GameHTTP.parse(Data(exact.utf8), limit: exact.utf8.count - 1) == .reject(431))
    }

    @Test func requestsRouteToTheGamesFiles() {
        let token = origin.token
        #expect(GameHTTP.route(make("/\(token)/index.html"), origin: origin, root: root) == .file(path: "\(root)/index.html", range: nil, head: false))
        #expect(GameHTTP.route(make("/\(token)/data/a%20b.json?cache=1#x"), origin: origin, root: root)
            == .file(path: "\(root)/data/a b.json", range: nil, head: false))
        #expect(GameHTTP.route(make("/\(token)/powder.wasm", method: "HEAD", fields: ["Range": "bytes=0-1"]), origin: origin, root: root)
            == .file(path: "\(root)/powder.wasm", range: "bytes=0-1", head: true))
        #expect(GameHTTP.route(make("/\(token)/data/../index.html"), origin: origin, root: root) == .file(path: "\(root)/index.html", range: nil, head: false))
    }

    @Test func requestsWithoutTheTokenOrOutsideTheRootAreRefused() {
        let token = origin.token
        for (target, status) in [
            ("/index.html", 404), ("/", 404), ("/\(token)", 404), ("/\(token)/", 404),
            ("/\(token.dropLast())/index.html", 404), ("/\(token)0/index.html", 404),
            ("/\(token.uppercased())/index.html", 404),
            ("/\(token)/../index.html", 403), ("/\(token)/%2e%2e/secret", 403), ("/\(token)/a/..%2F..%2F..%2Fsecret", 403),
            ("/\(token)/index.html%00.png", 403), ("/\(token)/%zz", 400),
            ("http://127.0.0.1:49152/\(token)/index.html", 400), ("*", 400),
        ] {
            #expect(GameHTTP.route(make(target), origin: origin, root: root) == .status(status), "\(target)")
        }
    }

    @Test func onlyGetAndHeadAreServed() {
        for method in ["POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT", "get"] {
            #expect(GameHTTP.route(make("/\(origin.token)/index.html", method: method), origin: origin, root: root) == .status(405), "\(method)")
        }
        #expect(GameHTTP.statusHeaders(405)["Allow"] == "GET, HEAD")
    }

    /// A page elsewhere that names 127.0.0.1 (DNS rebinding, for one) is refused.
    @Test func theHostMustBeTheOrigin() {
        let target = "/\(origin.token)/index.html"
        for hosts in [[], ["evil.example:49152"], ["127.0.0.1"], ["127.0.0.1:49153"], ["localhost:49152"], [origin.authority, origin.authority]] {
            var request = make(target)
            request.fields["host"] = hosts
            #expect(GameHTTP.route(request, origin: origin, root: root) == .status(400), "\(hosts)")
        }
    }

    @Test func responseHeadsAreIsolatedAndSafe() {
        let head = String(decoding: GameHTTP.head(206, headers: GameFiles.responseHeaders(for: "a.wasm", length: 10, contentRange: "bytes 0-9/20")), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n") && head.hasSuffix("\r\n\r\n"))
        for line in ["Cross-Origin-Opener-Policy: same-origin", "Cross-Origin-Embedder-Policy: require-corp",
                     "Cross-Origin-Resource-Policy: same-origin", "Cache-Control: no-store", "Connection: close",
                     "Content-Type: application/wasm", "Content-Length: 10", "Content-Range: bytes 0-9/20"] {
            #expect(head.contains("\r\n\(line)\r\n"), "\(line)")
        }
        let injected = String(decoding: GameHTTP.head(200, headers: ["Content-Range": "x\r\nSet-Cookie: a=b", "Bad Name": "v", "Ok": "v"]), as: UTF8.self)
        #expect(!injected.contains("Set-Cookie") && !injected.contains("Bad Name") && injected.contains("\r\nOk: v\r\n"))
        let error = GameHTTP.statusHeaders(404)
        #expect(error["Cross-Origin-Embedder-Policy"] == "require-corp" && error["Content-Length"] == "0" && error["Content-Type"] == "text/plain")
    }

    @Test func declineReasonsAreBoundedOnACharacterBoundary() {
        #expect(GameDecline.bounded("short") == "short")
        let accents = GameDecline.bounded(String(repeating: "é", count: 150))
        #expect(accents.utf8.count == 200 && accents == String(repeating: "é", count: 100))
        let family = GameDecline.bounded("a" + String(repeating: "👨‍👩‍👧", count: 20))
        #expect(family.utf8.count <= 200 && family.unicodeScalars.count % 5 == 1)
        let frame = ClientMessage.gameDecline(id: 3, reason: String(repeating: "x", count: 500)).frame
        #expect(frame.type == 0x97 && frame.body["id"]?.int == 3)
        #expect(frame.body["reason"] == .text(String(repeating: "x", count: 200)))
    }

    @Test func aSecondEndingWithinAMinuteIsTheLast() {
        var terminations = GameTerminations()
        let start = Date()
        let first = terminations.record(start)
        let longAfter = terminations.record(start.addingTimeInterval(61))
        let soonAfter = terminations.record(start.addingTimeInterval(90))
        #expect(!first)
        #expect(!longAfter)
        #expect(soonAfter)
    }
}

/// What a game's origin answers for its files, through a recording sink.
@MainActor @Suite struct GameFileResponderTests {
    let wasm = Data((0 ..< 1000).map { UInt8($0 % 251) })

    func respond(_ responder: GameFileResponder, _ path: String, range: String? = nil, head: Bool = false,
                 sink: RecordedResponse? = nil) async -> RecordedResponse {
        let sink = sink ?? RecordedResponse()
        await responder.respond(path: path, range: range, head: head, to: sink)
        return sink
    }

    @Test func aFileStreamsFromTheComputerThenComesFromTheCache() async throws {
        let cache = try temporaryGameCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let files = MemoryGameFiles(["web/powder.wasm": wasm])
        let responder = GameFileResponder(cache: cache, source: { files })
        let first = await respond(responder, "web/powder.wasm")
        #expect(first.status == 200 && first.body == wasm && first.finished && !first.aborted)
        #expect(first.headers["Content-Type"] == "application/wasm" && first.headers["Content-Length"] == "1000")
        #expect(first.headers["Cross-Origin-Embedder-Policy"] == "require-corp")
        let key = GameFiles.cacheKey(computer: files.computerKey, path: "web/powder.wasm", etag: "\"1000\"")
        try await eventually("cached") { cache.file(key) != nil }

        let second = await respond(responder, "web/powder.wasm")
        #expect(second.status == 200 && second.body == wasm)
        #expect(files.streams == ["content web/powder.wasm"]) // once
    }

    @Test func rangesComeFromTheCacheOrPassThrough() async throws {
        let cache = try temporaryGameCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let files = MemoryGameFiles(["web/powder.wasm": wasm])
        let responder = GameFileResponder(cache: cache, source: { files })
        // Not cached: the computer answers the range, and nothing is cached.
        let passed = await respond(responder, "web/powder.wasm", range: "bytes=10-19")
        #expect(passed.status == 206 && passed.body == wasm[10 ... 19] && passed.headers["Content-Range"] == "bytes 10-19/1000")
        #expect(files.streams == ["content web/powder.wasm bytes=10-19"])
        let refused = await respond(responder, "web/powder.wasm", range: "bytes=5000-")
        #expect(refused.status == 416 && refused.headers["Content-Range"] == "bytes */1000" && refused.body.isEmpty)

        _ = await respond(responder, "web/powder.wasm")
        let key = GameFiles.cacheKey(computer: files.computerKey, path: "web/powder.wasm", etag: "\"1000\"")
        try await eventually("cached") { cache.file(key) != nil }
        let cached = await respond(responder, "web/powder.wasm", range: "bytes=-100")
        #expect(cached.status == 206 && cached.body == wasm[900...] && cached.headers["Content-Range"] == "bytes 900-999/1000")
        #expect(cached.headers["Content-Length"] == "100")
        let beyond = await respond(responder, "web/powder.wasm", range: "bytes=1000-")
        #expect(beyond.status == 416 && beyond.headers["Content-Range"] == "bytes */1000")
        // A malformed range is answered with the whole file.
        let whole = await respond(responder, "web/powder.wasm", range: "bytes=9-3")
        #expect(whole.status == 200 && whole.body == wasm)
        #expect(files.streams.count == 3)
    }

    @Test func missingFilesAndDirectoriesAreNotFound() async throws {
        let cache = try temporaryGameCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let files = MemoryGameFiles(["web/data/a.json": Data("{}".utf8)])
        let responder = GameFileResponder(cache: cache, source: { files })
        #expect(await respond(responder, "web/missing.js").status == 404)
        #expect(await respond(responder, "web/data").status == 404)
        let unreachable = GameFileResponder(cache: cache, source: { nil })
        #expect(await respond(unreachable, "web/data/a.json").status == 502)
    }

    @Test func headIsAnsweredFromTheStatAlone() async throws {
        let cache = try temporaryGameCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let files = MemoryGameFiles(["web/powder.wasm": wasm])
        let responder = GameFileResponder(cache: cache, source: { files })
        let whole = await respond(responder, "web/powder.wasm", head: true)
        #expect(whole.status == 200 && whole.headers["Content-Length"] == "1000" && whole.body.isEmpty && whole.finished)
        let part = await respond(responder, "web/powder.wasm", range: "bytes=0-9", head: true)
        #expect(part.status == 206 && part.headers["Content-Range"] == "bytes 0-9/1000" && part.body.isEmpty)
        #expect(files.streams.isEmpty)
    }

    /// A request that is gone by the time the computer answers gets nothing, and nothing is cached.
    @Test func aGoneRequestIsWrittenNothing() async throws {
        let cache = try temporaryGameCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let files = MemoryGameFiles(["web/powder.wasm": wasm])
        let responder = GameFileResponder(cache: cache, source: { files })
        let gone = RecordedResponse()
        gone.isLive = false
        _ = await respond(responder, "web/powder.wasm", sink: gone)
        #expect(gone.status == nil && gone.body.isEmpty && !gone.finished)
        try await Task.sleep(for: .milliseconds(50))
        let stored = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(stored.isEmpty)
    }
}

/// `GameServer` on the loopback interface, fetched with URLSession as a page's requests are.
@MainActor @Suite(.serialized) struct GameServerTests {
    let index = Data("<!DOCTYPE html><title>game</title>".utf8)
    let wasm = Data((0 ..< 600_000).map { UInt8($0 % 253) })
    let root = "Games/powder/web"

    func makeServer(limits: GameServer.Limits = .standard) throws -> (GameServer, MemoryGameFiles, GameCache) {
        let cache = try temporaryGameCache()
        let files = MemoryGameFiles(["\(root)/index.html": index, "\(root)/powder.wasm": wasm])
        return (GameServer(root: root, responder: GameFileResponder(cache: cache, source: { files }), limits: limits), files, cache)
    }

    func fetch(_ url: URL, method: String = "GET", fields: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        for (name, value) in fields { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func aPageFetchesItsFilesOverLoopback() async throws {
        let (server, _, cache) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: cache.directory) }
        let origin = try await server.start()
        #expect(try await server.start() == origin) // started once
        let (body, response) = try await fetch(try #require(origin.url("index.html")))
        #expect(response.statusCode == 200 && body == index)
        #expect(response.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy") == "same-origin")
        #expect(response.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy") == "require-corp")
        #expect(response.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy") == "same-origin")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/html")

        let (module, wasmResponse) = try await fetch(try #require(origin.url("powder.wasm")))
        #expect(wasmResponse.statusCode == 200 && module == wasm)
        #expect(wasmResponse.value(forHTTPHeaderField: "Content-Type") == "application/wasm")
        let (part, partial) = try await fetch(try #require(origin.url("powder.wasm")), fields: ["Range": "bytes=100-199"])
        #expect(partial.statusCode == 206 && part == wasm[100 ... 199])
        let (_, refused) = try await fetch(try #require(origin.url("powder.wasm")), fields: ["Range": "bytes=900000-"])
        #expect(refused.statusCode == 416)
        let (_, head) = try await fetch(try #require(origin.url("powder.wasm")), method: "HEAD")
        #expect(head.statusCode == 200 && head.value(forHTTPHeaderField: "Content-Length") == "600000")
    }

    @Test func requestsWithoutTheTokenOrWithAnotherMethodAreRefused() async throws {
        let (server, files, cache) = try makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: cache.directory) }
        let origin = try await server.start()
        let (_, noToken) = try await fetch(URL(string: "http://127.0.0.1:\(origin.port)/index.html")!)
        #expect(noToken.statusCode == 404)
        #expect(noToken.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy") == "require-corp")
        let other = GameOrigin(port: origin.port, token: GameOrigin.newToken())
        let (_, wrongToken) = try await fetch(try #require(other.url("index.html")))
        #expect(wrongToken.statusCode == 404)
        let (_, missing) = try await fetch(try #require(origin.url("missing.js")))
        #expect(missing.statusCode == 404)
        let (_, post) = try await fetch(try #require(origin.url("index.html")), method: "POST")
        #expect(post.statusCode == 405 && post.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
        #expect(files.streams.isEmpty)
    }

    @Test func stoppingClosesTheListenerAndEveryConnection() async throws {
        var limits = GameServer.Limits.standard
        limits.requestTimeout = 30
        let (server, _, cache) = try makeServer(limits: limits)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let origin = try await server.start()
        // A connection that never sends its request.
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: origin.port)!, using: .tcp)
        idle.start(queue: .main)
        defer { idle.cancel() }
        try await eventually("connected") { server.openConnections == 1 }
        server.stop()
        #expect(server.openConnections == 0 && server.origin == nil)
        let url = try #require(origin.url("index.html"))
        await #expect(throws: (any Error).self) { try await fetch(url) }
        await #expect(throws: GameServerError.self) { try await server.start() }
    }

    @Test func aConnectionThatSendsNoRequestIsClosed() async throws {
        var limits = GameServer.Limits.standard
        limits.requestTimeout = 0.2
        let (server, _, cache) = try makeServer(limits: limits)
        defer { server.stop(); try? FileManager.default.removeItem(at: cache.directory) }
        let origin = try await server.start()
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: origin.port)!, using: .tcp)
        idle.start(queue: .main)
        defer { idle.cancel() }
        try await eventually("connected") { server.openConnections == 1 }
        try await eventually("timed out") { server.openConnections == 0 }
    }
}
