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

    /// The WebSocket URL for a path on this host (http → ws, https → wss).
    func socketURL(_ path: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    private func request<T: Decodable>(_ method: String, _ path: String, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        case 409:
            throw Failure.notRunning
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.server(status, message)
        }
    }
}
