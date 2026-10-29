import Foundation

/// What the Library asks the host's discover route for: a search within one category, or
/// within all of them, a page at a time (docs/architecture.md, Catalog).
public struct LibraryQuery: Hashable, Sendable {
    /// The search, without surrounding whitespace, so a trailing space asks nothing new.
    public let text: String
    /// One of the categories discover lists, or "" for every category.
    public let category: String

    public init(text: String = "", category: String = "") {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
    }

    /// Every app, unsearched: the list See All on Popular opens.
    public var isUnfiltered: Bool { text.isEmpty && category.isEmpty }

    /// The page of results that starts at `offset`, percent-encoded for the host client.
    public func path(offset: Int = 0) -> String {
        var items = ["q=" + Self.encode(text)]
        if !category.isEmpty { items.append("category=" + Self.encode(category)) }
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
