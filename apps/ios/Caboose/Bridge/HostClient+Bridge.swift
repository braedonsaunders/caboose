import CabooseKit
import Foundation

/// The native bridge routes (docs/native-bridge.md § Host). They never wake the computer.
extension HostClient {
    struct FolderItem: Decodable, Hashable, Sendable {
        let name: String
        let kind: String
        let mtime: Double
        var isFolder: Bool { kind == "directory" }
    }

    /// Answers a file request; false when the host no longer has it (answered elsewhere, or withdrawn).
    @discardableResult
    func answerBridge(_ id: String, _ answer: BridgeAnswer) async throws -> Bool {
        let reply = try await send("POST", "/v1/bridge/requests/\(id)", body: answer)
        if reply.status == 404 { return false }
        try check(reply)
        return true
    }

    /// The phone's appearance; ignored by a host without the bridge.
    func putAppearance(_ appearance: BridgeAppearance) async throws {
        let reply = try await send("PUT", "/v1/bridge/appearance", body: appearance)
        if reply.status != 404 { try check(reply) }
    }

    func putLocation(latitude: Double, longitude: Double, accuracy: Double, altitude: Double?) async throws {
        struct Location: Encodable { let latitude: Double, longitude: Double, accuracy: Double, altitude: Double? }
        let reply = try await send("PUT", "/v1/bridge/location", body: Location(latitude: latitude, longitude: longitude, accuracy: accuracy, altitude: altitude))
        if reply.status != 404 && reply.status != 429 { try check(reply) }
    }

    func deleteLocation() async throws {
        let reply = try await send("DELETE", "/v1/bridge/location", body: Optional<[String: String]>.none)
        if reply.status != 404 { try check(reply) }
    }

    func nowPlayingControl(_ id: String, action: String, position: Double? = nil) async throws {
        struct Command: Encodable { let action: String; let position: Double? }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        try check(try await send("POST", "/v1/now-playing/\(encoded)/control", body: Command(action: action, position: position)))
    }

    /// A folder of the computer's home, folders first, then by name.
    func folder(_ path: ComputerPath) async throws -> [FolderItem] {
        struct Listing: Decodable { let items: [FolderItem] }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/list"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path.relative)]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure.unreachable(error.localizedDescription) }
        try check(Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data))
        return try JSONDecoder().decode(Listing.self, from: data).items.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private struct Reply { let status: Int; let data: Data }

    /// Sends a JSON body; transport failures throw, statuses are the caller's to judge.
    private func send<Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch { throw Failure.unreachable(error.localizedDescription) }
    }

    private func check(_ reply: Reply) throws {
        switch reply.status {
        case 200 ..< 300: return
        case 401, 403: throw Failure.unauthorized
        case 409: throw Failure.notRunning
        default: throw Failure.server(reply.status, (try? JSONDecoder().decode([String: String].self, from: reply.data))?["error"])
        }
    }
}
