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
    }
}
#endif
