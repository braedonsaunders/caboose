import Foundation

/// A file handed to an agent with its task, e.g. a screenshot of a window.
struct AgentAttachment: Sendable {
    var name: String
    var type: String
    var data: Data
}

/// What the app and its share extension send to the computer.
extension HostClient {
    func startAgentTask(prompt: String, agent: String, approvals: String = "auto",
                        attachments: [AgentAttachment] = []) async throws -> String {
        struct Started: Decodable { var id: String }
        var body: [String: JSONValue] = ["prompt": .string(prompt), "agent": .string(agent), "approvals": .string(approvals)]
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map {
                .object(["name": .string($0.name), "type": .string($0.type), "data": .string($0.data.base64EncodedString())])
            })
        }
        let started: Started = try await request("POST", "/v1/agent/tasks", body: body, timeout: 120)
        return started.id
    }

    /// Saves a file in the computer's Downloads folder, optionally opening it there.
    func sendFile(name: String, data: Data, open: Bool = false) async throws -> String {
        struct Saved: Decodable { var path: String }
        let saved: Saved = try await request("POST", "/v1/files", body: [
            "name": .string(name), "data": .string(data.base64EncodedString()), "open": .bool(open),
        ], timeout: 300)
        return saved.path
    }

    /// Opens a web page in the computer's browser, on the owner's display.
    func open(_ url: URL) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/open", body: ["url": .string(url.absoluteString)], timeout: 120)
    }
}
