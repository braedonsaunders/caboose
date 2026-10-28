import Testing
@testable import CabooseKit

struct DocumentTypeMatchingTests {
    @Test func matchesExtensionsAndUTIsWithoutInventingHandlers() {
        #expect(DocumentTypeMatching.matches(filename: "Art.PSD", typeIdentifier: nil, extensions: ["psd"], typeIdentifiers: []))
        #expect(DocumentTypeMatching.matches(filename: "untitled", typeIdentifier: "public.png", extensions: [], typeIdentifiers: ["public.png"]))
        #expect(!DocumentTypeMatching.matches(filename: "art.psdx", typeIdentifier: nil, extensions: ["psd"], typeIdentifiers: []))
        #expect(!DocumentTypeMatching.matches(filename: "untitled", typeIdentifier: "", extensions: [], typeIdentifiers: [""]))
    }
}
