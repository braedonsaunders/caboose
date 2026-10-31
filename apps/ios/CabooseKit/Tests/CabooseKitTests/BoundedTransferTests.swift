import Foundation
import Testing
@testable import CabooseKit

/// A stand-in server: each URL answers with a status, headers and body chunks, or a redirect.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var redirect: URL?
        /// Send the chunks and never finish, as a stalled server does.
        var hangs = false
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func configuration() -> URLSessionConfiguration {
        let configuration = BoundedTransfer.configuration()
        configuration.protocolClasses = [StubServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies[request.url!.path] ?? Reply(status: 404)
        Self.lock.unlock()
        if let target = reply.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.hangs { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct BoundedTransferTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-" + UUID().uuidString)

    func download(_ path: String, limit: Int64) async throws -> (Int64, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        let size = try await BoundedTransfer.download(URLRequest(url: URL(string: "https://host.test\(path)")!), to: destination,
                                                      limit: limit, configuration: StubServer.configuration())
        return (size, destination)
    }

    func failure(_ path: String, limit: Int64) async -> BoundedTransfer.Failure? {
        do { _ = try await download(path, limit: limit); return nil }
        catch { return error as? BoundedTransfer.Failure }
    }

    func leftovers() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }

    @Test func aFileWithinTheLimitArrivesAndTheRangeIsAskedFor() async throws {
        StubServer.replies["/ok"] = .init(status: 206, headers: ["Content-Range": "bytes 0-5/6", "Content-Length": "6"],
                                          chunks: [Data("abc".utf8), Data("def".utf8)])
        let (size, file) = try await download("/ok", limit: 10)
        let data = try Data(contentsOf: file)
        #expect(size == 6 && data == Data("abcdef".utf8))
        #expect(StubServer.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-10")
    }

    @Test func aRangeOfALargerFileIsRefused() async {
        StubServer.replies["/large"] = .init(status: 206, headers: ["Content-Range": "bytes 0-10/500"], chunks: [Data(count: 11)])
        #expect(await failure("/large", limit: 10) == .tooLarge)
        #expect(leftovers().isEmpty)
    }

    @Test func aChunkedAnswerIsCutOffPastTheLimit() async {
        // A 200 that ignores the range, has no length, and keeps sending (a growing file).
        StubServer.replies["/chunked"] = .init(status: 200, chunks: Array(repeating: Data(count: 4), count: 10))
        #expect(await failure("/chunked", limit: 10) == .tooLarge)
        #expect(leftovers().isEmpty)
    }

    @Test func anAnnouncedOversizeIsRefusedBeforeItsBody() async {
        StubServer.replies["/announced"] = .init(status: 200, headers: ["Content-Length": "999"], chunks: [Data(count: 999)])
        #expect(await failure("/announced", limit: 10) == .tooLarge)
    }

    @Test func aShortBodyIsIncomplete() async {
        StubServer.replies["/short"] = .init(status: 206, headers: ["Content-Range": "bytes 0-7/8"], chunks: [Data(count: 3)])
        #expect(await failure("/short", limit: 10) == .incomplete)
        StubServer.replies["/middle"] = .init(status: 206, headers: ["Content-Range": "bytes 2-4/8"], chunks: [Data(count: 3)])
        #expect(await failure("/middle", limit: 10) == .incomplete)
    }

    @Test func redirectsAreNotFollowed() async {
        StubServer.replies["/moved"] = .init(redirect: URL(string: "https://elsewhere.test/steal")!)
        StubServer.requests.removeAll()
        #expect(await failure("/moved", limit: 10) == .redirected)
        #expect(!StubServer.requests.contains { $0.url?.host == "elsewhere.test" })
        #expect(leftovers().isEmpty)
    }

    @Test func errorsAreTheirStatus() async {
        StubServer.replies["/missing"] = .init(status: 404)
        #expect(await failure("/missing", limit: 10) == .status(404))
    }

    @Test func uploadsDoNotFollowRedirects() async throws {
        StubServer.replies["/upload"] = .init(redirect: URL(string: "https://elsewhere.test/steal")!)
        StubServer.requests.removeAll()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("up")
        try Data("secret".utf8).write(to: file)
        var request = URLRequest(url: URL(string: "https://host.test/upload")!)
        request.httpMethod = "PUT"
        await #expect(throws: BoundedTransfer.Failure.redirected) {
            _ = try await BoundedTransfer.upload(request, fromFile: file, configuration: StubServer.configuration())
        }
        #expect(!StubServer.requests.contains { $0.url?.host == "elsewhere.test" })
    }

    @Test func aTransferCancelledBeforeItStartsSendsNothing() async throws {
        StubServer.replies["/never"] = .init(status: 200, chunks: [Data(count: 4)])
        StubServer.requests.removeAll()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("never")
        let configuration = StubServer.configuration()
        let outcome = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await BoundedTransfer.download(URLRequest(url: URL(string: "https://host.test/never")!), to: destination,
                                                       limit: 10, configuration: configuration)
                return nil
            } catch { return error }
        }.value
        #expect(outcome is CancellationError)
        #expect(StubServer.requests.isEmpty)
        #expect(leftovers().isEmpty)
    }

    @Test func aTransferCancelledMidwayEndsAndLeavesNothing() async throws {
        StubServer.replies["/stalls"] = .init(status: 200, headers: ["Content-Length": "8"], chunks: [Data(count: 4)], hangs: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("stalls")
        let configuration = StubServer.configuration()
        let task = Task { () -> Error? in
            do {
                _ = try await BoundedTransfer.download(URLRequest(url: URL(string: "https://host.test/stalls")!), to: destination,
                                                       limit: 10, configuration: configuration)
                return nil
            } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value is CancellationError)
        #expect(leftovers().isEmpty)
    }

    @Test func metadataAnswersAreBounded() async throws {
        StubServer.replies["/stat"] = .init(status: 200, chunks: Array(repeating: Data(count: 32 * 1024), count: 3))
        await #expect(throws: BoundedTransfer.Failure.tooLarge) {
            _ = try await BoundedTransfer.fetch(URLRequest(url: URL(string: "https://host.test/stat")!), configuration: StubServer.configuration())
        }
        StubServer.replies["/small"] = .init(status: 404, chunks: [Data("{}".utf8)])
        let (data, status) = try await BoundedTransfer.fetch(URLRequest(url: URL(string: "https://host.test/small")!),
                                                             configuration: StubServer.configuration())
        #expect(status == 404 && data == Data("{}".utf8))
    }

    @Test func contentRangesMustDescribeTheStart() {
        #expect(BoundedTransfer.rangeTotal("bytes 0-9/10", limit: 10) == 10)
        #expect(BoundedTransfer.rangeTotal("bytes 0-10/500", limit: 10) == 500)
        #expect(BoundedTransfer.rangeTotal("bytes 0-3/8", limit: 10) == nil)
        #expect(BoundedTransfer.rangeTotal("bytes 1-9/10", limit: 10) == nil)
        #expect(BoundedTransfer.rangeTotal(nil, limit: 10) == nil)
    }
}
