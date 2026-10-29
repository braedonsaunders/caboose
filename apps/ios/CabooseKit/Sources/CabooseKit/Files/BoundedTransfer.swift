import Foundation

/// Authenticated file transfers with the host that cannot be steered or overrun: no
/// redirect is followed (the bearer token and the file never go anywhere else), a
/// download is streamed to disk and stopped the moment it passes its limit, and nothing
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
        var request = request
        request.setValue("bytes=0-\(limit)", forHTTPHeaderField: "Range")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else { throw CocoaError(.fileWriteUnknown) }
        let receiver = Receiver(limit: limit, handle: handle)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let size = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    receiver.continuation = continuation
                    session.dataTask(with: request).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
            try handle.close()
            return size
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A small request (a stat, a delete) without following redirects; returns the body and status.
    public static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration = configuration()) async throws -> (Data, Int) {
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300 ..< 400).contains(status) { throw Failure.redirected }
        return (data, status)
    }

    /// Uploads a file without following redirects; returns the body and status.
    public static func upload(_ request: URLRequest, fromFile file: URL,
                              configuration: URLSessionConfiguration = configuration()) async throws -> (Data, Int) {
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300 ..< 400).contains(status) { throw Failure.redirected }
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

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int64
        let handle: FileHandle
        var continuation: CheckedContinuation<Int64, Error>?
        private var received: Int64 = 0
        private var expected: Int64 = -1
        private var failure: Error?

        init(limit: Int64, handle: FileHandle) {
            self.limit = limit
            self.handle = handle
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            failure = Failure.redirected
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                expected = response.expectedContentLength
                if expected > limit { failure = Failure.tooLarge }
            case 206:
                if let total = BoundedTransfer.rangeTotal(http?.value(forHTTPHeaderField: "Content-Range"), limit: limit) {
                    expected = total
                    if total > limit { failure = Failure.tooLarge }
                } else {
                    failure = Failure.incomplete
                }
            case 300 ..< 400:
                failure = failure ?? Failure.redirected
            case let status:
                failure = Failure.status(status)
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
            do { try handle.write(contentsOf: data) } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = self.continuation
            self.continuation = nil
            if let failure { continuation?.resume(throwing: failure) }
            else if let error { continuation?.resume(throwing: error) }
            else if expected >= 0, received != expected { continuation?.resume(throwing: Failure.incomplete) }
            else { continuation?.resume(returning: received) }
        }
    }
}
