import Foundation

/// A file handed to an agent with its task, e.g. a screenshot of a window.
struct AgentAttachment: Sendable {
    var name: String
    var type: String
    var data: Data
    var json: JSONValue {
        .object(["name": .string(name), "type": .string(type), "data": .string(data.base64EncodedString())])
    }
}

/// What the app and its share extension send to the computer.
extension HostClient {
    /// `agent` is a registry id; nil runs the owner's default agent.
    func startAgentTask(prompt: String, agent: String?, approvals: String = "auto",
                        attachments: [AgentAttachment] = [], craftMcp: Bool = true, model: String? = nil) async throws -> String {
        struct Started: Decodable { var id: String }
        var body: [String: JSONValue] = ["prompt": .string(prompt), "approvals": .string(approvals), "craftMcp": .bool(craftMcp)]
        if let model { body["model"] = .string(model) }
        if let agent, !agent.isEmpty { body["agent"] = .string(agent) }
        if !attachments.isEmpty {
            body["attachments"] = .array(attachments.map(\.json))
        }
        let started: Started = try await request("POST", "/v1/agent/tasks", body: body, timeout: 120)
        return started.id
    }

    /// Upload directly from a local file, retaining only URLSession's streaming buffers.
    func sendFile(name: String, file: URL, open: Bool = false) async throws -> String {
        func endpoint(_ operation: String, _ path: String) -> URL {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            return components.url!
        }
        var mkdir = URLRequest(url: endpoint("mkdir", "Downloads"), timeoutInterval: 300)
        mkdir.httpMethod = "POST"
        mkdir.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, created) = try await URLSession.shared.data(for: mkdir)
        guard let created = created as? HTTPURLResponse, (200..<300).contains(created.statusCode) || created.statusCode == 409 else {
            throw Failure.unreachable("Could not create Downloads.")
        }
        let clean = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = clean.isEmpty || clean == "." || clean == ".." ? "file" : clean
        let ext = (safe as NSString).pathExtension
        let stem = ext.isEmpty ? safe : (safe as NSString).deletingPathExtension
        for number in 1...10000 {
            let suffix = number == 1 ? "" : " (\(number))"
            let target = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let path = "Downloads/" + target
            var upload = URLRequest(url: endpoint("content", path), timeoutInterval: 3600)
            upload.httpMethod = "PUT"
            upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            upload.setValue("*", forHTTPHeaderField: "If-None-Match")
            let (_, response) = try await URLSession.shared.upload(for: upload, fromFile: file)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 412 { continue }
            guard (200..<300).contains(status) else { throw Failure.server(status, "Could not upload the file.") }
            if open {
                let _: [String: Bool] = try await request("POST", "/v1/fs/open", body: ["path": .string(path)], timeout: 120)
            }
            return "/home/caboose/" + path
        }
        throw Failure.unreachable("Could not find a free file name in Downloads.")
    }

    func sendFile(name: String, data: Data, open: Bool = false) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await sendFile(name: name, file: file, open: open)
    }

    /// Opens a web page in the computer's browser, on the owner's display.
    func open(_ url: URL) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/open", body: ["url": .string(url.absoluteString)], timeout: 120)
    }
}
