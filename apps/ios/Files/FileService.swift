import Foundation
import FileProvider

func providerError(_ error: Error) -> Error {
    let domain = (error as NSError).domain
    return domain == NSFileProviderErrorDomain || domain == NSCocoaErrorDomain ? error : NSFileProviderError(.serverUnreachable)
}

struct RemoteItem: Decodable {
    let name: String
    let kind: String
    let size: Int64
    let mtime: Double
    let etag: String
    let contentType: String
    let identity: String
}
struct RemoteList: Decodable { let items: [RemoteItem] }
struct RemoteEvent: Decodable { let path: String; let removed: Bool; let cookie: Int }
struct RemoteChanges: Decodable { let anchor: String; let changed: Bool; let reset: Bool; let events: [RemoteEvent] }

/// Connect structured cancellation to URLSession and expose byte progress to File Provider.
private final class TransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ task: URLSessionTask, progress: Progress) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        progress.addChild(task.progress, withPendingUnitCount: 100)
        if cancelled { task.cancel() } else { task.resume() }
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; task?.cancel() }
}

struct FileService {
    let credentials: Credentials
    init(domain: NSFileProviderDomainIdentifier) throws {
        guard let credentials = Credentials.load(), credentials.fileDomainIdentifier == domain.rawValue else { throw NSFileProviderError(.notAuthenticated) }
        self.credentials = credentials
    }
    func request(_ operation: String, path: String = "", method: String = "GET", query: [URLQueryItem] = [], data: Data? = nil, match: String? = nil) async throws -> Data {
        let host = await credentials.reachableURL()
        var components = URLComponents(url: host.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)] + query
        var request = URLRequest(url: components.url!, timeoutInterval: 300)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let match { request.setValue(match, forHTTPHeaderField: "If-Match") }
        if let data { request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            try Self.check(response)
            return body
        } catch let error as NSFileProviderError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CocoaError(.userCancelled) }
        catch is CancellationError { throw CocoaError(.userCancelled) }
        catch { throw NSFileProviderError(.serverUnreachable) }
    }
    func stat(_ path: String) async throws -> RemoteItem { try JSONDecoder().decode(RemoteItem.self, from: await request("stat", path: path)) }
    func list(_ path: String) async throws -> [RemoteItem] { try JSONDecoder().decode(RemoteList.self, from: await request("list", path: path)).items }
    func changes(_ anchor: String = "") async throws -> RemoteChanges {
        try JSONDecoder().decode(RemoteChanges.self, from: await request("changes", query: [URLQueryItem(name: "anchor", value: anchor)]))
    }
    func content(_ path: String, version: String? = nil, progress: Progress) async throws -> URL {
        let host = await credentials.reachableURL()
        var components = URLComponents(url: host.appendingPathComponent("v1/fs/content"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3600)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let version { request.setValue(version, forHTTPHeaderField: "If-Match") }
        do {
            let state = TransferState()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = URLSession.shared.downloadTask(with: request) { temporary, response, error in
                        do {
                            if let error { throw error }
                            guard let temporary, let response else { throw NSFileProviderError(.serverUnreachable) }
                            try Self.check(response)
                            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try FileManager.default.moveItem(at: temporary, to: destination)
                            continuation.resume(returning: destination)
                        } catch { continuation.resume(throwing: error) }
                    }
                    state.set(task, progress: progress)
                }
            } onCancel: { state.cancel() }
        } catch let error as NSFileProviderError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CocoaError(.userCancelled) }
        catch is CancellationError { throw CocoaError(.userCancelled) }
        catch { throw NSFileProviderError(.serverUnreachable) }
    }
    func upload(_ path: String, file: URL, match: String?, progress: Progress) async throws -> RemoteItem {
        let host = await credentials.reachableURL()
        var components = URLComponents(url: host.appendingPathComponent("v1/fs/content"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3600)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(match ?? "*", forHTTPHeaderField: match == nil ? "If-None-Match" : "If-Match")
        do {
            let state = TransferState()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = URLSession.shared.uploadTask(with: request, fromFile: file) { data, response, error in
                        do {
                            if let error { throw error }
                            guard let data, let response else { throw NSFileProviderError(.serverUnreachable) }
                            try Self.check(response)
                            continuation.resume(returning: try JSONDecoder().decode(RemoteItem.self, from: data))
                        } catch { continuation.resume(throwing: error) }
                    }
                    state.set(task, progress: progress)
                }
            } onCancel: { state.cancel() }
        } catch let error as NSFileProviderError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CocoaError(.userCancelled) }
        catch is CancellationError { throw CocoaError(.userCancelled) }
        catch { throw NSFileProviderError(.serverUnreachable) }
    }
    private static func check(_ response: URLResponse) throws {
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 401: throw NSFileProviderError(.notAuthenticated)
        case 400, 403, 404: throw NSFileProviderError(.noSuchItem)
        case 409: throw NSFileProviderError(.filenameCollision)
        case 412, 428: throw NSFileProviderError(.localVersionConflictingWithServer)
        default: throw NSFileProviderError(.serverUnreachable)
        }
    }
}
