import Foundation

/// A way to sign in to an agent, as the agent announced it (docs/architecture.md § Signing in).
struct SignInMethod: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    /// "agent": the agent's own sign-in page in the computer's browser; "terminal": a terminal window there.
    var type: String
}

/// An agent from the ACP registry, as this computer sees it (`GET /v1/agents`).
struct AgentListing: Decodable, Identifiable, Hashable, Sendable {
    struct Installed: Decodable, Hashable, Sendable { var version: String }
    struct SignInStatus: Decodable, Hashable, Sendable {
        var methodId: String
        var status: String
        var message: String?
    }

    var id: String
    var name: String
    var version: String
    var description: String
    var website: String?
    var repository: String?
    var license: String?
    var distribution: String
    var installed: Installed?
    var signIn: [SignInMethod]?
    var signInStatus: SignInStatus?
    /// Variable names the agent's environment file in the computer sets; never values.
    var env: [String]?

    var isInstalled: Bool { installed != nil }
    var hasUpdate: Bool { installed.map { $0.version != version } ?? false }
    /// Registry icons are SVG, which iOS does not draw; agents show their initials instead.
    var monogram: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }
}

struct AgentsResponse: Decodable, Sendable {
    struct Registry: Decodable, Sendable {
        var fetchedAt: String?
        var error: String?
    }
    var agents: [AgentListing]
    var defaultAgent: String?
    var registry: Registry
}

extension HostClient {
    /// Never wakes the computer.
    func agents() async throws -> AgentsResponse { try await request("GET", "/v1/agents", timeout: 30) }

    /// Downloads the agent into the computer; a large agent can take minutes.
    func installAgent(_ id: String) async throws -> AgentListing {
        struct Installed: Decodable { var agent: AgentListing }
        let installed: Installed = try await request("POST", "/v1/agents/\(Self.pathComponent(id))/install", timeout: 900)
        return installed.agent
    }

    /// Opens the sign-in on the computer's own screen.
    func signInAgent(_ id: String, method: String) async throws {
        struct Started: Decodable { var started: Bool }
        let _: Started = try await request("POST", "/v1/agents/\(Self.pathComponent(id))/sign-in", body: ["methodId": .string(method)], timeout: 240)
    }

    /// Sets or removes variables, such as an API key, in the agent's environment in the computer.
    func setAgentEnv(_ id: String, set: [String: String] = [:], remove: [String] = []) async throws -> [String] {
        struct Names: Decodable { var env: [String] }
        let names: Names = try await request("PUT", "/v1/agents/\(Self.pathComponent(id))/env", body: [
            "set": .object(set.mapValues { .string($0) }), "remove": .array(remove.map { .string($0) }),
        ], timeout: 30)
        return names.env
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
