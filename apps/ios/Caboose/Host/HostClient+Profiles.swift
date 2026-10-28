#if CABOOSE_APP
import CabooseKit
import Foundation

extension HostClient {
    struct Profiles: Decodable { var profiles: [AgentProfile] }
    struct Profile: Decodable { var profile: AgentProfile }
    struct Routines: Decodable { var routines: [AgentRoutine]; var error: String? }
    struct Routine: Decodable { var routine: AgentRoutine }
    struct Runs: Decodable { var runs: [AgentRoutineRun] }
    struct Run: Decodable { var run: AgentRoutineRun }

    func agentProfiles() async throws -> [AgentProfile] {
        let result: Profiles = try await request("GET", "/v1/agent/profiles", timeout: 30)
        return result.profiles
    }
    func saveProfile(_ id: String?, body: [String: JSONValue]) async throws -> AgentProfile {
        let path = "/v1/agent/profiles" + (id.map { "/" + Self.pathComponent($0) } ?? "")
        let result: Profile = try await request(id == nil ? "POST" : "PATCH", path, body: body, timeout: 30)
        return result.profile
    }
    func saveMemory(profile: String, memory: String?, title: String, content: String) async throws -> AgentProfile {
        let path = "/v1/agent/profiles/\(Self.pathComponent(profile))/memories" + (memory.map { "/" + Self.pathComponent($0) } ?? "")
        let result: Profile = try await request(memory == nil ? "POST" : "PATCH", path,
            body: ["title": .string(title), "content": .string(content)], timeout: 30)
        return result.profile
    }
    func deleteMemory(profile: String, memory: String) async throws -> AgentProfile {
        let result: Profile = try await request("DELETE", "/v1/agent/profiles/\(Self.pathComponent(profile))/memories/\(Self.pathComponent(memory))", timeout: 30)
        return result.profile
    }
    func agentRoutines() async throws -> Routines { try await request("GET", "/v1/agent/routines", timeout: 30) }
    func saveRoutine(_ id: String?, body: [String: JSONValue]) async throws -> AgentRoutine {
        let path = "/v1/agent/routines" + (id.map { "/" + Self.pathComponent($0) } ?? "")
        let result: Routine = try await request(id == nil ? "POST" : "PATCH", path, body: body, timeout: 30)
        return result.routine
    }
    func deleteRoutine(_ id: String) async throws {
        let _: [String: Bool] = try await request("DELETE", "/v1/agent/routines/\(Self.pathComponent(id))", timeout: 30)
    }
    func runRoutine(_ id: String) async throws -> AgentRoutineRun {
        let result: Run = try await request("POST", "/v1/agent/routines/\(Self.pathComponent(id))/run", timeout: 30)
        return result.run
    }
    func routineHistory(_ id: String? = nil) async throws -> [AgentRoutineRun] {
        let path = "/v1/agent/routines" + (id.map { "/" + Self.pathComponent($0) } ?? "") + "/history"
        let result: Runs = try await request("GET", path, timeout: 30)
        return result.runs
    }
    func startProfileTask(_ profileId: String, prompt: String, attachments: [AgentAttachment]) async throws -> String {
        struct Started: Decodable { var id: String }
        var body: [String: JSONValue] = ["profileId": .string(profileId), "prompt": .string(prompt)]
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map(\.json)) }
        let result: Started = try await request("POST", "/v1/agent/tasks", body: body, timeout: 120)
        return result.id
    }
}

extension AgentSchedule {
    func requestValue() throws -> JSONValue {
        let data = try JSONEncoder().encode(normalized())
        func value(_ raw: Any) throws -> JSONValue {
            if let s = raw as? String { return .string(s) }
            if let a = raw as? [Any] { return .array(try a.map(value)) }
            if let o = raw as? [String: Any] { return .object(try o.mapValues(value)) }
            if let n = raw as? NSNumber { return .int(n.intValue) }
            throw CocoaError(.coderInvalidValue)
        }
        return try value(JSONSerialization.jsonObject(with: data))
    }
}

#endif
