import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import CabooseKit

/// End-to-end against a real Xpra seamless server running xterm and xclock:
///
///     CABOOSE_XPRA_URL=ws://host:14610 CABOOSE_XPRA_PASSWORD=… swift test --filter LiveServer
///
/// Skipped when CABOOSE_XPRA_URL is unset.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_XPRA_URL"] != nil))
@MainActor struct LiveServerTests {
    let url = URL(string: ProcessInfo.processInfo.environment["CABOOSE_XPRA_URL"] ?? "ws://127.0.0.1:1")!
    let password = ProcessInfo.processInfo.environment["CABOOSE_XPRA_PASSWORD"] ?? ""
    let username = ProcessInfo.processInfo.environment["CABOOSE_XPRA_USERNAME"] ?? "caboose"

    @Test func connectsRendersTypesAndResizes() async throws {
        var capabilities = ClientCapabilities(desktopWidth: 1600, desktopHeight: 1600, dpi: 192, username: username)
        capabilities.preferredEncoding = ProcessInfo.processInfo.environment["CABOOSE_XPRA_ENCODING"] ?? "auto"
        let session = XpraSession(displayURL: url, token: "unused", password: password, capabilities: capabilities)
        let started = Date()
        session.connect()
        try await until("hello", timeout: 15) { session.state == .ready || isClosed(session.state) }
        #expect(session.state == .ready, "state: \(session.state)")
        print("hello in \(ms(since: started)) ms, server \(session.serverVersion ?? "?")")

        try await until("two windows", timeout: 15) { session.windows.count >= 2 }
        for window in session.windows.values {
            try await until("first paint of \(window.appClass?.instance ?? "\(window.id)")", timeout: 15) { window.surface.generation > 1 }
            #expect(nonBlankPixels(window.surface) > 0, "window \(window.id) painted nothing")
        }
        print("windows painted in \(ms(since: started)) ms: \(session.windows.values.map { "\($0.appClass?.instance ?? "?") \(Int($0.frame.width))x\(Int($0.frame.height))" })")

        let terminal = try #require(session.windows.values.first { $0.appClass?.instance == "xterm" })
        session.configure(terminal, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        try await until("resize", timeout: 10) { terminal.surface.pixelSize == CGSize(width: 1200, height: 800) }
        let before = terminal.surface.generation
        session.focus(terminal)
        let typed = Date()
        session.type("echo caboose-ok\n", in: terminal)
        try await until("xterm repaint after typing", timeout: 10) { terminal.surface.generation > before }
        print("typing → repaint in \(ms(since: typed)) ms")

        // A flood of output makes the server switch the terminal to video.
        session.type("timeout 4 sh -c 'while :; do head -c 3000 /dev/urandom | base64; done'\n", in: terminal)
        try await Task.sleep(for: .seconds(5))
        let stats = DrawStatistics.shared.snapshot
        print("draws applied: \(stats.applied), failed: \(stats.failed)")
        #expect(stats.failed.isEmpty, "draw failures: \(stats.failed)")
        if let path = ProcessInfo.processInfo.environment["CABOOSE_XPRA_SNAPSHOT"] { Self.snapshot(terminal.surface, to: path) }

        session.disconnect()
    }

    private func isClosed(_ state: XpraSession.State) -> Bool {
        if case .closed = state { return true }
        return false
    }

    private func until(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw LiveError.timedOut(what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    private func nonBlankPixels(_ surface: WindowSurface) -> Int {
        guard let texture = surface.texture else { return 0 }
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] | pixels[$1 + 1] | pixels[$1 + 2] != 0 ? 1 : 0) }
    }

    static func snapshot(_ surface: WindowSurface, to path: String) {
        guard let texture = surface.texture else { return }
        let rowBytes = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * texture.height)
        texture.getBytes(&pixels, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: texture.width, height: texture.height, bitsPerComponent: 8,
                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                           UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    enum LiveError: Error { case timedOut(String) }
}
