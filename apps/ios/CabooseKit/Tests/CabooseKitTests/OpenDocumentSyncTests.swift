import Testing
@testable import CabooseKit

struct OpenDocumentSyncTests {
    @Test func comparesBothSidesToTheirOwnBaselines() {
        #expect(OpenDocumentSync.decide(local: "a", baselineLocal: "a", remote: "1", baselineRemote: "1") == .unchanged)
        #expect(OpenDocumentSync.decide(local: "b", baselineLocal: "a", remote: "1", baselineRemote: "1") == .uploadLocal)
        #expect(OpenDocumentSync.decide(local: "a", baselineLocal: "a", remote: "2", baselineRemote: "1") == .downloadRemote)
        #expect(OpenDocumentSync.decide(local: "b", baselineLocal: "a", remote: "2", baselineRemote: "1") == .conflict)
    }
}
