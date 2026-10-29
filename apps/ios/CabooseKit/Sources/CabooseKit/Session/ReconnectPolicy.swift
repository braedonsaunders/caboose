import Foundation

/// When the app opens the display again after losing it, and when it stops trying.
///
/// A series is at most `delays.count` attempts, about a minute in all. It starts again
/// only when the display has stayed connected for `stableAfter` seconds, when the network
/// path changes, or when the person asks; a display that connects and drops at once keeps
/// counting, so a flapping link cannot retry forever.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Why the display is not connected.
    public enum Cause: Equatable, Sendable {
        /// The socket closed or failed.
        case dropped
        /// Nothing arrived from the computer for too long (`LinkWatchdog`).
        case stalled
        /// The host could not be reached, or would not wake the computer.
        case wakeFailed
        /// The display refused this session's token. The next wake fetches a fresh one, so
        /// it is retried once; a second refusal stops the series.
        case refused
        /// The computer's display speaks another protocol version or could not understand
        /// this client. Retrying cannot help.
        case incompatible
    }

    /// Seconds before each attempt of a series.
    public static let delays: [Double] = [0.5, 1, 2, 4, 8, 15, 15, 15]
    /// Seconds connected after which a later drop starts a new series.
    public static let stableAfter: Double = 10

    /// Attempts made in this series.
    public private(set) var attempts = 0
    private var refusals = 0
    private var connectedAt: Double?

    public init() {}

    public static var maxAttempts: Int { delays.count }

    /// The display is connected and showing the computer.
    public mutating func connected(at now: Double) {
        connectedAt = now
    }

    /// The delay before the next attempt, or nil when the series is over.
    public mutating func next(after cause: Cause, at now: Double) -> Double? {
        if let connectedAt, now - connectedAt >= Self.stableAfter { restart() }
        connectedAt = nil
        switch cause {
        case .incompatible:
            return nil
        case .refused:
            refusals += 1
            if refusals > 1 { return nil }
        case .dropped, .stalled, .wakeFailed:
            break
        }
        guard attempts < Self.delays.count else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }

    /// A new network path, or the person asking: a fresh series.
    public mutating func restart() {
        attempts = 0
        refusals = 0
    }
}

/// Decides that a display connection is dead when the socket has not said so.
///
/// A socket on a network the phone has left (Wi-Fi given up for cellular, a tunnel torn
/// down) can stay open for minutes without delivering anything. The client pings every
/// `pingInterval` seconds while connected and the server answers each one, so silence is
/// evidence. All times are seconds on one monotonic clock.
public struct LinkWatchdog: Equatable, Sendable {
    public static let pingInterval: Double = 5
    /// Silence on a connected display before it is given up.
    public static let silenceLimit: Double = 15
    /// From opening the socket to the server's hello.
    public static let openLimit: Double = 15
    /// After a probe (the network path changed), how long the old connection has to answer.
    public static let probeLimit: Double = 5

    public enum Verdict: Equatable, Sendable {
        case live
        case stalled(String)
    }

    private let openedAt: Double
    private var readyAt: Double?
    private var probedAt: Double?

    public init(openedAt: Double) {
        self.openedAt = openedAt
    }

    /// The server's hello arrived.
    public mutating func ready(at now: Double) {
        readyAt = now
    }

    /// Asks for an answer soon: something arriving after `now` proves the connection.
    public mutating func probe(at now: Double) {
        if probedAt == nil { probedAt = now }
    }

    /// `lastReceive` is when any byte last arrived, nil if none has.
    public mutating func verdict(at now: Double, lastReceive: Double?) -> Verdict {
        guard let readyAt else {
            return now - openedAt > Self.openLimit ? .stalled("The computer's display did not answer.") : .live
        }
        let heard = max(lastReceive ?? readyAt, readyAt)
        if let probedAt {
            if heard >= probedAt { self.probedAt = nil }
            else if now - probedAt > Self.probeLimit { return .stalled("The network changed and the connection stopped answering.") }
        }
        if now - heard > Self.silenceLimit {
            return .stalled("Nothing arrived from the computer for \(Int(Self.silenceLimit)) seconds.")
        }
        return .live
    }
}

/// Why a display connection closed.
public enum DisplayCloseCause: Equatable, Sendable {
    /// The app closed it (`disconnect()`).
    case local
    /// The socket closed or failed, with the transport's description when it gave one.
    case transport(String?)
    /// The watchdog heard nothing for too long.
    case stalled(String)
    /// The server said goodbye with this reason (`auth`, `version`, `shutdown`, `protocol`,
    /// `replaced`, or one this client does not know).
    case bye(String)
    /// The server's hello is for another protocol version.
    case incompatible

    /// What a reconnect attempt is up against, or nil when the app should not try on its
    /// own: it closed the display itself, or another device took it over.
    public var reconnect: ReconnectPolicy.Cause? {
        switch self {
        case .local, .bye("replaced"): nil
        case .transport: .dropped
        case .stalled: .stalled
        case .bye("auth"): .refused
        case .bye("version"), .bye("protocol"), .incompatible: .incompatible
        case .bye: .dropped
        }
    }

    /// Whether the windows stay on screen for a resume. A lost connection, silence or a
    /// refused token (the computer may have resumed from parking with a new one) keep
    /// them; the next hello's epoch decides whether they are still valid.
    var keepsWindows: Bool {
        switch self {
        case .transport, .stalled, .bye("auth"): true
        case .local, .bye, .incompatible: false
        }
    }
}
