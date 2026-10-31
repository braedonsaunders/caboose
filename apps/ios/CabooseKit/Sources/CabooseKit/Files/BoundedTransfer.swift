import Foundation

/// Authenticated file transfers with the host that cannot be steered or overrun: no
/// redirect is followed (the bearer token and the file never go anywhere else), every
/// response body has a hard byte limit enforced as it arrives, a download is streamed to
/// disk, cancellation (even before the request starts) ends the transfer, and nothing
/// partial is left behind.
public enum BoundedTransfer {
    public enum Failure: Error, Equatable {
        /// The server answered with this status.
        case status(Int)
        /// The server tried to redirect the request.
        case redirected
        /// More bytes than the limit.
        case tooLarge
        /// A ranged answer that does not describe the start of the file, or fewer bytes
        /// than the server announced.
        case incomplete
    }

    /// The most a metadata answer (a stat, an upload's reply) may be.
    public static let metadataLimit: Int64 = 64 * 1024

    /// An ephemeral configuration: no cookies, no cache, nothing kept on disk.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// Downloads `request` into a new file at `destination`, at most `limit` bytes, and
    /// returns its size. The request asks for the first `limit + 1` bytes; a 206 must be
    /// exactly the start of a file no larger than `limit`, and a 200 is cut off past it.
    public static func download(_ request: URLRequest, to destination: URL, limit: Int64,
                                configuration: URLSessionConfiguration = configuration()) async throws -> Int64 {
        try Task.checkCancellation()
        var request = request
        request.setValue("bytes=0-\(limit)", forHTTPHeaderField: "Range")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else { throw CocoaError(.fileWriteUnknown) }
        let receiver = Receiver(limit: limit, file: handle, ranged: true)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, _, size) = try await receiver.run { session.dataTask(with: request) }
            try handle.close()
            return size
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A small request (a stat, a delete): its body (at most `metadataLimit`) and status.
    public static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration = configuration()) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let receiver = Receiver(limit: metadataLimit, file: nil, ranged: false)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, status, _) = try await receiver.run { session.dataTask(with: request) }
        return (data, status)
    }

    /// Uploads a file; returns the reply (at most `metadataLimit`) and status.
    public static func upload(_ request: URLRequest, fromFile file: URL,
                              configuration: URLSessionConfiguration = configuration()) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let receiver = Receiver(limit: metadataLimit, file: nil, ranged: false)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, status, _) = try await receiver.run { session.uploadTask(with: request, fromFile: file) }
        return (data, status)
    }

    /// The size of the file a `Content-Range` answering `bytes=0-limit` describes: the
    /// range must start at 0 and, for a file within the limit, cover all of it.
    static func rangeTotal(_ header: String?, limit: Int64) -> Int64? {
        guard let header, header.hasPrefix("bytes 0-"),
              let slash = header.firstIndex(of: "/"),
              let end = Int64(header[header.index(header.startIndex, offsetBy: 8) ..< slash]),
              let total = Int64(header[header.index(after: slash)...]), total > 0 else { return nil }
        return total > limit || end == total - 1 ? total : nil
    }

    /// Receives one task's answer within a limit, into a file or memory. Its continuation
    /// is resumed exactly once; cancellation before or after the task starts ends it.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int64
        private let file: FileHandle?
        private let ranged: Bool
        private let lock = NSLock()
        // Guarded by `lock`.
        private var continuation: CheckedContinuation<(Data, Int, Int64), Error>?
        private var task: URLSessionTask?
        private var cancelled = false
        // Touched only on the session's delegate queue.
        private var body = Data()
        private var received: Int64 = 0
        private var expected: Int64 = -1
        private var status = 0
        private var failure: Error?

        init(limit: Int64, file: FileHandle?, ranged: Bool) {
            self.limit = limit
            self.file = file
            self.ranged = ranged
        }

        func run(_ makeTask: @escaping () -> URLSessionTask) async throws -> (Data, Int, Int64) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if cancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let task = makeTask()
                    self.task = task
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                lock.lock()
                cancelled = true
                let task = self.task
                lock.unlock()
                task?.cancel()
            }
        }

        private func finish(_ result: Result<(Data, Int, Int64), Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let outcome = cancelled ? .failure(CancellationError()) : result
            lock.unlock()
            continuation?.resume(with: outcome)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            failure = Failure.redirected
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            switch status {
            case 300 ..< 400:
                failure = failure ?? Failure.redirected
            case 206 where ranged:
                if let total = BoundedTransfer.rangeTotal(http?.value(forHTTPHeaderField: "Content-Range"), limit: limit) {
                    expected = total
                    if total > limit { failure = Failure.tooLarge }
                } else {
                    failure = Failure.incomplete
                }
            case 200 where ranged:
                expected = response.expectedContentLength
                if expected > limit { failure = Failure.tooLarge }
            case _ where ranged:
                failure = Failure.status(status)
            default:
                // A metadata answer of any status goes back to the caller, within the limit.
                if response.expectedContentLength > limit { failure = Failure.tooLarge }
            }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            received += Int64(data.count)
            guard received <= limit else {
                failure = Failure.tooLarge
                dataTask.cancel()
                return
            }
            if let file {
                do { try file.write(contentsOf: data) } catch {
                    failure = error
                    dataTask.cancel()
                }
            } else {
                body.append(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let failure { finish(.failure(failure)) }
            else if let error { finish(.failure(error)) }
            else if ranged, expected >= 0, received != expected { finish(.failure(Failure.incomplete)) }
            else { finish(.success((body, status, received))) }
        }
    }
}
