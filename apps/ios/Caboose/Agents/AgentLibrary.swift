import CabooseKit
import Foundation
import Observation

@MainActor @Observable
final class AgentLibrary {
    var profiles: [AgentProfile] = []
    var routines: [AgentRoutine] = []
    var runs: [AgentRoutineRun] = []
    var loadingProfiles = false
    var loadingRoutines = false
    var profilesUnavailable = false
    var routinesUnavailable = false
    var profileError: String?
    var routineError: String?
    var historyError: String?
    var loadingHistory = false
    var selectedProfileId: String?
    private var host: HostClient?
    private var generation = UUID()

    var selectedProfile: AgentProfile? { profiles.first { $0.id == selectedProfileId && !$0.archived } }
    var activeProfiles: [AgentProfile] { profiles.filter { !$0.archived } }
    func attach(_ host: HostClient) { self.host = host; Task { await refreshProfiles(); await refreshRoutines() } }
    func reset() {
        generation = UUID(); host = nil; profiles = []; routines = []; runs = []; selectedProfileId = nil
        profileError = nil; routineError = nil; historyError = nil
        profilesUnavailable = false; routinesUnavailable = false
        loadingProfiles = false; loadingRoutines = false; loadingHistory = false
    }
    func client() throws -> HostClient {
        guard let host else { throw HostClient.Failure.unreachable("Connect to your computer first.") }
        return host
    }
    func refreshProfiles() async {
        guard let host, !loadingProfiles else { return }
        let generation = generation
        loadingProfiles = true
        defer { if generation == self.generation { loadingProfiles = false } }
        do {
            let result = try await host.agentProfiles()
            guard generation == self.generation else { return }
            profiles = result; profilesUnavailable = false; profileError = nil
        } catch {
            guard generation == self.generation else { return }
            if case HostClient.Failure.server(404, _) = error { profilesUnavailable = true }
            else { profileError = error.localizedDescription }
        }
    }
    func refreshRoutines() async {
        guard let host, !loadingRoutines else { return }
        let generation = generation
        loadingRoutines = true
        defer { if generation == self.generation { loadingRoutines = false } }
        do {
            let result = try await host.agentRoutines()
            guard generation == self.generation else { return }
            routines = result.routines; routineError = result.error; routinesUnavailable = false
        } catch {
            guard generation == self.generation else { return }
            if case HostClient.Failure.server(404, _) = error { routinesUnavailable = true }
            else { routineError = error.localizedDescription }
        }
    }
    func refreshHistory() async {
        guard let host, !loadingHistory else { return }
        let generation = generation
        loadingHistory = true
        defer { if generation == self.generation { loadingHistory = false } }
        do {
            let result = try await host.routineHistory()
            guard generation == self.generation else { return }
            runs = result; historyError = nil
        } catch { if generation == self.generation { historyError = error.localizedDescription } }
    }
    func put(_ profile: AgentProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
    }
    func put(_ routine: AgentRoutine) {
        if let i = routines.firstIndex(where: { $0.id == routine.id }) { routines[i] = routine } else { routines.append(routine) }
    }
    func saveProfile(_ id: String?, body: [String: JSONValue]) async throws { put(try await client().saveProfile(id, body: body)); await refreshRoutines() }
    func saveMemory(profile: String, memory: String?, title: String, content: String) async throws {
        put(try await client().saveMemory(profile: profile, memory: memory, title: title, content: content))
    }
    func deleteMemory(profile: String, memory: String) async throws { put(try await client().deleteMemory(profile: profile, memory: memory)) }
    func saveRoutine(_ id: String?, body: [String: JSONValue]) async throws { put(try await client().saveRoutine(id, body: body)) }
    func deleteRoutine(_ id: String) async throws { try await client().deleteRoutine(id); routines.removeAll { $0.id == id } }
    func run(_ id: String) async throws { _ = try await client().runRoutine(id); await refreshHistory() }
}
