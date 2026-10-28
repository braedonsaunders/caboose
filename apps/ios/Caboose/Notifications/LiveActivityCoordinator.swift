import ActivityKit
import Foundation
import UIKit

@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()
    private var watching = Set<String>()
    private var started = false
    private var startToken: String?
    private var generation = 0
    private var registrations = 0
    private var host: HostClient? { AppModel.shared.host }
    private var environment: String { Bundle.main.object(forInfoDictionaryKey: "CabooseAPNsEnvironment") as? String ?? "sandbox" }
    private var deviceID: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "activity.deviceID") { return saved }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(value, forKey: "activity.deviceID")
        return value
    }
    private func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    func configure() {
        guard !started else { return }
        started = true
        Task {
            for await token in Activity<JobAttributes>.pushToStartTokenUpdates {
                self.startToken = self.hex(token)
                await self.registerStartToken()
            }
        }
        Task {
            for await activity in Activity<JobAttributes>.activityUpdates { self.watch(activity) }
        }
        for activity in Activity<JobAttributes>.activities { watch(activity) }
        if let token = Activity<JobAttributes>.pushToStartToken { startToken = hex(token) }
    }
    func connected() {
        configure()
        Task { await registerStartToken() }
        for activity in Activity<JobAttributes>.activities { watch(activity); Task { await register(activity) } }
    }
    private func resolvedHost() async -> HostClient? {
        guard let credentials = Credentials.load() else { return nil }
        let url = await credentials.reachableURL()
        return HostClient(baseURL: url, token: credentials.token)
    }
    private func registerStartToken() async {
        let currentGeneration = generation
        guard let token = startToken, ActivityAuthorizationInfo().areActivitiesEnabled, let host = await resolvedHost(), currentGeneration == generation else { return }
        registrations += 1
        defer { registrations -= 1 }
        let _: [String: Bool]? = try? await host.request("POST", "/v1/activities/start-token", body: ["token": .string(token), "environment": .string(environment), "deviceId": .string(deviceID)], timeout: 20)
    }
    private func register(_ activity: Activity<JobAttributes>) async {
        let currentGeneration = generation
        guard let token = activity.pushToken, let host = await resolvedHost(), currentGeneration == generation else { return }
        registrations += 1
        defer { registrations -= 1 }
        let _: [String: Bool]? = try? await host.request("POST", "/v1/activities", body: ["token": .string(hex(token)), "environment": .string(environment), "jobId": .string(activity.attributes.jobID), "activityId": .string(activity.id)], timeout: 20)
    }
    private func watch(_ activity: Activity<JobAttributes>) {
        guard watching.insert(activity.id).inserted else { return }
        Task {
            await register(activity)
            for await _ in activity.pushTokenUpdates { await self.register(activity) }
            self.watching.remove(activity.id)
        }
    }
    func sync(_ tasks: [AgentCenter.Task]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, AppModel.shared.computerStatus?.capabilities.push == true else { return }
        for task in tasks {
            let current = Activity<JobAttributes>.activities.filter { $0.attributes.jobID == task.id }
            let state = JobAttributes.ContentState(status: task.status, detail: String((task.summary ?? task.prompt).prefix(500)))
            if task.isRunning && current.isEmpty {
                do {
                    let attributes = JobAttributes(jobID: task.id, kind: "agent", title: task.agentName ?? task.agent)
                    let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
                    watch(activity)
                } catch { PushCoordinator.shared.error = error.localizedDescription }
            } else {
                for activity in current {
                    Task {
                        if task.isRunning { await activity.update(ActivityContent(state: state, staleDate: nil)) }
                        else { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(3600))) }
                    }
                }
            }
        }
    }
    func unregister(from host: HostClient?) {
        guard let host else { return }
        generation += 1
        let device = deviceID
        let activities = Activity<JobAttributes>.activities
        Task {
            while registrations > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            let _: [String: Bool]? = try? await host.request("DELETE", "/v1/activities/start-token", body: ["deviceId": .string(device)], timeout: 20)
            for activity in activities {
                let _: [String: Bool]? = try? await host.request("DELETE", "/v1/activities", body: ["activityId": .string(activity.id)], timeout: 20)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
