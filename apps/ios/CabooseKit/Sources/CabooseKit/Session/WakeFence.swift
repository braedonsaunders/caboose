import Foundation

/// One wake at a time, and only for the computer the app is paired with now.
///
/// A caller for the same computer while a wake runs waits for it. Pairing with another
/// computer, signing out, closing the display or leaving the foreground invalidates the
/// running wake: its ticket stops being current, so whatever it learns afterwards (a
/// reachable address, a session, a failure) is dropped instead of applied to the new state.
/// Cancelling its task is not enough on its own, because work already past its last
/// cancellation check still finishes.
@MainActor
public final class WakeFence {
    /// Handed to a wake; check `isCurrent(_:)` after every suspension before changing state.
    public struct Ticket: Equatable, Sendable {
        public let generation: Int
        public let identity: String
    }

    private var generation = 0
    private var running: (ticket: Ticket, task: Task<Void, Never>)?

    public init() {}

    /// Whether `ticket`'s wake may still change anything.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && running?.ticket == ticket
    }

    /// The running wake, if any, no longer counts.
    public func invalidate() {
        generation += 1
        running?.task.cancel()
        running = nil
    }

    /// Runs `body` as the wake for `identity` (the paired computer), or waits for the one
    /// already running for it. A running wake for another identity is invalidated first.
    public func run(identity: String, _ body: @escaping @MainActor (Ticket) async -> Void) async {
        if let running {
            if running.ticket.identity == identity { return await running.task.value }
            invalidate()
        }
        let ticket = Ticket(generation: generation, identity: identity)
        let task = Task { @MainActor in await body(ticket) }
        running = (ticket, task)
        await task.value
        // Only this wake's own entry: a newer one may have started meanwhile.
        if running?.ticket == ticket { running = nil }
    }
}

/// What a wake does about the display that is already there, which may belong to the
/// computer the app was paired with before.
public enum WakePlan: Equatable, Sendable {
    /// This computer's display is up: nothing to do.
    case alreadyLive
    /// This computer's display is opening: it finishes or fails on its own.
    case alreadyOpening
    /// Wake the computer, then resume this computer's lost display or open a new one.
    case wake

    /// `owner` is the identity the current session was opened for, nil without one.
    public static func plan(for identity: String, owner: String?, state: DisplaySessionState?, phaseReady: Bool) -> WakePlan {
        guard let state, owner == identity else { return .wake }
        switch state {
        case .ready: return phaseReady ? .alreadyLive : .wake
        case .connecting, .authenticating: return .alreadyOpening
        case .idle, .closed: return .wake
        }
    }
}
