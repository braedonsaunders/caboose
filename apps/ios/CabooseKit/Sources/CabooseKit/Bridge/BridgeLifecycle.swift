import Foundation

/// Which of the computer's file requests the phone may show and answer, and which callbacks
/// are still allowed to act: the policy behind the app's `NativeBridge`, without UIKit.
///
/// Every request is shown under a ticket: the request and the generation it was received
/// in. Resetting (signing out, switching computers), losing the control connection or going
/// to the background starts a new generation, so a picker callback, upload or dismissal
/// from before cannot act on what follows. The computer has already sent those requests to
/// its own dialogs (docs/native-bridge.md § File chooser), so nothing is answered for them.
public struct BridgeLifecycle: Sendable {
    public struct Ticket: Hashable, Sendable {
        public let generation: Int
        public let request: String
    }

    public enum Admission: Equatable, Sendable {
        /// Waiting to be shown.
        case queued
        /// Already shown or waiting; nothing to do.
        case duplicate
        /// Not shown: answer it with the computer's own dialog.
        case declined
    }

    public static let queueLimit = 8

    public private(set) var generation = 0
    public private(set) var current: Ticket?
    public private(set) var queue: [String] = []
    public private(set) var active = false
    public private(set) var connected = false

    public init() {}

    /// A request arrived on the control connection. `dialogs` is the owner's choice to use the phone's.
    public mutating func receive(_ id: String, dialogs: Bool) -> Admission {
        if current?.request == id || queue.contains(id) { return .duplicate }
        guard dialogs, connected, queue.count < Self.queueLimit else { return .declined }
        queue.append(id)
        return .queued
    }

    /// The next request to show, when the app can show one.
    public mutating func next() -> Ticket? {
        guard active, connected, current == nil, !queue.isEmpty else { return nil }
        let ticket = Ticket(generation: generation, request: queue.removeFirst())
        current = ticket
        return ticket
    }

    /// Whether a callback for `ticket` may still act: it is the request shown, in this generation.
    public func isCurrent(_ ticket: Ticket) -> Bool { current == ticket }

    /// The shown request was answered; true when `ticket` was the one shown (its answer may go).
    public mutating func finish(_ ticket: Ticket) -> Bool {
        guard current == ticket else { return false }
        current = nil
        return true
    }

    /// The computer withdrew a request: dropped if waiting; the ticket to dismiss if shown.
    public mutating func withdraw(_ id: String) -> Ticket? {
        queue.removeAll { $0 == id }
        guard let shown = current, shown.request == id else { return nil }
        current = nil
        return shown
    }

    /// A control connection is up (its first event arrived).
    public mutating func connect() { connected = true }

    /// The control connection closed or the computer stopped: everything waiting or shown is
    /// the computer's again. Returns the ticket to dismiss.
    public mutating func disconnect() -> Ticket? {
        connected = false
        return invalidate()
    }

    /// In the foreground (or not). Going to the background closes the control connection, so
    /// what was shown or waiting goes to the computer; returns the ticket to dismiss.
    public mutating func setActive(_ active: Bool) -> Ticket? {
        self.active = active
        return active ? nil : invalidate()
    }

    /// Signed out or switched computers. Returns the ticket to dismiss.
    public mutating func reset() -> Ticket? {
        connected = false
        return invalidate()
    }

    private mutating func invalidate() -> Ticket? {
        generation &+= 1
        queue.removeAll()
        defer { current = nil }
        return current
    }
}

/// Which computers the owner shares the phone's location with: consent is per computer, so
/// pairing or switching to another never inherits it.
public struct LocationConsent: Equatable, Sendable {
    public private(set) var computers: Set<String>

    public init(_ computers: [String] = []) { self.computers = Set(computers) }

    public func allows(_ computer: String?) -> Bool { computer.map(computers.contains) ?? false }

    public mutating func set(_ shared: Bool, for computer: String) {
        if shared { computers.insert(computer) } else { computers.remove(computer) }
    }

    public var stored: [String] { computers.sorted() }
}
