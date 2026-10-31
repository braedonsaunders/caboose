import Foundation

/// The routing fields of a Caboose APNs alert; system APS fields are ignored.
public struct PushPayload: Decodable, Equatable, Sendable {
    public let taskId: String?
    public let approvalId: String?
    public let windowId: Int?
    /// A finished command, independent of desktop notification routing.
    public let commandId: String?
    public let notificationId: String?
    public let desktopEntry: String?
    public let defaultAction: Bool?
    public init(taskId: String? = nil, approvalId: String? = nil, windowId: Int? = nil,
                commandId: String? = nil, notificationId: String? = nil,
                desktopEntry: String? = nil, defaultAction: Bool? = nil) {
        self.taskId = taskId; self.approvalId = approvalId; self.windowId = windowId
        self.commandId = commandId; self.notificationId = notificationId
        self.desktopEntry = desktopEntry; self.defaultAction = defaultAction
    }
}
