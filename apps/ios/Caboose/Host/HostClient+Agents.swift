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
        /// "phone" or "display"; absent from a computer whose runner predates signing in on the phone.
        var on: String?
        /// Which sign-in this is; absent from a runner that predates attempts.
        var attempt: String?
        /// On the phone: the page the sign-in opened, for the app to show.
        var url: String?
        /// On the phone: the terminal session a terminal method runs in.
        var terminal: String?
        var message: String?
        var startedAt: String?

        var isRunning: Bool { status == "running" }
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

    /// Starts a sign-in on the phone (its page and terminal come to the app), or on the computer's
    /// own screen. Returns its attempt, which a host from before attempts does not send.
    func signInAgent(_ id: String, method: String, onPhone: Bool) async throws -> String? {
        struct Started: Decodable { var started: Bool; var attempt: String? }
        let started: Started = try await request("POST", "/v1/agents/\(Self.pathComponent(id))/sign-in",
                                                 body: ["methodId": .string(method), "on": .string(onPhone ? "phone" : "display")], timeout: 240)
        return started.attempt
    }

    /// Hands the agent the address on the computer's loopback that sign-in `attempt`'s page sent the browser back to.
    func deliverSignInCallback(_ id: String, attempt: String, url: URL) async throws {
        struct Delivered: Decodable { var delivered: Bool }
        let _: Delivered = try await request("POST", "/v1/agents/\(Self.pathComponent(id))/sign-in/callback",
                                             body: ["attempt": .string(attempt), "url": .string(url.absoluteString)], timeout: 180)
    }

    /// Stops sign-in `attempt` if it is still the agent's running one; never a newer one.
    func cancelSignIn(_ id: String, attempt: String) async throws {
        struct Cancelled: Decodable { var cancelled: Bool }
        let _: Cancelled = try await request("POST", "/v1/agents/\(Self.pathComponent(id))/sign-in/cancel",
                                             body: ["attempt": .string(attempt)], timeout: 150)
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

struct AgentModelState: Decodable, Equatable, Sendable {
    struct Models: Decodable, Equatable, Sendable {
        struct Choice: Decodable, Equatable, Identifiable, Sendable {
            var id: String
            var name: String
            var description: String?
        }
        var currentModelId: String
        var availableModels: [Choice]
    }
    var requestedModel: String?
    var models: Models?
}

extension HostClient {
    func agentModels(_ id: String) async throws -> AgentModelState {
        try await request("POST", "/v1/agents/\(Self.pathComponent(id))/models", timeout: 180)
    }
    func taskModels(_ id: String) async throws -> AgentModelState {
        try await request("GET", "/v1/agent/tasks/\(Self.pathComponent(id))/models", timeout: 30)
    }
    func selectTaskModel(_ id: String, model: String) async throws -> AgentModelState {
        try await request("PUT", "/v1/agent/tasks/\(Self.pathComponent(id))/models", body: ["model": .string(model)], timeout: 30)
    }
}
