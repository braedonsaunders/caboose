import Foundation
import Testing
@testable import CabooseKit

struct DesktopItemPolicyTests {
    @Test func pathsStayInsideDesktop() {
        #expect(DesktopItemPolicy.path(name: "Project.txt") == "Desktop/Project.txt")
        for name in ["", ".", "..", "../secret", "a/b", "a\0b"] { #expect(DesktopItemPolicy.path(name: name) == nil) }
        #expect(ShortcutPath.destination(folder: "../Documents", filename: "a") == nil)
    }
    @Test func shortcutsNeverInterpretExec() {
        let text = "[Desktop Entry]\nExec=arbitrary --command\nX-Caboose-AppId=org.example.App.desktop\n"
        #expect(DesktopAppShortcut.appID(from: Data(text.utf8)) == "org.example.App.desktop")
        #expect(DesktopAppShortcut.appID(from: Data("[Desktop Entry]\nExec=arbitrary\n".utf8)) == nil)
        #expect(DesktopAppShortcut.appID(from: Data("[Desktop Action other]\nX-Caboose-AppId=app.desktop\n".utf8)) == nil)
        #expect(DesktopAppShortcut.appID(from: Data("[Desktop Entry]\nX-Caboose-AppId=../app.desktop\n".utf8)) == nil)
        #expect(DesktopAppShortcut.appID(from: Data(repeating: 65, count: 262145)) == nil)
    }
    @Test func metadataStreamStopsAtItsHardLimit() async throws {
        let exact = AsyncStream<UInt8> { continuation in
            for _ in 0..<DesktopAppShortcut.maximumBytes { continuation.yield(65) }
            continuation.finish()
        }
        let accepted = try await DesktopAppShortcut.read(exact)
        #expect(accepted.count == DesktopAppShortcut.maximumBytes)
        let tooLarge = AsyncStream<UInt8> { continuation in
            for _ in 0...DesktopAppShortcut.maximumBytes { continuation.yield(65) }
            continuation.finish()
        }
        do {
            _ = try await DesktopAppShortcut.read(tooLarge)
            Issue.record("Oversized metadata was accepted")
        } catch { #expect((error as NSError).code == CocoaError.fileReadTooLarge.rawValue) }
    }
    @Test func acknowledgementCannotResurrectAWindowCompletedOrResetAttempt() {
        var state = DockLaunchState()
        let token = state.begin("editor")!
        #expect(state.pending["editor"]?.acknowledged == false)
        let acknowledged = state.acknowledge("editor", token: token)
        #expect(acknowledged)
        let rejected1 = state.acknowledge("editor", token: token)
        #expect(!rejected1)
        let duplicate = state.begin("editor")
        #expect(duplicate == nil)
        let finished = state.finish("editor", token: token)
        #expect(finished)
        let rejected2 = state.acknowledge("editor", token: token)
        #expect(!rejected2)
        let next = state.begin("editor")!
        let rejected3 = state.acknowledge("editor", token: token)
        #expect(!rejected3)
        state.reset()
        let rejected4 = state.acknowledge("editor", token: next)
        #expect(!rejected4)
    }
    @Test func launchesCoalesceAndOldCompletionsCannotClearRetries() {
        var state = DockLaunchState()
        let first = state.begin("browser")!
        let duplicate = state.begin("browser")
        #expect(duplicate == nil)
        let secondApp = state.begin("editor")!
        let finished = state.finish("browser", token: first)
        #expect(finished)
        let retry = state.begin("browser")!
        let stale = state.finish("browser", token: first)
        #expect(!stale)
        #expect(state.pending["browser"]?.token == retry)
        #expect(state.pending["editor"]?.token == secondApp)
        state.reset()
        let reset = state.finish("browser", token: retry)
        #expect(!reset)
        #expect(state.pending.isEmpty)
    }
}
