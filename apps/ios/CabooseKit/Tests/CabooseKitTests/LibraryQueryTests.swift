import Testing
@testable import CabooseKit

/// The Library pages through one ranked list from the host's discover route.
struct LibraryQueryTests {
    @Test func theOpeningLibraryAsksForEverything() {
        let query = LibraryQuery()
        #expect(query.isUnfiltered)
        #expect(query.path() == "/v1/catalog/discover?q=")
    }

    @Test func searchesAndCategoriesAreEncodedAsQueryValues() {
        let query = LibraryQuery(text: "  c++ & co/op  ", category: "Video & Audio")
        #expect(!query.isUnfiltered)
        #expect(query.text == "c++ & co/op")
        #expect(query.path(offset: 40) == "/v1/catalog/discover?q=c%2B%2B%20%26%20co%2Fop&category=Video%20%26%20Audio&offset=40")
    }

    @Test func aBlankSearchInACategoryIsFiltered() {
        let query = LibraryQuery(text: "   ", category: "Games")
        #expect(!query.isUnfiltered)
        #expect(query == LibraryQuery(category: "Games"))
        #expect(query.path() == "/v1/catalog/discover?q=&category=Games")
    }

    @Test func pagingStopsAtTheTotalOrAnEmptyPage() {
        #expect(LibraryQuery.nextOffset(after: 0, count: 40, total: 3300) == 40)
        #expect(LibraryQuery.nextOffset(after: 3280, count: 20, total: 3300) == nil)
        #expect(LibraryQuery.nextOffset(after: 40, count: 0, total: 3300) == nil)
    }

    @Test func aLaterPageNeverRepeatsAnEntry() {
        struct Entry: Identifiable, Equatable { let id: String }
        let first = [Entry(id: "gimp"), Entry(id: "flathub-org.mozilla.firefox")]
        let next = [Entry(id: "flathub-org.mozilla.firefox"), Entry(id: "flathub-org.kde.krita"), Entry(id: "flathub-org.kde.krita")]
        #expect(first.appendingPage(next).map(\.id) == ["gimp", "flathub-org.mozilla.firefox", "flathub-org.kde.krita"])
    }
}
