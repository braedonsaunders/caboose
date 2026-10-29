import Foundation

/// What the Library asks the host's discover route for: a search within one category or one
/// curated collection, or within all of them, a page at a time (docs/architecture.md, Catalog).
public struct LibraryQuery: Hashable, Sendable {
    /// The search, without surrounding whitespace, so a trailing space asks nothing new.
    public let text: String
    /// One of the categories discover lists, or "" for every category.
    public let category: String
    /// A curated collection's id, or "". A collection is browsed, never installed at once;
    /// the host answers with its apps, then popular apps in its category.
    public let collection: String

    public init(text: String = "", category: String = "", collection: String = "") {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The host takes a collection or a category, not both; the collection wins.
        self.category = collection.isEmpty ? category : ""
        self.collection = collection
    }

    /// The Library as it opens: no search, category or collection, where the collections show.
    public var isUnfiltered: Bool { text.isEmpty && category.isEmpty && collection.isEmpty }

    /// The page of results that starts at `offset`, percent-encoded for the host client.
    public func path(offset: Int = 0) -> String {
        var items = ["q=" + Self.encode(text)]
        if !category.isEmpty { items.append("category=" + Self.encode(category)) }
        if !collection.isEmpty { items.append("collection=" + Self.encode(collection)) }
        if offset > 0 { items.append("offset=\(offset)") }
        return "/v1/catalog/discover?" + items.joined(separator: "&")
    }

    /// Where the next page starts, or nil once every result has arrived. An empty page ends
    /// the list even if `total` says otherwise, so a shrinking index cannot loop forever.
    public static func nextOffset(after offset: Int, count: Int, total: Int) -> Int? {
        let next = offset + count
        return count > 0 && next < total ? next : nil
    }

    private static let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/"))
    private static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
}

extension Array where Element: Identifiable {
    /// The next page of results after these, without an entry the ranking moved between pages
    /// appearing twice.
    public func appendingPage(_ page: [Element]) -> [Element] {
        var seen = Set(map(\.id))
        return self + page.filter { seen.insert($0.id).inserted }
    }
}
