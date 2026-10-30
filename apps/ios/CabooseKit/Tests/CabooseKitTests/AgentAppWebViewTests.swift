#if canImport(UIKit) && canImport(WebKit)
import Foundation
import UIKit
import WebKit
import XCTest
@testable import CabooseKit

@MainActor final class AgentAppWebViewTests: XCTestCase {
    func testRealDocumentReloadAndTakeover() async throws {
        let base = URL(string: "http://127.0.0.1:18765")!
        let descriptor = try XCTUnwrap(WebviewDescriptor([
            "id": 1, "window": 1, "app": "check", "bridge": "cccccccccccccccccccccccccccccccc",
            "grant": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "root": "Apps/check", "entry": "index.html"
        ]))
        let game = RemoteGame(GameDescriptor(id: 1, window: 1, root: descriptor.root, entry: descriptor.entry),
                              host: GameHostAccess(baseURL: base, token: "test"), picture: WindowSurface(), webview: descriptor)
        let surface = GameSurfaceView.surface(for: game)
        defer { game.end() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(surface)
        surface.frame = controller.view.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func waitForCalls() async throws -> String {
            for _ in 0..<100 {
                if let result = try? await surface.webView.callAsyncJavaScript(
                    "return await Promise.all([window.caboose.files.readText('x'), window.caboose.exec(['echo'])])",
                    arguments: [:], in: nil, contentWorld: .page) as? [Any],
                    result.count == 2, let file = result[0] as? String,
                    let exec = result[1] as? [String: Any], exec["stdout"] as? String == "ran" { return file }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NSError(domain: "AgentAppWebViewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "page calls did not succeed"])
        }
        func state() async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/state"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // An idle page must register and poll without an API call.
        var idleRegistered = false
        for _ in 0..<100 {
            let log = try await state()["log"] as? [[String: Any]] ?? []
            if log.contains(where: { $0["operation"] as? String == "events" }) { idleRegistered = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(idleRegistered, "idle page did not register and poll")
        let firstResult = try await waitForCalls()
        XCTAssertEqual(firstResult, "hello")
        let firstState = try await state()
        let first = try XCTUnwrap(firstState["document"] as? String)
        surface.webView.reload()
        try await Task.sleep(for: .seconds(1))
        let secondResult = try await waitForCalls()
        XCTAssertEqual(secondResult, "hello")
        let secondState = try await state()
        let second = try XCTUnwrap(secondState["document"] as? String)
        XCTAssertNotEqual(first, second)
        try await checkNet(surface.webView)
        var request = URLRequest(url: base.appendingPathComponent("v1/webview/test/bridge"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operation":"call", "grant":descriptor.grant, "document":first, "method":"exec"])
        let (old, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: old) as? [String: Any])?["ok"] as? Bool, false)
        var takeover = URLRequest(url: base.appendingPathComponent("test/takeover"))
        takeover.httpMethod = "POST"; takeover.httpBody = Data("{}".utf8)
        _ = try await URLSession.shared.data(for: takeover)
        let response = try await surface.webView.callAsyncJavaScript("try { await window.caboose.exec(['echo']); return 'accepted' } catch (e) { return 'rejected' }", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(response, "rejected")
        let taken = try XCTUnwrap(WebviewDescriptor([
            "id": 1, "window": 1, "app": "check", "bridge": "cccccccccccccccccccccccccccccccc",
            "grant": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "root": "Apps/check", "entry": "index.html"
        ]))
        try await checkKeptPage(surface, game: game, descriptor: taken, base: base)
    }

    /// `net` through the device's network origin to a server without CORS consent.
    private func checkNet(_ webView: WKWebView) async throws {
        let result = try await webView.callAsyncJavaScript("""
            const direct = await fetch('http://127.0.0.1:18765/upstream/echo').then(() => 'read', error => error.name)
            const response = await caboose.fetch('http://127.0.0.1:18765/upstream/echo', {
              method: 'POST', body: 'hi', headers: { 'X-Probe': '1', 'User-Agent': 'probe-agent' } })
            const echoed = await response.json()
            return { direct, status: response.status, method: echoed.method, body: echoed.body,
                     probe: echoed.headers['x-probe'], agent: echoed.headers['user-agent'],
                     url: response.headers.get('X-Caboose-Url') }
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let net = try XCTUnwrap(result)
        XCTAssertEqual(net["direct"] as? String, "TypeError")
        XCTAssertEqual(net["status"] as? Int, 200)
        XCTAssertEqual(net["method"] as? String, "POST")
        XCTAssertEqual(net["body"] as? String, "hi")
        XCTAssertEqual(net["probe"] as? String, "1")
        XCTAssertEqual(net["agent"] as? String, "probe-agent")
        XCTAssertEqual(net["url"] as? String, "http://127.0.0.1:18765/upstream/echo")
    }

    /// A page playing media when Caboose leaves the screen is kept, and the app's next
    /// announcement (here with the grant the takeover gave) takes it over without a reload; a
    /// page that is not playing is not kept.
    private func checkKeptPage(_ surface: GameSurfaceView, game: RemoteGame, descriptor: WebviewDescriptor,
                               base: URL) async throws {
        let webView = surface.webView
        let started = try await webView.callAsyncJavaScript("""
            window.__mark = 'kept'
            window.__audio = new Audio(caboose.net.url('http://127.0.0.1:18765/upstream/tone.wav'))
            await window.__audio.play()
            return !window.__audio.paused
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(started, true)
        AgentAppPages.shared.parking { game.end() }
        XCTAssertEqual(AgentAppPages.shared.count, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(AgentAppPages.shared.count, 1, "a playing page was not kept")
        let failed = try await webView.callAsyncJavaScript(
            "try { await caboose.exec(['echo']); return 'ran' } catch (e) { return 'refused' }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(failed, "refused")

        let next = RemoteGame(GameDescriptor(id: 2, window: 1, root: descriptor.root, entry: descriptor.entry),
                              host: GameHostAccess(baseURL: base, token: "test"), picture: WindowSurface(), webview: descriptor)
        XCTAssertTrue(AgentAppPages.shared.adopt(next))
        XCTAssertTrue(GameSurfaceView.surface(for: next) === surface)
        XCTAssertEqual(AgentAppPages.shared.count, 0)
        var reconnected: String?
        for _ in 0..<50 {
            reconnected = try? await webView.callAsyncJavaScript(
                "return window.__mark + ':' + (await caboose.exec(['echo'])).stdout", arguments: [:], in: nil, contentWorld: .page) as? String
            if reconnected != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(reconnected, "kept:ran")

        _ = try await webView.callAsyncJavaScript("window.__audio.pause()", arguments: [:], in: nil, contentWorld: .page)
        AgentAppPages.shared.parking { next.end() }
        for _ in 0..<30 where AgentAppPages.shared.count > 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(AgentAppPages.shared.count, 0, "a page that was not playing was kept")
    }
}
#endif
