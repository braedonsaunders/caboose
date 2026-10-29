import Foundation

/// An HTTP launch acknowledgement is not evidence that an application opened a window.
public struct DockLaunchState: Sendable {
    public struct Attempt: Equatable, Sendable {
        public let token: UUID
        public let started: Date
        public fileprivate(set) var acknowledged = false
    }
    public private(set) var pending: [String: Attempt] = [:]
    public init() {}
    public mutating func begin(_ appID: String, now: Date = Date()) -> UUID? {
        guard pending[appID] == nil else { return nil }
        let token = UUID()
        pending[appID] = Attempt(token: token, started: now)
        return token
    }
    /// Only a still-pending request may start the window deadline. A window or reset
    /// can settle it while HTTP is still awaiting its response.
    public mutating func acknowledge(_ appID: String, token: UUID) -> Bool {
        guard pending[appID]?.token == token, pending[appID]?.acknowledged == false else { return false }
        pending[appID]?.acknowledged = true
        return true
    }
    @discardableResult public mutating func finish(_ appID: String, token: UUID) -> Bool {
        guard pending[appID]?.token == token else { return false }
        pending[appID] = nil
        return true
    }
    public mutating func reset() { pending.removeAll() }
}
