import Foundation

/// The routing fields of a Caboose APNs alert; system APS fields are ignored.
public struct PushPayload: Decodable, Equatable, Sendable {
    public let taskId: String?
    public let approvalId: String?
    public let windowId: Int?
    /// A Linux notification's record ID, which `POST /v1/notifications/:id/respond` answers.
    public let notificationId: String?
    /// The desktop file ID (without `.desktop`) of the application that sent it.
    public let desktopEntry: String?
    /// Whether opening it invokes the application's `default` action.
    public let defaultAction: Bool?
    public init(taskId: String? = nil, approvalId: String? = nil, windowId: Int? = nil,
                notificationId: String? = nil, desktopEntry: String? = nil, defaultAction: Bool? = nil) {
        self.taskId = taskId; self.approvalId = approvalId; self.windowId = windowId
        self.notificationId = notificationId; self.desktopEntry = desktopEntry; self.defaultAction = defaultAction
    }
}
