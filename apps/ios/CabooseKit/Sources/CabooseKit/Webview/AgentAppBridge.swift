#if canImport(UIKit) && canImport(WebKit)
import Foundation
import WebKit

/// The native end of one app view. The page never receives either host credential.
@MainActor
final class AgentAppBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "caboose")
    private(set) weak var game: RemoteGame?
    private weak var webView: WKWebView?
    private var origin: GameOrigin?
    private var document: String?
    private var epoch = 0
    private var opening: Task<Void, Error>?
    private var polling: Task<Void, Never>?
    private var ended = false
    private var closing = false
    /// Kept while Caboose is away (`AgentAppPages`): calls fail until the page is adopted.
    private var parked = false
    /// What the app's manifest declares, as the computer reported it when the page opened.
    private var capabilities: Set<String> = []
    /// The app's network origin on this device, for an app that declares `net`.
    private var network: AgentAppNetServer?
    var onFailure: (() -> Void)?
    var onReload: (() -> Void)?

    init(game: RemoteGame, webView: WKWebView) {
        self.game = game
        self.webView = webView
    }

    private func send(_ payload: [String: Any]) async throws -> Any {
        guard !ended, let game, let descriptor = game.webview, let host = game.host else {
            throw URLError(.notConnectedToInternet)
        }
        let url = host.baseURL.appendingPathComponent("v1/webview/\(descriptor.bridge)/bridge")
        let operation = payload["operation"] as? String
        var request = URLRequest(url: url, timeoutInterval: operation == "call" ? 660 : 5)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var scoped = payload
        scoped["grant"] = descriptor.grant
        request.httpBody = try JSONSerialization.data(withJSONObject: scoped)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = result["ok"] as? Bool else { throw URLError(.badServerResponse) }
        if !ok { throw BridgeError(result["error"] as? String ?? "The request failed") }
        return result["value"] ?? NSNull()
    }

    struct BridgeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Fetch immutable app information before injecting its API into the first document.
    func prepare(origin: GameOrigin) async throws -> String {
        if document != nil { committed() }
        self.origin = origin
        let token = GameOrigin.newToken()
        var info: Any?
        for attempt in 0..<20 {
            do {
                info = try await send(["operation": "open", "document": token, "revision": epoch])
                break
            } catch {
                if attempt == 19 || Task.isCancelled { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let info else { throw BridgeError("The app bridge is unavailable") }
        document = token
        capabilities = Set((info as? [String: Any])?["capabilities"] as? [String] ?? [])
        var netBase = "null"
        if capabilities.contains("net") {
            let appOrigin = "http://\(origin.authority)"
            if network?.appOrigin != appOrigin {
                network?.stop()
                network = AgentAppNetServer(appOrigin: appOrigin)
            }
            if let base = try await network?.start(),
               let encoded = try? JSONSerialization.data(withJSONObject: base.absoluteString, options: .fragmentsAllowed) {
                netBase = String(decoding: encoded, as: UTF8.self)
            }
        }
        guard JSONSerialization.isValidJSONObject(info),
              let data = try? JSONSerialization.data(withJSONObject: info),
              let text = String(data: data, encoding: .utf8),
              let url = Bundle.module.url(forResource: "AgentAppPage", withExtension: "js"),
              let page = try? String(contentsOf: url, encoding: .utf8) else { throw BridgeError("The app API is unavailable") }
        // The network base first: the app's own text never becomes a placeholder.
        return page.replacingOccurrences(of: "__CABOOSE_NET__", with: netBase).replacingOccurrences(of: "__CABOOSE_APP__", with: text)
    }

    /// The network origin listens again after the system took its socket in the background.
    func resume() { network?.resume() }

    /// The display closed but the page is kept: its link to the computer stops, and its
    /// network origin, which needs no computer, stays.
    func park() {
        parked = true
        polling?.cancel()
        polling = nil
        opening?.cancel()
        opening = nil
        document = nil
        epoch += 1
    }

    /// The kept page carries on as `game`: it registers again over the new grant.
    func adopt(_ game: RemoteGame) {
        self.game = game
        parked = false
        Task { [weak webView] in _ = try? await webView?.evaluateJavaScript("__cabooseReconnect()", in: nil, contentWorld: Self.world) }
    }

    static func worldScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "AgentAppWorld", withExtension: "js") else { throw BridgeError("The app API is unavailable") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A committed document invalidates its predecessor's bridge and processes.
    func committed() {
        epoch += 1
        let previous = document
        document = nil
        opening?.cancel()
        opening = nil
        if let previous { Task { _ = try? await send(["operation": "close", "document": previous]) } }
    }

    private func ensureDocument(_ token: String, generation: Int) async throws {
        if document != token {
            guard document == nil else { throw BridgeError("This page has been replaced") }
            document = token
            let task = Task { _ = try await send(["operation": "open", "document": token, "revision": generation]) }
            opening = task
        }
        if let opening { try await opening.value }
        guard !ended, epoch == generation, document == token else { throw BridgeError("This page has been replaced") }
        opening = nil
        startPolling()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard !parked else { return (nil, "Caboose is not connected to the computer") }
        guard !ended, !closing, message.frameInfo.isMainFrame, message.webView === webView,
              let origin, let url = message.frameInfo.request.url, origin.contains(url),
              let raw = message.body as? String, raw.utf8.count <= 96 * 1024 * 1024,
              let bytes = raw.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let token = payload["document"] as? String,
              token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            return (nil, "This page cannot use the bridge")
        }
        let generation = epoch
        do {
            try await ensureDocument(token, generation: generation)
            if payload["method"] as? String == "__caboose.ready" { return ("{\"ok\":true,\"value\":true}", nil) }
            payload["operation"] = "call"
            let value = try await send(payload)
            guard generation == epoch, document == token else { throw BridgeError("This page has been replaced") }
            let encoded = try JSONSerialization.data(withJSONObject: ["ok": true, "value": value])
            return (String(decoding: encoded, as: UTF8.self), nil)
        } catch {
            let encoded = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])
            return (encoded.map { String(decoding: $0, as: UTF8.self) }, nil)
        }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled, let self, !self.ended && !self.closing {
                if let token = self.document {
                    do {
                        let events = try await self.send(["operation": "events", "document": token]) as? [[String: Any]] ?? []
                        guard self.document == token, let webView = self.webView else { continue }
                        failures = 0
                        for event in events {
                            if event["type"] as? String == "reload" {
                                self.onReload?()
                                break
                            }
                            guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { continue }
                            _ = try? await webView.callAsyncJavaScript("__cabooseEvent(json)", arguments: ["json": json], in: nil, contentWorld: Self.world)
                        }
                    } catch {
                        if self.document == token { failures += 1 }
                        if failures >= 6 { self.onFailure?(); return }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func end() {
        guard !closing, !ended else { return }
        closing = true
        network?.stop()
        network = nil
        let previous = document
        polling?.cancel()
        polling = nil
        opening?.cancel()
        opening = nil
        if let previous {
            Task { [self] in _ = try? await send(["operation": "close", "document": previous]); ended = true }
        } else { ended = true }
        document = nil
        epoch += 1
    }
}
#endif
