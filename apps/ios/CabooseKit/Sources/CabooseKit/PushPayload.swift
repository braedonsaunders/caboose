import Foundation

/// The routing fields of a Caboose APNs alert; system APS fields are ignored.
public struct PushPayload: Decodable, Equatable, Sendable {
    public let taskId: String?
    public let approvalId: String?
    public let windowId: Int?
    /// A finished command (docs/architecture.md, Push notifications).
    public let commandId: String?
    public init(taskId: String? = nil, approvalId: String? = nil, windowId: Int? = nil, commandId: String? = nil) {
        self.taskId = taskId; self.approvalId = approvalId; self.windowId = windowId; self.commandId = commandId
    }
}
