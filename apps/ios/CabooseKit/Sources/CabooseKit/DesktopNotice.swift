import CryptoKit
import Foundation

/// A Linux desktop notification as the host's `notification` control event carries it
/// (docs/architecture.md § Desktop notifications): its text, the application's action
/// buttons, whether it accepts an inline reply, and the desktop entry it came from.
public struct DesktopNotice: Decodable, Equatable, Sendable {
    public struct Action: Codable, Hashable, Sendable {
        public let key: String
        public let label: String
        public init(key: String, label: String) { self.key = key; self.label = label }
    }
    public struct Reply: Codable, Hashable, Sendable {
        public let label: String
        public let placeholder: String
        public init(label: String, placeholder: String) { self.label = label; self.placeholder = placeholder }
    }

    /// The record's ID, which `POST /v1/notifications/:id/respond` answers.
    public let id: String
    public let app: String
    public let summary: String
    public let body: String
    /// A desktop file ID without `.desktop`.
    public let desktopEntry: String?
    public let actions: [Action]
    /// Whether the application acts on the notification being opened (its `default` action).
    public let defaultAction: Bool
    public let reply: Reply?

    public init(id: String, app: String, summary: String, body: String, desktopEntry: String? = nil,
                actions: [Action] = [], defaultAction: Bool = false, reply: Reply? = nil) {
        self.id = id; self.app = app; self.summary = summary; self.body = body
        self.desktopEntry = desktopEntry; self.actions = actions; self.defaultAction = defaultAction; self.reply = reply
    }

    private enum CodingKeys: String, CodingKey { case id, app, summary, body, desktopEntry, actions, defaultAction, reply }

    /// Hosts and guests that predate actions send none of the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard UUID(uuidString: id) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "A notification ID is a UUID")
        }
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        desktopEntry = try container.decodeIfPresent(String.self, forKey: .desktopEntry).flatMap { $0.isEmpty ? nil : $0 }
        let offered = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        actions = Array(offered.filter { !$0.key.isEmpty && !$0.label.isEmpty }.prefix(DesktopNotificationCategory.buttons))
        defaultAction = try container.decodeIfPresent(Bool.self, forKey: .defaultAction) ?? false
        reply = try container.decodeIfPresent(Reply.self, forKey: .reply)
    }

    /// The control event's JSON object.
    public init(event: Data) throws { self = try JSONDecoder().decode(Self.self, from: event) }

    /// Its summary, else its application's name.
    public var title: String { summary.isEmpty ? (app.isEmpty ? "Caboose" : app) : summary }

    /// The category with its actions and reply; nil when it has neither.
    public var category: DesktopNotificationCategory? {
        actions.isEmpty && reply == nil ? nil : DesktopNotificationCategory(actions: actions, reply: reply)
    }

    /// The routing keys a local notification carries: the same as a `desktop` push's.
    public var userInfo: [String: Any] {
        var info: [String: Any] = ["notificationId": id]
        if let desktopEntry { info["desktopEntry"] = desktopEntry }
        if defaultAction { info["defaultAction"] = true }
        return info
    }
}

/// The buttons of the notifications that share one set of actions and reply. Categories
/// must be registered before a notification that uses them is shown, so the app registers
/// one for each set it posts; a push uses the fixed `DESKTOP_REPLY`.
public struct DesktopNotificationCategory: Codable, Hashable, Sendable {
    /// What a push offers when its application accepts a reply.
    public static let replyCategory = "DESKTOP_REPLY"
    /// The text input action's identifier, in this category and `DESKTOP_REPLY`.
    public static let replyAction = "REPLY"
    /// Prefix of a button's identifier, followed by its action key.
    public static let actionPrefix = "ACTION:"
    /// Buttons a Linux notification carries (the host's bound).
    public static let buttons = 4

    public let actions: [DesktopNotice.Action]
    public let reply: DesktopNotice.Reply?

    public init(actions: [DesktopNotice.Action], reply: DesktopNotice.Reply?) {
        self.actions = actions; self.reply = reply
    }

    /// Derived from the content, so the same set always has the same identifier, across launches.
    public var identifier: String {
        var text = ""
        for action in actions { text += action.key + "\u{1F}" + action.label + "\u{1E}" }
        if let reply { text += "\u{1D}" + reply.label + "\u{1F}" + reply.placeholder }
        return "DESKTOP." + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The button title of the text input action: the application's label, else Reply.
    public var replyTitle: String { reply.map { $0.label.isEmpty ? "Reply" : $0.label } ?? "Reply" }
}

/// The action sets registered for notifications the app posted, least recently used first.
/// Kept with the app's settings so delivered notifications keep their buttons across launches.
public struct DesktopNotificationCategories: Codable, Equatable, Sendable {
    public static let limit = 32
    public private(set) var recent: [DesktopNotificationCategory] = []

    public init() {}

    /// Makes `category` the most recent; true when it is new and so must be registered now.
    @discardableResult
    public mutating func use(_ category: DesktopNotificationCategory, limit: Int = DesktopNotificationCategories.limit) -> Bool {
        if let index = recent.firstIndex(of: category) {
            recent.append(recent.remove(at: index))
            return false
        }
        recent.append(category)
        if recent.count > limit { recent.removeFirst(recent.count - limit) }
        return true
    }
}

/// What the person did with a Linux notification.
public enum DesktopNotificationAnswer: Equatable, Sendable {
    /// Opened it: show its application, and invoke `default` when it offered that.
    case open
    case action(String)
    case reply(String)

    /// From a response's action identifier (`openIdentifier` being the system's default
    /// action) and typed text; nil for a dismissal, an empty reply or another category's action.
    public init?(actionIdentifier: String, userText: String?, openIdentifier: String) {
        if actionIdentifier == openIdentifier {
            self = .open
        } else if actionIdentifier == DesktopNotificationCategory.replyAction {
            guard let text = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            self = .reply(text)
        } else if actionIdentifier.hasPrefix(DesktopNotificationCategory.actionPrefix) {
            let key = String(actionIdentifier.dropFirst(DesktopNotificationCategory.actionPrefix.count))
            guard !key.isEmpty else { return nil }
            self = .action(key)
        } else {
            return nil
        }
    }

    /// The body of `POST /v1/notifications/:id/respond`; opening answers `default`.
    public var request: (field: String, value: String) {
        switch self {
        case .open: ("action", "default")
        case .action(let key): ("action", key)
        case .reply(let text): ("reply", text)
        }
    }
}

/// Linux notifications name their application's desktop entry, not a window.
public enum DesktopEntryMatch {
    /// The installed app whose desktop ID is `entry`, with or without `.desktop`, ignoring case.
    public static func appID(for entry: String, among ids: [String]) -> String? {
        let wanted = normalized(entry)
        guard !wanted.isEmpty else { return nil }
        return ids.first { normalized($0) == wanted }
    }

    private static func normalized(_ id: String) -> String {
        let lowered = id.lowercased()
        return lowered.hasSuffix(".desktop") ? String(lowered.dropLast(8)) : lowered
    }
}
