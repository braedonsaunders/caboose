import Foundation

/// The answers to one request for a game file, whatever carries them (`GameServer`'s
/// connections, or a test's recorder).
@MainActor
protocol GameResponseSink: AnyObject {
    /// False once the request is gone (its connection closed, its server stopped): nothing
    /// more reaches it.
    var isLive: Bool { get }
    func start(_ status: Int, headers: [String: String])
    /// Returns once the transport has taken the bytes, so a slow reader slows the sender.
    func send(_ data: Data) async
    /// The response is complete.
    func finish()
    /// The response cannot be completed: what was sent of it is cut off.
    func abort()
}

/// What a game's origin answers for one of its files (docs/game-handoff.md, "Files").
///
/// The file is looked up with `/v1/fs/stat` and served from `GameCache` when the device has
/// that version of it. Otherwise it streams from `/v1/fs/content` as it arrives, into a
/// staging file at the same time, which moves into the cache once complete. A `Range` request
/// is answered 206 (or 416) from a cached file, or passed to the computer and relayed without
/// caching. A `HEAD` is answered from the stat alone. Nothing reaches a sink once it is no
/// longer live, and a download that completes after that is not cached.
@MainActor
final class GameFileResponder {
    static let chunk = 256 * 1024
    private let cache: GameCache
    private let source: () -> (any GameFileSource)?

    init(cache: GameCache = .shared, source: @escaping () -> (any GameFileSource)?) {
        self.cache = cache
        self.source = source
    }

    /// Answers a request for `path`, home-relative and already resolved against the game's root.
    func respond(path: String, range rangeHeader: String?, head: Bool, to sink: any GameResponseSink) async {
        let reply = Reply(sink: sink, head: head)
        guard let source = source() else { return reply.status(502, path: path) }
        let range = rangeHeader.flatMap(GameByteRange.init(header:))
        let item: GameFileItem?
        do { item = try await source.stat(path) } catch { return reply.fail(path: path) }
        guard reply.isLive else { return }
        guard let item, !item.isDirectory else { return reply.status(404, path: path) }
        if head { return reply.headers(of: item, path: path, range: range) }
        let key = item.etag.isEmpty ? nil : GameFiles.cacheKey(computer: source.computerKey, path: path, etag: item.etag)
        if let key, let file = cache.file(key) {
            cache.touch(file)
            return await reply.file(file, path: path, range: range)
        }
        let staging = range == nil && key != nil ? cache.stagingFile() : nil
        await relay(source.stream(path, range: range == nil ? nil : rangeHeader, teeInto: staging),
                    path: path, item: item, computer: source.computerKey, reply: reply)
    }

    /// Streams the computer's answer; a whole file that arrived complete is cached.
    private func relay(_ download: any GameTransfer, path: String, item: GameFileItem, computer: String, reply: Reply) async {
        var cached = false
        defer { if !cached, let staged = download.stagedFile { try? FileManager.default.removeItem(at: staged) } }
        var etag: String?
        var status = 0
        do {
            for try await event in download.events {
                guard reply.isLive else { return }
                switch event {
                case .response(let response):
                    status = response.statusCode
                    switch status {
                    case 200, 206:
                        etag = response.value(forHTTPHeaderField: "ETag")
                        let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? (status == 200 ? item.size : nil)
                        reply.start(status, headers: GameFiles.responseHeaders(
                            for: path, length: length, contentRange: response.value(forHTTPHeaderField: "Content-Range")))
                    case 416:
                        return reply.status(416, path: path, contentRange: response.value(forHTTPHeaderField: "Content-Range"))
                    case 404: return reply.status(404, path: path)
                    default: return reply.status(502, path: path)
                    }
                case .data(let data):
                    await reply.send(data)
                }
            }
        } catch {
            return reply.fail(path: path)
        }
        guard reply.isLive else { return }
        guard reply.isStarted else { return reply.status(502, path: path) }
        reply.finish()
        guard let staged = download.stagedFile, status == 200, download.teed,
              let version = etag ?? (item.etag.isEmpty ? nil : item.etag) else { return }
        cached = true
        let cache = cache, key = GameFiles.cacheKey(computer: computer, path: path, etag: version)
        Task.detached { cache.store(staged, as: key) }
    }
}

/// The answers to one request, each given only while its sink is live.
@MainActor
private final class Reply {
    let sink: any GameResponseSink
    /// A `HEAD`: the headers go, the body does not.
    let head: Bool
    private(set) var isStarted = false

    init(sink: any GameResponseSink, head: Bool) {
        self.sink = sink
        self.head = head
    }

    var isLive: Bool { sink.isLive }

    func start(_ status: Int, headers: [String: String]) {
        guard sink.isLive, !isStarted else { return }
        isStarted = true
        sink.start(status, headers: headers)
    }

    func send(_ data: Data) async {
        guard sink.isLive, isStarted, !head, !data.isEmpty else { return }
        await sink.send(data)
    }

    func finish() {
        guard sink.isLive, isStarted else { return }
        sink.finish()
    }

    /// A complete answer without a body.
    func status(_ status: Int, path: String, contentRange: String? = nil) {
        var headers = GameFiles.responseHeaders(for: path, length: 0, contentRange: contentRange)
        if status >= 400 { headers["Content-Type"] = "text/plain" }
        start(status, headers: headers)
        finish()
    }

    /// The computer could not be reached, or the answer broke off: a 502 when nothing was
    /// sent yet, else the response is cut off.
    func fail(path: String) {
        guard sink.isLive else { return }
        if isStarted { sink.abort() } else { status(502, path: path) }
    }

    /// What a `GET` would answer for `item`, without its body.
    func headers(of item: GameFileItem, path: String, range: GameByteRange?) {
        guard let range else {
            start(200, headers: GameFiles.responseHeaders(for: path, length: item.size))
            return finish()
        }
        guard let wanted = range.bytes(ofSize: item.size) else { return status(416, path: path, contentRange: "bytes */\(item.size)") }
        start(206, headers: GameFiles.responseHeaders(for: path, length: wanted.count,
                                                      contentRange: "bytes \(wanted.lowerBound)-\(wanted.upperBound)/\(item.size)"))
        finish()
    }

    /// A cached file, whole or the requested range of it, read off the main actor a chunk at a time.
    func file(_ url: URL, path: String, range: GameByteRange?) async {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        var bytes = 0 ..< size
        var contentRange: String?
        if let range {
            guard let wanted = range.bytes(ofSize: size) else { return status(416, path: path, contentRange: "bytes */\(size)") }
            bytes = wanted.lowerBound ..< wanted.upperBound + 1
            contentRange = "bytes \(wanted.lowerBound)-\(wanted.upperBound)/\(size)"
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return status(404, path: path) }
        defer { try? handle.close() }
        start(range == nil ? 200 : 206, headers: GameFiles.responseHeaders(for: path, length: bytes.count, contentRange: contentRange))
        do {
            try handle.seek(toOffset: UInt64(bytes.lowerBound))
            var remaining = bytes.count
            while remaining > 0, isLive {
                let count = min(remaining, GameFileResponder.chunk)
                let data = try await Task.detached { try handle.read(upToCount: count) ?? Data() }.value
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                await send(data)
                remaining -= data.count
            }
            finish()
        } catch {
            fail(path: path)
        }
    }
}
