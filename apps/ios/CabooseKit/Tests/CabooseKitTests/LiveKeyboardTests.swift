import Foundation
import Testing
@testable import CabooseKit

/// Types every printable ASCII character into `cat` on a live server and snapshots the
/// terminal, so key mapping can be checked by eye. Needs the same env as LiveServerTests.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_XPRA_KEYS"] != nil))
@MainActor struct LiveKeyboardTests {
    @Test func typesPrintableASCII() async throws {
        let env = ProcessInfo.processInfo.environment
        let session = XpraSession(displayURL: URL(string: env["CABOOSE_XPRA_URL"]!)!, token: "unused",
                                  password: env["CABOOSE_XPRA_PASSWORD"] ?? "",
                                  capabilities: ClientCapabilities(desktopWidth: 1600, desktopHeight: 1600, dpi: 192,
                                                                   username: env["CABOOSE_XPRA_USERNAME"] ?? "caboose"))
        session.connect()
        for _ in 0 ..< 300 where session.windows.values.first(where: { $0.appClass?.instance == "xterm" }) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let terminal = try #require(session.windows.values.first { $0.appClass?.instance == "xterm" })
        session.configure(terminal, frame: CGRect(x: 0, y: 0, width: 1400, height: 600))
        session.focus(terminal)
        try await Task.sleep(for: .milliseconds(300))
        session.type("clear; cat\n", in: terminal)
        try await Task.sleep(for: .milliseconds(300))
        let printable = String((32 ... 126).map { Character(UnicodeScalar(UInt8($0))) })
        session.type(printable + "\n", in: terminal)
        try await Task.sleep(for: .milliseconds(800))
        session.key(KeyStroke(name: "c", keyval: 0x63, string: "c"), pressed: true, in: terminal, extraModifiers: ["control"])
        session.key(KeyStroke(name: "c", keyval: 0x63, string: "c"), pressed: false, in: terminal, extraModifiers: ["control"])
        try await Task.sleep(for: .milliseconds(500))
        LiveServerTests.snapshot(terminal.surface, to: env["CABOOSE_XPRA_SNAPSHOT"] ?? "/tmp/caboose-keys.png")
        session.disconnect()
    }
}
