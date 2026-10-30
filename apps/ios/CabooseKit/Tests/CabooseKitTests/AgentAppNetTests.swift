import Foundation
import XCTest
@testable import CabooseKit

/// The device's network origin: the same contract as guest/apps/net.py, whose tests pin the
/// computer's side.
final class AgentAppNetTests: XCTestCase {
    let token = String(repeating: "ab", count: 16)

    func testTargets() throws {
        XCTAssertEqual(try AgentAppNet.target("/\(token)/https/api.example.com/v1/items?q=a%20b&n=1", token: token).get().absoluteString,
                       "https://api.example.com/v1/items?q=a%20b&n=1")
        XCTAssertEqual(try AgentAppNet.target("/\(token)/http/radio.example%3A8000/live", token: token).get().absoluteString,
                       "http://radio.example:8000/live")
        XCTAssertEqual(try AgentAppNet.target("/\(token)/http/%5B%3A%3A1%5D%3A8080", token: token).get().absoluteString,
                       "http://[::1]:8080/")
        XCTAssertEqual(try AgentAppNet.target("/\(token)/HTTPS/a.example/", token: token).get().absoluteString, "https://a.example/")
    }

    func testTargetRefusals() {
        let cases: [String: Int] = [
            "/\(String(repeating: "cd", count: 16))/https/a.example/": 404,
            "/\(token)/https": 404,
            "/\(token)/ftp/a.example/x": 400,
            "/\(token)/file/a.example/etc/passwd": 400,
            "/\(token)/https/user%40a.example/": 400,
            "/\(token)/https/a.example%2Fb/": 400,
            "/\(token)/https//x": 400,
            "relative": 400,
        ]
        for (target, status) in cases {
            guard case .failure(let refusal) = AgentAppNet.target(target, token: token) else { return XCTFail("\(target) was admitted") }
            XCTAssertEqual(refusal.status, status, target)
        }
    }

    func testHeaders() {
        let sent = AgentAppNet.upstreamHeaders([
            ("Host", "127.0.0.1:1"), ("Origin", "http://127.0.0.1:2"), ("Authorization", "Bearer k"), ("Range", "bytes=0-"),
            ("Sec-Fetch-Mode", "cors"), ("Accept-Encoding", "gzip"), ("X-Caboose-Header-User-Agent", "VLC/3.0"),
            ("User-Agent", "WebKit"), ("X-Caboose-Header-Cookie", "a=1"), ("X-Caboose-Header-Host", "evil.example"),
            ("Icy-MetaData", "1"), ("X-Bad", "a\r\nInjected: 1"),
        ])
        XCTAssertEqual(sent.map { "\($0.0): \($0.1)" },
                       ["Authorization: Bearer k", "Range: bytes=0-", "Icy-MetaData: 1", "User-Agent: VLC/3.0", "Cookie: a=1"])
        XCTAssertEqual(AgentAppNet.allowedOrigin(nil, appOrigin: "http://127.0.0.1:2"), "*")
        XCTAssertEqual(AgentAppNet.allowedOrigin("http://127.0.0.1:2", appOrigin: "http://127.0.0.1:2"), "http://127.0.0.1:2")
        XCTAssertNil(AgentAppNet.allowedOrigin("https://evil.example", appOrigin: "http://127.0.0.1:2"))
        let response = AgentAppNet.responseHeaders([
            ("Content-Type", "audio/mpeg"), ("Content-Length", "10"), ("Set-Cookie", "s=1"),
            ("Access-Control-Allow-Origin", "https://site.example"), ("Content-Security-Policy", "default-src 'none'"), ("icy-name", "Radio"),
        ], origin: "http://127.0.0.1:2", finalURL: "https://a.example/x")
        XCTAssertEqual(response.map { "\($0.0): \($0.1)" }, [
            "Content-Type: audio/mpeg", "Content-Length: 10", "X-Caboose-Set-Cookie: s=1", "icy-name: Radio",
            "Access-Control-Allow-Origin: http://127.0.0.1:2", "Access-Control-Expose-Headers: *", "Vary: Origin",
            "X-Caboose-Url: https://a.example/x",
        ])
        let decoded = AgentAppNet.responseHeaders([("Content-Encoding", "gzip"), ("Content-Length", "4")], origin: "*", finalURL: "")
        XCTAssertFalse(decoded.contains { $0.0 == "Content-Length" || $0.0 == "Content-Encoding" })
    }

    /// The server forwards to itself: the inner request has a wrong token, so the 404 it
    /// answers comes back through the outer one with its headers and the page's CORS.
    @MainActor func testServerForwardsPreflightsAndRefuses() async throws {
        let server = AgentAppNetServer(appOrigin: "http://127.0.0.1:9")
        defer { server.stop() }
        let base = try await server.start()
        let authority = "127.0.0.1%3A\(base.port!)"
        func fetch(_ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (HTTPURLResponse, String) {
            var request = URLRequest(url: URL(string: base.absoluteString + path)!)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (response as! HTTPURLResponse, String(decoding: data, as: UTF8.self))
        }
        let inner = String(repeating: "cd", count: 16)
        let (forwarded, body) = try await fetch("http/\(authority)/\(inner)/https/a.example/", headers: ["Origin": "http://127.0.0.1:9"])
        XCTAssertEqual(forwarded.statusCode, 404)
        XCTAssertEqual(body, "Not found\n")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "X-Caboose-Error"), "Not found")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "http://127.0.0.1:9")
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "X-Caboose-Url"), "http://127.0.0.1:\(base.port!)/\(inner)/https/a.example/")

        let (preflight, _) = try await fetch("https/api.example/x", method: "OPTIONS", headers: [
            "Origin": "http://127.0.0.1:9", "Access-Control-Request-Method": "PUT", "Access-Control-Request-Headers": "authorization",
        ])
        XCTAssertEqual(preflight.statusCode, 204)
        XCTAssertEqual(preflight.value(forHTTPHeaderField: "Access-Control-Allow-Methods"), "PUT")

        let (foreign, _) = try await fetch("https/api.example/x", headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(foreign.statusCode, 403)
        let (unreachable, _) = try await fetch("http/127.0.0.1%3A9/")
        XCTAssertEqual(unreachable.statusCode, 502)
        XCTAssertNotNil(unreachable.value(forHTTPHeaderField: "X-Caboose-Error"))
    }
}
