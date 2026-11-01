import CabooseKit
import Foundation

/// The running apps (docs/architecture.md, Running apps). None of these wake the computer.
extension HostClient {
    func runningApps() async throws -> RunningAppsListing {
        try await request("GET", RunningAppsRoute.list, timeout: 15)
    }

    /// Asks every window of the app to close; the number asked.
    func quitRunningApp(_ id: String) async throws -> Int {
        let reply: RunningAppQuitReply = try await request("POST", RunningAppsRoute.path(.quit, id: id), timeout: 20)
        return reply.closed
    }

    /// SIGTERM, then a kill after 5 s; the host answers within a further 2 s.
    func forceQuitRunningApp(_ id: String) async throws -> RunningAppEndReply {
        try await request("POST", RunningAppsRoute.path(.forceQuit, id: id), timeout: 30)
    }

    func killRunningApp(_ id: String) async throws -> RunningAppEndReply {
        try await request("POST", RunningAppsRoute.path(.kill, id: id), timeout: 20)
    }
}

/// The computer's services (docs/architecture.md, Services). None of these wake the computer.
extension HostClient {
    /// Start, stop, restart, enable or disable → the service's status. Stopping waits for it to stop.
    func service(_ action: ServicesRoute.Action, name: String) async throws -> RunningService {
        try await request("POST", ServicesRoute.path(action, name: name), timeout: 60)
    }

    func serviceLog(name: String, lines: Int) async throws -> [String] {
        struct Log: Decodable { var lines: [String] }
        let log: Log = try await request("GET", ServicesRoute.logs(name: name, lines: lines), timeout: 15)
        return log.lines
    }

    /// Creates or replaces an owner service; it is not started.
    func saveService(name: String, _ definition: ServiceDefinition) async throws -> RunningService {
        let data = try await send("PUT", ServicesRoute.path(name: name), payload: try JSONEncoder().encode(definition),
                                  contentType: "application/json", accept: "application/json", timeout: 30)
        return try JSONDecoder().decode(RunningService.self, from: data)
    }

    /// Stops an owner service and removes its unit file.
    func deleteService(name: String) async throws {
        let _: [String: Bool] = try await request("DELETE", ServicesRoute.path(name: name), timeout: 60)
    }
}
