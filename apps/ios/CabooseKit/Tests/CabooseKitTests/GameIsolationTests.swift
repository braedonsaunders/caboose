#if canImport(WebKit) && os(macOS)
import Foundation
import Testing
import WebKit
@testable import CabooseKit

/// A page served by `GameServer` is cross-origin isolated in WebKit: SharedArrayBuffer exists
/// and a Worker writes through shared memory the page then reads (docs/game-handoff.md,
/// "Files"). macOS WebKit; the iOS device check is in apps/ios/README.md.
@MainActor @Suite(.serialized) struct GameIsolationTests {
    static let page = Data("""
    <!DOCTYPE html><title>pending</title>
    <script>
    const report = (roundtrip, note) => { document.title = JSON.stringify({ isolated: self.crossOriginIsolated === true,
      sab: typeof SharedArrayBuffer === 'function', roundtrip, note }); };
    try {
      const shared = new SharedArrayBuffer(4);
      const worker = new Worker('worker.js');
      worker.onmessage = () => report(Atomics.load(new Int32Array(shared), 0) === 42, 'worker');
      worker.onerror = e => report(false, 'worker error: ' + e.message);
      worker.postMessage(shared);
    } catch (e) { report(false, String(e)); }
    </script>
    """.utf8)
    static let worker = Data("onmessage = e => { Atomics.store(new Int32Array(e.data), 0, 42); postMessage(1); };".utf8)

    final class Loads: NSObject, WKNavigationDelegate {
        var finished = false
        var failure: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failure = "\(error)"
        }
    }

    @Test func aPageFromTheGameServerGetsThreads() async throws {
        let cache = try temporaryGameCache()
        let root = "Games/check/web"
        let files = MemoryGameFiles(["\(root)/index.html": Self.page, "\(root)/worker.js": Self.worker])
        let server = GameServer(root: root, responder: GameFileResponder(cache: cache, source: { files }))
        defer { server.stop(); try? FileManager.default.removeItem(at: cache.directory) }
        let origin = try await server.start()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        let loads = Loads()
        view.navigationDelegate = loads
        view.load(URLRequest(url: try #require(origin.url("index.html"))))
        // WebKit's web content process starts cold here: allow it longer than other waits.
        let deadline = Date().addingTimeInterval(20)
        while loads.failure == nil, view.title?.hasPrefix("{") != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(loads.failure == nil)
        let report = try JSONSerialization.jsonObject(with: Data((view.title ?? "{}").utf8)) as? [String: Any]
        #expect(report?["isolated"] as? Bool == true, "\(view.title ?? "")")
        #expect(report?["sab"] as? Bool == true)
        #expect(report?["roundtrip"] as? Bool == true)
    }
}
#endif
