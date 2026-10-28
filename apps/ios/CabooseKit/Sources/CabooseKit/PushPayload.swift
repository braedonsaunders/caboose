import Foundation

/// The routing fields of a Caboose APNs alert; system APS fields are ignored.
public struct PushPayload: Decodable, Equatable, Sendable {
    public let taskId: String?
    public let approvalId: String?
    public let windowId: Int?
    public init(taskId: String? = nil, approvalId: String? = nil, windowId: Int? = nil) {
        self.taskId = taskId; self.approvalId = approvalId; self.windowId = windowId
    }
}
