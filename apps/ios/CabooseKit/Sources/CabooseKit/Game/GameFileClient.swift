import Foundation

/// An item of the computer's file service (docs/architecture.md, "Files").
public struct GameFileItem: Decodable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var size: Int
    /// Unix milliseconds.
    public var mtime: Double
    /// Opaque and quoted; changes when the file does.
    public var etag: String

    public var isDirectory: Bool { kind == "directory" }

    public init(name: String, kind: String, size: Int, mtime: Double, etag: String) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.etag = etag
    }

    private enum CodingKeys: String, CodingKey { case name, kind, size, mtime, etag }

    /// Only the name and kind are required; the rest default to nothing known.
    public init(from decoder: Decoder) throws {
        let item = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: item.decode(String.self, forKey: .name), kind: item.decode(String.self, forKey: .kind),
                      size: item.decodeIfPresent(Int.self, forKey: .size) ?? 0, mtime: item.decodeIfPresent(Double.self, forKey: .mtime) ?? 0,
                      etag: item.decodeIfPresent(String.self, forKey: .etag) ?? "")
    }
}

/// How a save write went.
public enum GameWriteResult: Equatable, Sendable {
    /// Written; the computer's new etag, when it said.
    case written(etag: String?)
    /// The precondition failed (412): the computer's copy is not the one the device last saw.
    case conflict
}

/// The computer's file service answered with an error, or could not be reached.
public struct GameFileError: LocalizedError, Equatable {
    /// The HTTP status; nil when no answer came.
    public var status: Int?
    public var message: String

    public var errorDescription: String? { message }
}

/// The `/v1/fs` requests save sync makes, so it can be checked without a computer.
protocol GameFileService: Sendable {
    /// A directory's items; nil when it does not exist.
    func list(_ path: String) async throws -> [GameFileItem]?
    /// One item; nil when it does not exist.
    func stat(_ path: String) async throws -> GameFileItem?
    /// A whole file and its etag.
    func download(_ path: String) async throws -> (data: Data, etag: String?)
    func put(_ path: String, data: Data, _ precondition: GamePrecondition) async throws -> GameWriteResult
    /// Makes a directory; one that already exists is fine.
    func mkdir(_ path: String) async throws
    /// Moves an item to the Trash. One already gone, or changed on the computer (412), is left be.
    func delete(_ path: String, ifMatch: String?) async throws
}

/// Where a game's files come from as its origin serves them (`GameFileResponder`): the
/// computer's `/v1/fs`, or a stand-in, so serving can be checked without a computer.
protocol GameFileSource: Sendable {
    /// Names the computer in the game cache (`GameHostAccess.computerKey`).
    var computerKey: String { get }
    /// One item; nil when it does not exist.
    func stat(_ path: String) async throws -> GameFileItem?
    /// The file's bytes as they arrive, `range` sent as its `Range` header, each chunk written
    /// to `teeInto` (when given) before it is yielded.
    func stream(_ path: String, range: String?, teeInto file: URL?) -> any GameTransfer
}

/// A file on its way from the computer: its response, then its bytes. Ending the iteration of
/// `events` stops the transfer.
protocol GameTransfer: AnyObject, Sendable {
    var events: AsyncThrowingStream<GameTransferEvent, Error> { get }
    /// The file each chunk is written to, if any.
    var stagedFile: URL? { get }
    /// Whether every chunk reached `stagedFile`; read once `events` has ended.
    var teed: Bool { get }
}

enum GameTransferEvent {
    case response(HTTPURLResponse)
    case data(Data)
}

/// `/v1/fs` over the host's HTTP API.
struct GameFileClient: GameFileService, GameFileSource {
    var host: GameHostAccess
    var session: URLSession = .shared

    var computerKey: String { host.computerKey }

    func stat(_ path: String) async throws -> GameFileItem? {
        let (data, status, _) = try await send(host.request("stat", path: path))
        if status == 404 { return nil }
        try check(status, data)
        return try decode(GameFileItem.self, data)
    }

    func list(_ path: String) async throws -> [GameFileItem]? {
        let (data, status, _) = try await send(host.request("list", path: path))
        if status == 404 { return nil }
        try check(status, data)
        struct Listing: Decodable { var items: [GameFileItem] }
        return try decode(Listing.self, data).items
    }

    func download(_ path: String) async throws -> (data: Data, etag: String?) {
        var request = host.request("content", path: path)
        request.timeoutInterval = 300
        let (data, status, response) = try await send(request)
        try check(status, data)
        return (data, response?.value(forHTTPHeaderField: "ETag"))
    }

    func put(_ path: String, data: Data, _ precondition: GamePrecondition) async throws -> GameWriteResult {
        var request = host.request("content", path: path, method: "PUT")
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .create: request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .match(let etag): request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        let body: Data, status: Int, response: HTTPURLResponse?
        do {
            let (answer, urlResponse) = try await session.upload(for: request, from: data)
            (body, response) = (answer, urlResponse as? HTTPURLResponse)
            status = response?.statusCode ?? 0
        } catch {
            throw GameFileError(status: nil, message: error.localizedDescription)
        }
        if status == 412 { return .conflict }
        try check(status, body)
        return .written(etag: response?.value(forHTTPHeaderField: "ETag") ?? (try? decode(GameFileItem.self, body))?.etag)
    }

    func mkdir(_ path: String) async throws {
        let (data, status, _) = try await send(host.request("mkdir", path: path, method: "POST"))
        if status == 409 { return } // already there
        try check(status, data)
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        var request = host.request("item", path: path, method: "DELETE")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let (data, status, _) = try await send(request)
        if status == 404 || status == 412 { return }
        try check(status, data)
    }

    /// A `GET /v1/fs/content`, its bytes relayed as they arrive.
    func stream(_ path: String, range: String?, teeInto file: URL?) -> any GameTransfer {
        var request = host.request("content", path: path)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return GameDownload(request: request, teeInto: file)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, http)
        } catch {
            throw GameFileError(status: nil, message: error.localizedDescription)
        }
    }

    private func check(_ status: Int, _ data: Data) throws {
        guard !(200 ..< 300).contains(status) else { return }
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        throw GameFileError(status: status, message: message ?? "The computer answered \(status).")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw GameFileError(status: nil, message: "The computer's file service sent an answer this Caboose cannot read.")
        }
    }
}

/// One `GET /v1/fs/content` whose response and bytes arrive as `events`, each chunk written
/// to `teeInto` (when given) before it is yielded. Ending the iteration cancels the request.
final class GameDownload: NSObject, URLSessionDataDelegate, GameTransfer, @unchecked Sendable {
    let events: AsyncThrowingStream<GameTransferEvent, Error>
    private let continuation: AsyncThrowingStream<GameTransferEvent, Error>.Continuation
    private var file: FileHandle?
    private var task: URLSessionDataTask?
    let stagedFile: URL?
    private(set) var teed: Bool

    init(request: URLRequest, teeInto url: URL?) {
        let (events, continuation) = AsyncThrowingStream<GameTransferEvent, Error>.makeStream()
        self.events = events
        self.continuation = continuation
        stagedFile = url
        if let url, FileManager.default.createFile(atPath: url.path, contents: nil) {
            file = try? FileHandle(forWritingTo: url)
        }
        teed = file != nil
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // The session holds this delegate until it is invalidated, when the task completes.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.task = task
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { continuation.yield(.response(http)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let file {
            do { try file.write(contentsOf: data) } catch { teed = false }
        }
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        file = nil
        session.finishTasksAndInvalidate()
        if let error {
            teed = false
            continuation.finish(throwing: GameFileError(status: nil, message: error.localizedDescription))
        } else {
            continuation.finish()
        }
    }
}
