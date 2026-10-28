import Foundation
import QuartzCore
import Testing
@testable import CabooseKit

/// Connects to a real computer running caboose-display, through caboose-host exactly as the
/// app does: wake, the relayed display, the hello with the wake token, the windows, and
/// pictures decoded in hardware while vsync ticks at 120 Hz. The host must run with
/// `CABOOSE_DISPLAY=caboose` and have a window open (a terminal is enough):
///
///     CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… swift test --filter LiveCabooseDisplay
///
/// Or straight to a compositor, without a host (its dev container, `guest/display`):
///
///     CABOOSE_DISPLAY_URL=ws://box:14600/ CABOOSE_DISPLAY_TOKEN=… swift test --filter LiveCabooseDisplay
///
/// Prints the server's encoders and features, each window, frames per second, failed
/// decodes and the round trip. Skipped without either URL.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] != nil
    || ProcessInfo.processInfo.environment["CABOOSE_DISPLAY_URL"] != nil))
@MainActor struct LiveCabooseDisplayTests {
    let host = URL(string: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] ?? "http://127.0.0.1:1")!
    let token = ProcessInfo.processInfo.environment["CABOOSE_HOST_TOKEN"] ?? ""
    let seconds = Double(ProcessInfo.processInfo.environment["CABOOSE_VIDEO_SECONDS"] ?? "") ?? 10

    @Test func streamsWindowsOverTheRelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        let session: CabooseDisplaySession
        let capabilities = ClientCapabilities(desktopWidth: 2560, desktopHeight: 1600, dpi: 192, refreshRate: 120)
        if let direct = environment["CABOOSE_DISPLAY_URL"].flatMap(URL.init(string:)) {
            session = CabooseDisplaySession(displayURL: direct, token: "", password: environment["CABOOSE_DISPLAY_TOKEN"] ?? "",
                                            capabilities: capabilities)
        } else {
            session = try await relayedSession(capabilities)
        }
        try await measure(session)
    }

    /// Wakes the computer through the host and opens its relayed display, as the app does.
    private func relayedSession(_ capabilities: ClientCapabilities) async throws -> CabooseDisplaySession {
        var request = URLRequest(url: host.appendingPathComponent("v1/session"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        let (body, _) = try await URLSession.shared.data(for: request)
        let wake = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let display = try #require(wake?["display"] as? [String: Any])
        try #require(display["protocol"] as? String == "caboose-display", "the host serves \(display["protocol"] ?? "?"); set CABOOSE_DISPLAY=caboose")
        let password = try #require(display["token"] as? String)
        var socket = URLComponents(url: host.appendingPathComponent("v1/display"), resolvingAgainstBaseURL: false)!
        socket.scheme = host.scheme == "https" ? "wss" : "ws"

        return CabooseDisplaySession(displayURL: socket.url!, token: token, password: password, capabilities: capabilities)
    }

    private func measure(_ session: CabooseDisplaySession) async throws {
        session.connect()
        try await until("hello", timeout: 20) { session.state == .ready }
        let server = try #require(session.server)
        print("encoders \(server.encoders), features \(server.features.sorted())")
        try await until("a window", timeout: 20) { !session.windows.isEmpty }
        for window in session.windows.values.sorted(by: { $0.id < $1.id }) {
            print("window \(window.id) \(window.appClass?.instance ?? "?") \"\(window.title)\" \(window.frame) touch=\(window.acceptsTouch)")
        }

        // Tick vsync as a 120 Hz screen would, so the server releases frames.
        let start = Date()
        let generations = session.windows.mapValues(\.surface.generation)
        let failedBefore = DrawStatistics.shared.snapshot.failed.values.reduce(0, +)
        while Date().timeIntervalSince(start) < seconds {
            session.displayWillRefresh(0, targetTimestamp: CACurrentMediaTime() + 1.0 / 120)
            try await Task.sleep(for: .milliseconds(8))
        }
        let frames = session.windows.reduce(0) { $0 + Int($1.value.surface.generation - (generations[$1.key] ?? 0)) }
        let failed = DrawStatistics.shared.snapshot.failed.values.reduce(0, +) - failedBefore
        print(String(format: "pictures: %d in %.1f s = %.1f per second, %d failed, round trip %@ ms", frames, seconds,
                     Double(frames) / seconds, failed, session.latencyMs.map { String(format: "%.1f", $0) } ?? "?"))
        #expect(session.windows.values.allSatisfy { $0.surface.generation > 0 }, "every window got its keyframe")
        #expect(failed == 0)
        session.disconnect()
    }

    /// Touch, text, composition and keys against the compositor's test windows: a Chromium
    /// page whose title reports `<pointerType>|<field value>`, and xterm. Direct mode only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CABOOSE_DISPLAY_URL"] != nil))
    func drivesTouchTextAndKeys() async throws {
        let environment = ProcessInfo.processInfo.environment
        let capabilities = ClientCapabilities(desktopWidth: 2560, desktopHeight: 1600, dpi: 192, refreshRate: 120)
        let session = CabooseDisplaySession(displayURL: URL(string: environment["CABOOSE_DISPLAY_URL"]!)!, token: "",
                                            password: environment["CABOOSE_DISPLAY_TOKEN"] ?? "", capabilities: capabilities)
        session.connect()
        try await until("hello", timeout: 20) { session.state == .ready }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                session.displayWillRefresh(0, targetTimestamp: CACurrentMediaTime() + 1.0 / 120)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        defer { ticker.cancel(); session.disconnect() }
        try await until("windows", timeout: 20) { session.windows.count >= 2 }
        let page = try #require(session.windows.values.first { $0.appClass?.instance.contains("chrome") == true })
        print("page \(page.frame) title \"\(page.title)\" touch=\(page.acceptsTouch)")

        // A tap in the middle of the page: Chromium sees a touch pointer and focuses the field.
        let centre = CGPoint(x: page.frame.width / 2, y: page.frame.height / 2)
        session.touch([TouchPoint(slot: 0, phase: .down, x: centre.x, y: centre.y)], in: page)
        try await Task.sleep(for: .milliseconds(60))
        session.touch([TouchPoint(slot: 0, phase: .up, x: centre.x, y: centre.y)], in: page)
        try await until("a touch pointer", timeout: 5) { page.title.hasPrefix("touch|") }

        // The field fills the page, so the tap lands in it and Chromium enables text-input-v3.
        try await until("text input enabled", timeout: 3) { session.textInput?.enabled == true }
        #expect(session.composesText)
        // Clear what an earlier run left: a BackSpace per character, and a few more, since the
        // title (where the page reports its field) loses trailing spaces.
        let backspace = try #require(Keysyms.special["BackSpace"])
        for _ in 0 ..< page.title.drop(while: { $0 != "|" }).dropFirst().count + 4 {
            session.key(backspace, pressed: true, in: page)
            session.key(backspace, pressed: false, in: page)
        }
        try await until("an empty field", timeout: 3) { page.title == "touch|" }
        let x = try #require(Keysyms.stroke(for: "x"))
        session.key(x, pressed: true, in: page)
        session.key(x, pressed: false, in: page)
        try await until("a key", timeout: 3) { page.title == "touch|x" }
        session.key(backspace, pressed: true, in: page)
        session.key(backspace, pressed: false, in: page)
        try await until("BackSpace", timeout: 3) { page.title == "touch|" }
        session.edit([.type("caboose")], in: page)
        try await until("committed text", timeout: 5) { page.title == "touch|caboose" }
        session.edit([.backspace(1), .type("e!")], in: page)
        try await until("a replacement", timeout: 5) { page.title == "touch|caboose!" }
        if session.composesText {
            session.compose("にほ", selection: NSRange(location: 2, length: 0), in: page)
            try await Task.sleep(for: .milliseconds(300))
            print("during preedit: \"\(page.title)\"")
            session.edit([.type("日本")], in: page)
            try await until("the composition committed", timeout: 5) { page.title == "touch|caboose!日本" }
        }
        print("text: \"\(page.title)\"")

        // Keys into xterm, through Xwayland, and how fast its picture answers.
        if let xterm = session.windows.values.first(where: { $0.appClass?.instance == "XTerm" || $0.title == "xterm" }) {
            let before = xterm.surface.generation
            for character in "echo caboose\r" {
                for stroke in Keysyms.strokes(for: character) {
                    session.key(stroke, pressed: true, in: xterm)
                    session.key(stroke, pressed: false, in: xterm)
                }
                try await Task.sleep(for: .milliseconds(120))
            }
            try await Task.sleep(for: .milliseconds(500))
            print("xterm pictures \(xterm.surface.generation - before), typing echo \(session.typingEchoMs.map { "\($0) ms" } ?? "?")")
            #expect(xterm.surface.generation > before)
        }
        #expect(DrawStatistics.shared.snapshot.failed.isEmpty, "\(DrawStatistics.shared.snapshot.failed)")
    }

    private func until(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
