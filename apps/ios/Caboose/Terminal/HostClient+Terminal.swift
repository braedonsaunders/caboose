import CabooseKit
import Foundation

/// The terminal routes (docs/architecture.md § Terminal). The terminal itself is a WebSocket
/// that `TerminalModel` opens with `TerminalProtocol.url`.
extension HostClient {
    struct TerminalSessions: Decodable, Sendable { var sessions: [TerminalSessionInfo] }

    /// The computer's open terminals, oldest first. Answers `notRunning` while it is parked.
    func terminalSessions() async throws -> [TerminalSessionInfo] {
        let list: TerminalSessions = try await request("GET", "/v1/terminal/sessions", timeout: 20)
        return list.sessions
    }

    /// Hangs up a session's shell; whoever is attached sees it exit.
    func hangUpTerminal(_ id: String) async throws {
        let _: [String: Bool] = try await request("DELETE", "/v1/terminal/sessions/\(id)", timeout: 20)
    }
}
