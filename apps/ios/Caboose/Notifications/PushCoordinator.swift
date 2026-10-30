import CabooseKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Settings are local to this device; the host stores a copy with its APNs token.
@MainActor @Observable
final class PushCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    private let defaults = UserDefaults.standard
    var approvals: Bool { didSet { defaults.set(approvals, forKey: "push.approvals"); synchronize() } }
    var tasks: Bool { didSet { defaults.set(tasks, forKey: "push.tasks"); synchronize() } }
    var desktop: Bool { didSet { defaults.set(desktop, forKey: "push.desktop"); synchronize() } }
    var error: String?
    private var synchronization: Task<Void, Never>?
    private var token: String? { defaults.string(forKey: "push.token") }
    private var host: HostClient? { AppModel.shared.host }
    private var environment: String { Bundle.main.object(forInfoDictionaryKey: "CabooseAPNsEnvironment") as? String ?? "sandbox" }

    private override init() {
        approvals = UserDefaults.standard.bool(forKey: "push.approvals")
        tasks = UserDefaults.standard.bool(forKey: "push.tasks")
        desktop = UserDefaults.standard.bool(forKey: "push.desktop")
        super.init()
    }
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow")
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: .destructive)
        center.setNotificationCategories([UNNotificationCategory(identifier: "AGENT_APPROVAL", actions: [allow, deny], intentIdentifiers: [])])
        if approvals || tasks || desktop { UIApplication.shared.registerForRemoteNotifications() }
    }
    func received(token data: Data) {
        defaults.set(data.map { String(format: "%02x", $0) }.joined(), forKey: "push.token")
        synchronize()
    }
    func enable() async {
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                error = "Enable notifications for Caboose in iOS Settings."
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            synchronize()
        } catch { self.error = error.localizedDescription }
    }
    func synchronize() {
        guard let host, let token else { return }
        let kinds = [("approval", approvals), ("task", tasks), ("desktop", desktop)].compactMap { $0.1 ? JSONValue.string($0.0) : nil }
        let previous = synchronization
        synchronization = Task {
            await previous?.value
            do {
                let _: [String: Bool] = try await host.request("POST", "/v1/devices/push", body: ["token": .string(token), "environment": .string(environment), "kinds": .array(kinds)], timeout: 20)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    func unregister(from host: HostClient?) {
        guard let host, let token else { return }
        let previous = synchronization
        synchronization = Task {
            await previous?.value
            let _: [String: Bool]? = try? await host.request("DELETE", "/v1/devices/push", body: ["token": .string(token)], timeout: 20)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard JSONSerialization.isValidJSONObject(info), let data = try? JSONSerialization.data(withJSONObject: info), let payload = try? JSONDecoder().decode(PushPayload.self, from: data) else { return }
        await handle(payload, action: response.actionIdentifier)
    }
    private func handle(_ payload: PushPayload, action: String) async {
        if let task = payload.taskId, let approval = payload.approvalId, action == "ALLOW" || action == "DENY" {
            do {
                guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
                let url = await credentials.reachableURL()
                try await HostClient(baseURL: url, token: credentials.token).decideAgentApproval(task, request: approval, allow: action == "ALLOW", option: nil)
            } catch {
                self.error = error.localizedDescription
                AppModel.shared.notificationTaskID = task
                let notice = UNMutableNotificationContent()
                notice.title = "Couldn't answer approval"
                notice.body = error.localizedDescription
                notice.userInfo = ["taskId": task]
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "approval-error.\(approval)", content: notice, trigger: nil))
            }
        } else if let task = payload.taskId {
            AppModel.shared.notificationTaskID = task
            AppModel.shared.presentedWindowID = nil
        } else if let command = payload.commandId {
            AppModel.shared.notificationCommandID = command
            AppModel.shared.presentedWindowID = nil
        } else if let window = payload.windowId {
            AppModel.shared.show(windowID: window)
        }
    }
}
