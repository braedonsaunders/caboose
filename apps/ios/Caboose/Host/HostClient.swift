import Foundation

/// The caboose-host HTTP API (see docs/architecture.md).
struct HostClient: Sendable {
    struct Session: Decodable, Sendable {
        struct Display: Decodable, Sendable {
            var path: String
            var token: String
            var `protocol`: String
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

    struct App: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var icon: String
        var categories: [String]
        var exec: String

        /// The PNG behind the icon's data URL.
        var iconData: Data? {
            guard let comma = icon.firstIndex(of: ",") else { return nil }
            return Data(base64Encoded: String(icon[icon.index(after: comma)...]))
        }
    }

    /// `GET /v1/computer`: the computer's settings and what it is running with now.
    struct ComputerStatus: Decodable, Equatable, Sendable {
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
        var activeResources: Resources?
        var restartRequired: Bool
        var clients: Clients
        var tasks: Tasks
        var capabilities: Capabilities
        var lastError: String?
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

    func wake() async throws -> Session { try await request("POST", "/v1/session", timeout: 300) }
    func apps() async throws -> [App] { try await request("GET", "/v1/apps", timeout: 60) }

    func launch(_ app: App) async throws {
        let id = app.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? app.id
        let _: [String: Bool] = try await request("POST", "/v1/apps/\(id)/launch", timeout: 30)
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

    func request<T: Decodable>(_ method: String, _ path: String, body: [String: JSONValue]? = nil,
                               timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            return try JSONDecoder().decode(T.self, from: data)
        case 401, 403:
            throw Failure.unauthorized
        case 409 where path.hasPrefix("/v1/computer"):
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
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
