import Foundation
import Testing
@testable import CabooseKit

/// Measures a playing video end to end, through caboose-host exactly as the app connects:
/// wake, the relayed display, a 4K desktop, hardware decode. Start a full-screen video on the
/// computer first, then:
///
///     CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… swift test --filter LiveVideo
///
/// Prints frames per second and the encodings that carried them. Skipped without the URL.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] != nil))
@MainActor struct LiveVideoTests {
    let host = URL(string: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] ?? "http://127.0.0.1:1")!
    let token = ProcessInfo.processInfo.environment["CABOOSE_HOST_TOKEN"] ?? ""
    let seconds = Double(ProcessInfo.processInfo.environment["CABOOSE_VIDEO_SECONDS"] ?? "") ?? 20

    @Test func measuresAPlayingVideoAt4K() async throws {
        var request = URLRequest(url: host.appendingPathComponent("v1/session"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        let (body, _) = try await URLSession.shared.data(for: request)
        let wake = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let display = try #require(wake?["display"] as? [String: Any])
        let password = try #require(display["token"] as? String)
        var socket = URLComponents(url: host.appendingPathComponent("v1/display"), resolvingAgainstBaseURL: false)!
        socket.scheme = host.scheme == "https" ? "wss" : "ws"

        let capabilities = ClientCapabilities(desktopWidth: 3840, desktopHeight: 2160, dpi: 192, refreshRate: 60)
        let session = XpraSession(displayURL: socket.url!, token: token, password: password, capabilities: capabilities)
        session.playsAudio = false
        session.connect()
        try await until("hello", timeout: 20) { session.state == .ready }

        // The biggest window is the video; give it the whole 4K screen.
        try await until("a window", timeout: 20) { !session.windows.isEmpty }
        try await Task.sleep(for: .seconds(2))
        let video = try #require(session.windows.values.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        session.configure(video, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        session.focus(video)
        try await Task.sleep(for: .seconds(4)) // let the server settle on its video encoder

        let startFrames = video.surface.generation
        let startStats = DrawStatistics.shared.snapshot.applied
        let started = Date()
        try await Task.sleep(for: .seconds(seconds))
        let elapsed = Date().timeIntervalSince(started)
        let frames = Int(video.surface.generation - startFrames)
        let stats = DrawStatistics.shared.snapshot
        let carried = stats.applied.map { ($0.key, $0.value - (startStats[$0.key] ?? 0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        print("video window \(video.appClass?.instance ?? "?") \(Int(video.surface.pixelSize.width))x\(Int(video.surface.pixelSize.height))")
        print(String(format: "frames: %d in %.1f s = %.1f fps", frames, elapsed, Double(frames) / elapsed))
        print("encodings: \(carried.map { "\($0.0)=\($0.1)" }.joined(separator: " ")), failed: \(stats.failed)")
        #expect(frames > 0)
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
