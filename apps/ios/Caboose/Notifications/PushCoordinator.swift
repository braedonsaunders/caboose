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
    /// The action sets of Linux notifications this app posted, registered as categories.
    private var desktopCategories: DesktopNotificationCategories
    private var token: String? { defaults.string(forKey: "push.token") }
    private var host: HostClient? { AppModel.shared.host }
    private var environment: String { Bundle.main.object(forInfoDictionaryKey: "CabooseAPNsEnvironment") as? String ?? "sandbox" }

    private override init() {
        approvals = UserDefaults.standard.bool(forKey: "push.approvals")
        tasks = UserDefaults.standard.bool(forKey: "push.tasks")
        desktop = UserDefaults.standard.bool(forKey: "push.desktop")
        desktopCategories = UserDefaults.standard.data(forKey: "push.desktopCategories")
            .flatMap { try? JSONDecoder().decode(DesktopNotificationCategories.self, from: $0) } ?? DesktopNotificationCategories()
        super.init()
    }
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(categories())
        if approvals || tasks || desktop { UIApplication.shared.registerForRemoteNotifications() }
    }
    /// Approvals, a desktop push's reply, and the recent Linux action sets. iOS shows a
    /// notification's buttons only from a category registered before it arrives.
    private func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow")
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: .destructive)
        var categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: "AGENT_APPROVAL", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: DesktopNotificationCategory.replyCategory,
                                   actions: [Self.replyAction(title: "Reply", placeholder: "")], intentIdentifiers: []),
        ]
        for category in desktopCategories.recent {
            var actions: [UNNotificationAction] = category.reply.map { [Self.replyAction(title: category.replyTitle, placeholder: $0.placeholder)] } ?? []
            actions += category.actions.map { UNNotificationAction(identifier: DesktopNotificationCategory.actionPrefix + $0.key, title: $0.label) }
            categories.insert(UNNotificationCategory(identifier: category.identifier, actions: actions, intentIdentifiers: []))
        }
        return categories
    }

    private static func replyAction(title: String, placeholder: String) -> UNTextInputNotificationAction {
        UNTextInputNotificationAction(identifier: DesktopNotificationCategory.replyAction, title: title, options: [],
                                      textInputButtonTitle: "Send", textInputPlaceholder: placeholder)
    }

    /// Shows a Linux notification while the app runs, with the application's buttons and reply.
    func postDesktop(_ notice: DesktopNotice) async {
        AppModel.requestNotificationPermission()
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.userInfo = notice.userInfo
        if let category = notice.category {
            if desktopCategories.use(category) {
                center.setNotificationCategories(categories())
                // Registration is asynchronous; reading the categories back waits for it.
                _ = await center.notificationCategories()
            }
            defaults.set(try? JSONEncoder().encode(desktopCategories), forKey: "push.desktopCategories")
            content.categoryIdentifier = category.identifier
        }
        try? await center.add(UNNotificationRequest(identifier: "linux.\(notice.id)", content: content, trigger: nil))
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
        let content = response.notification.request.content
        let info = content.userInfo
        guard JSONSerialization.isValidJSONObject(info), let data = try? JSONSerialization.data(withJSONObject: info), let payload = try? JSONDecoder().decode(PushPayload.self, from: data) else { return }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await handle(payload, action: response.actionIdentifier, text: text, title: content.title)
    }
    private func handle(_ payload: PushPayload, action: String, text: String?, title: String) async {
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
        } else if let window = payload.windowId {
            AppModel.shared.show(windowID: window)
        } else if let notification = payload.notificationId,
                  let answer = DesktopNotificationAnswer(actionIdentifier: action, userText: text, openIdentifier: UNNotificationDefaultActionIdentifier) {
            await answerDesktop(notification, answer, payload: payload, title: title)
        }
    }

    /// Opening shows the application's window and invokes its `default` action; a button or
    /// a reply reaches the application in the background, and a failure says so.
    private func answerDesktop(_ id: String, _ answer: DesktopNotificationAnswer, payload: PushPayload, title: String) async {
        if answer == .open {
            if payload.defaultAction == true { Task { try? await Self.respond(id, answer) } }
            if let entry = payload.desktopEntry { await AppModel.shared.openDesktopEntry(entry) }
            return
        }
        do {
            try await Self.respond(id, answer)
        } catch {
            let notice = UNMutableNotificationContent()
            notice.title = title.isEmpty ? "Couldn't answer the notification" : "Couldn't answer \u{201C}\(title)\u{201D}"
            var body = error.localizedDescription
            if case .reply(let text) = answer { body += "\n\nYour reply: \(text)" }
            notice.body = body
            var info: [String: Any] = ["notificationId": id]
            if let entry = payload.desktopEntry { info["desktopEntry"] = entry }
            notice.userInfo = info
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "desktop-error.\(id)", content: notice, trigger: nil))
        }
    }

    /// `POST /v1/notifications/:id/respond`, which wakes a parked computer.
    private static func respond(_ id: String, _ answer: DesktopNotificationAnswer) async throws {
        guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
        guard let uuid = UUID(uuidString: id) else { throw HostClient.Failure.server(400, "This notification can't be answered.") }
        let url = await credentials.reachableURL()
        let request = answer.request
        let reply: [String: Bool] = try await HostClient(baseURL: url, token: credentials.token).request(
            "POST", "/v1/notifications/\(uuid.uuidString.lowercased())/respond", body: [request.field: .string(request.value)], timeout: 25)
        guard reply["responded"] == true else { throw HostClient.Failure.server(200, "The computer did not confirm the answer.") }
    }
}
