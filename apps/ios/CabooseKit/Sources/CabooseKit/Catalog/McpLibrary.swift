import Foundation

// The MCP Library's view of the host's `/v1/mcp` routes (docs/architecture.md, MCP Library):
// servers Smithery lists, and the ones a computer has added, which every agent on it can use.

/// A server Smithery lists.
public struct McpServer: Decodable, Identifiable, Hashable, Sendable {
    /// Smithery's qualified name, such as `brave` or `upstash/context7-mcp`.
    public let id: String
    public let name: String
    public let description: String
    /// Smithery's count of uses, its measure of popularity.
    public let uses: Int
    /// Smithery verified the publisher. It is not a review of the server.
    public let verified: Bool
    public let homepage: String?
    /// The icon's id for `/v1/mcp/icons/<id>`, or nil when the server has none.
    public let iconId: String?
    /// This computer's connection to the server, when it has added it.
    public var connection: String?

    public init(id: String, name: String, description: String, uses: Int = 0, verified: Bool = false,
                homepage: String? = nil, iconId: String? = nil, connection: String? = nil) {
        self.id = id; self.name = name; self.description = description; self.uses = uses
        self.verified = verified; self.homepage = homepage; self.iconId = iconId; self.connection = connection
    }

    /// The server's homepage, when it is a web address.
    public var homepageURL: URL? {
        guard let homepage, let url = URL(string: homepage), url.scheme == "https" else { return nil }
        return url
    }
}

/// A tool a server offers, as Smithery lists it.
public struct McpTool: Decodable, Hashable, Sendable {
    public let name: String
    public let description: String
}

/// `GET /v1/mcp/servers/<id>`: the server and the tools Smithery lists for it.
public struct McpServerDetail: Decodable, Sendable {
    public var server: McpServer
    public let tools: [McpTool]

    private enum CodingKeys: String, CodingKey { case tools }
    public init(from decoder: Decoder) throws {
        server = try McpServer(from: decoder)
        tools = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([McpTool].self, forKey: .tools) ?? []
    }
}

/// A row of the MCP Library's front page: Popular, Verified, then topics.
public struct McpShelf: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// What the row's order means, such as "Ranked by uses on Smithery".
    public let note: String?
    public var servers: [McpServer]
}

public struct McpStorefront: Decodable, Sendable {
    public let groups: [McpShelf]
    /// Why the rows are missing or old: Smithery could not be reached.
    public let error: String?
}

/// One page of `GET /v1/mcp/discover`.
public struct McpSearchPage: Decodable, Sendable {
    public let servers: [McpServer]
    public let total: Int
    /// 1-based.
    public let page: Int
    public let pageSize: Int
}

/// `GET`, `PUT` and `DELETE /v1/mcp/account`: whether this computer has a Smithery account.
public struct McpAccount: Decodable, Equatable, Sendable {
    public let connected: Bool
    public let namespace: String?
    /// A disconnect Smithery could not finish: agents have no access until it does.
    public let disconnecting: Bool
    public init(connected: Bool, namespace: String?, disconnecting: Bool = false) { self.connected = connected; self.namespace = namespace; self.disconnecting = disconnecting }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        connected = try values.decode(Bool.self, forKey: .connected)
        namespace = try values.decodeIfPresent(String.self, forKey: .namespace)
        disconnecting = try values.decodeIfPresent(Bool.self, forKey: .disconnecting) ?? false
    }
    private enum Keys: String, CodingKey { case connected, namespace, disconnecting }
}

/// A setting a server asked for before it can connect.
public struct McpSetupField: Decodable, Hashable, Identifiable, Sendable {
    public enum Location: String, Decodable, Sendable { case header, query }
    public let key: String
    /// Where the server takes it. A header value is entered as a secret.
    public let location: Location
    public let label: String
    public let description: String
    public let required: Bool
    public var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, location = "where", label, description, required }

    public init(key: String, location: Location, label: String, description: String = "", required: Bool) {
        self.key = key; self.location = location; self.label = label; self.description = description; self.required = required
    }
}

/// How one of the computer's servers is doing, as Smithery last reported it.
public enum McpConnectionStatus: Decodable, Hashable, Sendable {
    case connected(tools: Int)
    /// The server needs its owner to sign in on Smithery's page.
    case needsSignIn(URL)
    /// The server needs settings, such as its API key.
    case needsSetup(fields: [McpSetupField], setupURL: URL?)
    case failed(String)
    case checking

    private enum CodingKeys: String, CodingKey { case state, tools, setupUrl, fields, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let setup = (try? container.decodeIfPresent(String.self, forKey: .setupUrl)).flatMap(Self.smitheryPage)
        switch try container.decode(String.self, forKey: .state) {
        case "connected":
            self = .connected(tools: try container.decodeIfPresent(Int.self, forKey: .tools) ?? 0)
        case "needs-sign-in":
            // Only Smithery's own pages open in the app's browser.
            self = setup.map(Self.needsSignIn) ?? .failed("This server needs a sign-in Caboose could not start.")
        case "needs-setup":
            self = .needsSetup(fields: try container.decodeIfPresent([McpSetupField].self, forKey: .fields) ?? [], setupURL: setup)
        case "failed":
            self = .failed(try container.decodeIfPresent(String.self, forKey: .message) ?? "The server didn't accept the connection.")
        case "checking":
            self = .checking
        default:
            self = .failed("Update Caboose to see how this server is doing.")
        }
    }

    /// An https page on smithery.ai or one of its subdomains, without credentials.
    public static func smitheryPage(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host == "smithery.ai" || host.hasSuffix(".smithery.ai") else { return nil }
        return url
    }
}

/// One of the computer's servers.
public struct McpConnection: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    /// The server's qualified name.
    public let server: String
    public let name: String
    public let iconId: String?
    public let addedAt: String
    public var status: McpConnectionStatus

    public init(id: String, server: String, name: String, iconId: String? = nil, addedAt: String = "", status: McpConnectionStatus) {
        self.id = id; self.server = server; self.name = name; self.iconId = iconId; self.addedAt = addedAt; self.status = status
    }
}

/// `GET /v1/mcp/connections`.
public struct McpConnections: Decodable, Sendable {
    public let account: Bool
    /// How many servers a computer holds.
    public let limit: Int
    public let connections: [McpConnection]
}

/// The host's MCP Library routes, percent-encoded for the host client.
public enum McpRoute {
    public static let account = "/v1/mcp/account"
    public static let storefront = "/v1/mcp/storefront"
    public static let connections = "/v1/mcp/connections"
    /// The highest page the host's discover route serves.
    public static let lastPage = 250

    /// A server by qualified name. Each segment is encoded on its own, so the one `/` a
    /// qualified name may hold stays a separator and nothing else can add one.
    public static func server(_ id: String) -> String {
        "/v1/mcp/servers/" + id.split(separator: "/", omittingEmptySubsequences: false).map { segment($0) }.joined(separator: "/")
    }

    /// A page (1-based) of Smithery's search, or of everything for an empty search.
    public static func discover(_ text: String, page: Int = 1) -> String {
        "/v1/mcp/discover?q=" + query(text.trimmingCharacters(in: .whitespacesAndNewlines)) + "&page=\(max(1, page))"
    }

    /// A page (1-based) of one front-page row in full, for See All.
    public static func group(_ id: String, page: Int = 1) -> String {
        "/v1/mcp/discover?group=" + query(id) + "&page=\(max(1, page))"
    }

    public static func connections(refresh: Bool) -> String { refresh ? connections + "?refresh=1" : connections }
    public static func connection(_ id: String) -> String { connections + "/" + segment(id) }
    public static func check(_ id: String) -> String { connection(id) + "/check" }
    public static func icon(_ id: String) -> String { "/v1/mcp/icons/" + segment(id) }

    /// The page after `page`, or nil once every result has arrived. An empty page ends the
    /// list even if `total` says otherwise, so a shrinking index cannot loop forever.
    public static func nextPage(after page: Int, count: Int, total: Int, pageSize: Int) -> Int? {
        count > 0 && pageSize > 0 && page * pageSize < total && page < lastPage ? page + 1 : nil
    }

    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))
    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#/%"))
    private static func segment<S: StringProtocol>(_ value: S) -> String { value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? "" }
    private static func query(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? "" }
}

/// The settings a server asked for, as the person fills them in. What it sends holds only the
/// keys the server declared, and only once every required one has a value.
public struct McpSetupForm: Equatable, Sendable {
    public let fields: [McpSetupField]
    public var values: [String: String] = [:]

    public init(fields: [McpSetupField]) { self.fields = fields }

    private func value(_ field: McpSetupField) -> String {
        (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Required settings that are still empty, in the server's order.
    public var missing: [McpSetupField] { fields.filter { $0.required && value($0).isEmpty } }
    public var isComplete: Bool { missing.isEmpty }

    /// The `values` for `PATCH /v1/mcp/connections/<id>`: declared keys only, trimmed, with
    /// empty optional settings left out. Nil while a required setting is empty.
    public var submission: [String: String]? {
        guard isComplete else { return nil }
        var result: [String: String] = [:]
        for field in fields {
            let value = value(field)
            if !value.isEmpty { result[field.key] = value }
        }
        return result
    }
}

extension Array where Element == McpServer {
    /// These servers with this computer's connections marked, so Add and status follow changes
    /// made anywhere.
    public func marking(_ connections: [McpConnection]) -> [McpServer] {
        let added = Dictionary(connections.map { ($0.server, $0.id) }, uniquingKeysWith: { first, _ in first })
        return map { server in var server = server; server.connection = added[server.id]; return server }
    }
}
