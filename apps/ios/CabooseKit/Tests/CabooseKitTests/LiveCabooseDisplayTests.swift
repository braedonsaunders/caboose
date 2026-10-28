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
/// Prints the server's encoders and features, each window, frames per second, failed
/// decodes and the round trip. Skipped without the URL.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] != nil))
@MainActor struct LiveCabooseDisplayTests {
    let host = URL(string: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] ?? "http://127.0.0.1:1")!
    let token = ProcessInfo.processInfo.environment["CABOOSE_HOST_TOKEN"] ?? ""
    let seconds = Double(ProcessInfo.processInfo.environment["CABOOSE_VIDEO_SECONDS"] ?? "") ?? 10

    @Test func streamsWindowsOverTheRelay() async throws {
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

        let capabilities = ClientCapabilities(desktopWidth: 2560, desktopHeight: 1600, dpi: 192, refreshRate: 120)
        let session = CabooseDisplaySession(displayURL: socket.url!, token: token, password: password, capabilities: capabilities)
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

    private func until(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
