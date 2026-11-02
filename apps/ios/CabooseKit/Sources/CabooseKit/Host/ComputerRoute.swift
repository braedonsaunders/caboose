import Foundation

/// Where a computer's routes are on its host (docs/architecture.md § Computers).
///
/// A sign-in bound to one computer, and the owner token, reach a computer through the
/// unscoped routes (`/v1/session`, `/v1/display`, …). A host sign-in reaches each computer
/// through its scoped form, `/v1/computers/<id>/<route>`, WebSocket upgrades included. The
/// host's own routes (`/v1/computers`, `/v1/host/…`, `/v1/health`, `/v1/pair`) are never
/// scoped.
///
/// Foundation only: the share and widget extensions compile this file directly.
public struct ComputerRoute: Equatable, Hashable, Sendable {
    /// The computer the routes are scoped to; nil for the unscoped routes.
    public var computer: String?

    public init(computer: String?) {
        self.computer = computer.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let unscoped = ComputerRoute(computer: nil)

    /// Whether `path` (without a query) is one of the host's own routes rather than a computer's.
    public static func isHostRoute(_ path: String) -> Bool {
        let route = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        for root in ["/v1/computers", "/v1/host"] where route == root || route.hasPrefix(root + "/") { return true }
        return route == "/v1/health" || route == "/v1/pair"
    }

    /// `/v1/<route>[?query]` as this scope reaches it. Host routes, and paths that are not
    /// under `/v1/`, are returned unchanged, so mapping twice changes nothing.
    public func path(_ path: String) -> String {
        guard let computer, path.hasPrefix("/v1/"), !Self.isHostRoute(path) else { return path }
        return "/v1/computers/" + Self.segment(computer) + path.dropFirst("/v1".count)
    }

    /// The address of a route on a host. `base` may carry a prefix the host is served under;
    /// `path` is percent-encoded and may end in a query string.
    public func url(base: URL, _ path: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        let mapped = self.path(path)
        return URL(string: root + mapped) ?? base.appendingPathComponent(mapped)
    }

    /// The WebSocket address of a route (http → ws, https → wss).
    public func socketURL(base: URL, _ path: String) -> URL {
        let url = url(base: base, path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = ["https", "wss"].contains(base.scheme?.lowercased() ?? "") ? "wss" : "ws"
        return components.url ?? url
    }

    /// A route's path split into the prefix the host is served under, the computer it is
    /// scoped to (nil for an unscoped route) and the computer route itself:
    /// `/caboose/v1/computers/c-1/display` → (`/caboose`, `c-1`, `/v1/display`). Nil for a
    /// path with no `/v1/` route.
    public static func split(_ path: String) -> (prefix: String, route: ComputerRoute, path: String)? {
        if let scoped = path.range(of: "/v1/computers/") {
            let rest = path[scoped.upperBound...]
            if let slash = rest.firstIndex(of: "/"), slash != rest.startIndex {
                let id = String(rest[..<slash])
                return (String(path[..<scoped.lowerBound]), ComputerRoute(computer: id.removingPercentEncoding ?? id),
                        "/v1" + rest[slash...])
            }
        }
        guard let range = path.range(of: "/v1/", options: .backwards) else { return nil }
        return (String(path[..<range.lowerBound]), .unscoped, String(path[range.lowerBound...]))
    }

    /// A computer id as one path segment.
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%;"))) ?? id
    }
}
