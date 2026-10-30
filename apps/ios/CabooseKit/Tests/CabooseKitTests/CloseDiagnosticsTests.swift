import Testing
@testable import CabooseKit

@MainActor @Suite struct CloseDiagnosticsTests {
    @Test func peerEpochCannotInjectContentIntoCloseArtifact() {
        #expect(CloseDiagnostics.safeEpoch("0123456789abcdef") == "0123456789abcdef")
        #expect(CloseDiagnostics.safeEpoch(nil) == nil)
        #expect(CloseDiagnostics.safeEpoch("https://example.test/account") == nil)
        #expect(CloseDiagnostics.safeEpoch("0123456789abcdef\n") == nil)
        #expect(CloseDiagnostics.safeEpoch(String(repeating: "a", count: 65_536)) == nil)
        #expect(CloseDiagnostics.safeEpoch("0123456789abcdeé") == nil)
    }
}
