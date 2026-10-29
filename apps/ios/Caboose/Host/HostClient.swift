import Foundation

/// The caboose-host HTTP API (see docs/architecture.md).
struct HostClient: Sendable {
    struct Session: Decodable, Sendable {
        struct Display: Decodable, Sendable {
            var path: String
            var token: String
        }
        struct Computer: Decodable, Sendable {
            var name: String
            var image: String
            var memoryMb: Int
            var vcpus: Int
        }
        var state: String
        var display: Display
        var computer: Computer
    }

    struct App: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var icon: String
        var categories: [String]
        var exec: String
        /// The entry's desktop actions (`New Private Window`); absent from hosts that predate them.
        var actions: [Action]?
        var startupWMClass: String?

        struct Action: Codable, Hashable, Sendable {
            var id: String
            var name: String
        }

        /// The PNG behind the icon's data URL.
        var iconData: Data? {
            guard let comma = icon.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(icon[icon.index(after: comma)...]))
        }
    }

    /// `GET /v1/computer`: the computer's settings and what it is running with now.
    struct ComputerStatus: Decodable, Equatable, Sendable {
        struct Size: Decodable, Equatable, Identifiable, Sendable {
            var id: String
            var name: String
            var memoryMb: Int
            var vcpus: Int
            var available: Bool
        }
        struct Settings: Codable, Equatable, Sendable {
            var name: String
            var memoryMb: Int
            var vcpus: Int
            var idleMs: Int
        }
        struct Resources: Decodable, Equatable, Sendable {
            var memoryMb: Int
            var vcpus: Int
        }
        struct Clients: Decodable, Equatable, Sendable {
            var display: Int
            var control: Int
        }
        struct Tasks: Decodable, Equatable, Sendable {
            var running: Int
            var paused: Int
        }
        struct Capabilities: Decodable, Equatable, Sendable {
            var restart: Bool
            var push: Bool?
        }
        struct Upgrade: Decodable, Equatable, Sendable {
            var state: String
            var version: String?
            var message: String?
        }
        struct Bounds: Decodable, Equatable, Sendable {
            var min: Int
            var max: Int
            var range: ClosedRange<Int> { min ... Swift.max(min, max) }
        }
        struct Limits: Decodable, Equatable, Sendable {
            var memoryMb: Bounds
            var vcpus: Bounds
            var idleMs: Bounds
        }
        var state: String
        var settings: Settings
        var sizes: [Size]?
        var activeResources: Resources?
        var restartRequired: Bool
        var clients: Clients
        var tasks: Tasks
        var capabilities: Capabilities
        var lastError: String?
        var upgrade: Upgrade?
        /// The bounds `PATCH /v1/computer/settings` accepts.
        var limits: Limits
    }

    enum Failure: LocalizedError {
        case unauthorized
        case notRunning
        case server(Int, String?)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Your computer did not accept this sign-in token."
            case .notRunning: "Your computer is not awake."
            case .server(let status, let message): message ?? "Your computer answered with an error (\(status))."
            case .unreachable(let reason): "Your computer could not be reached. \(reason)"
            }
        }
    }

    var baseURL: URL
    var token: String

    /// A cold boot can take minutes; reconnecting to a computer that was just running passes a shorter `timeout`.
    func wake(timeout: TimeInterval = 300) async throws -> Session { try await request("POST", "/v1/session", timeout: timeout) }
    func apps() async throws -> [App] { try await request("GET", "/v1/apps", timeout: 60) }

    /// Starts an app, or one of its desktop actions.
    func launch(_ app: App, action: App.Action? = nil) async throws {
        let id = app.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? app.id
        let body: [String: JSONValue]? = action.map { ["action": .string($0.id)] }
        let reply: [String: Bool] = try await request("POST", "/v1/apps/\(id)/launch", body: body, timeout: 30)
        guard reply["launched"] == true else {
            throw Failure.server(200, "The computer did not acknowledge the application launch.")
        }
    }

    func createDesktopShortcut(_ appID: String) async throws {
        let id = appID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? appID
        let _: [String: String] = try await request("POST", "/v1/apps/\(id)/desktop-shortcut", timeout: 30)
    }

    func park() async throws {
        let _: [String: String] = try await request("POST", "/v1/session/park", timeout: 120)
    }

    func computer() async throws -> ComputerStatus { try await request("GET", "/v1/computer", timeout: 20) }

    /// Saves only the settings that changed; the host rejects unknown or out-of-range values.
    func updateSettings(_ changes: [String: JSONValue]) async throws -> ComputerStatus {
        try await request("PATCH", "/v1/computer/settings", body: changes, timeout: 30)
    }

    /// Cold restart: open apps close, the disk is kept. Callers confirm with the person first.
    func restart() async throws -> ComputerStatus {
        try await request("POST", "/v1/computer/restart", body: ["confirm": .bool(true)], timeout: 300)
    }

    /// The WebSocket URL for a path on this host (http → ws, https → wss).
    func socketURL(_ path: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// The address of a route. `path` is percent-encoded (ids through `pathComponent`) and may
    /// end in a query string; characters a URL cannot hold are encoded, escapes are kept.
    func endpoint(_ path: String) -> URL {
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + path) ?? baseURL.appendingPathComponent(path)
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: [String: JSONValue]? = nil,
                               timeout: TimeInterval) async throws -> T {
        let data = try await send(method, path, body: body, accept: "application/json", timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The bytes a `GET` route answers with, such as an image, signed in like every request.
    func data(_ path: String, accept: String = "*/*", timeout: TimeInterval) async throws -> Data {
        try await send("GET", path, body: nil, accept: accept, timeout: timeout)
    }

    private func send(_ method: String, _ path: String, body: [String: JSONValue]?, accept: String,
                      timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: endpoint(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300:
            return data
        case 401, 403:
            throw Failure.unauthorized
        case 409 where path.hasPrefix("/v1/agent/profiles") || path.hasPrefix("/v1/agent/routines") || path.hasPrefix("/v1/computer") || path.hasPrefix("/v1/catalog") || path.hasPrefix("/v1/mcp/") || path == "/v1/session/park":
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.server(status, message)
        case 409:
            throw Failure.notRunning
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.server(status, message)
        }
    }
}

/// A JSON request value: just what the host API takes.
enum JSONValue: Encodable, Equatable, Sendable, ExpressibleByStringLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
