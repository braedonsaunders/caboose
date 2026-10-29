import Foundation

/// The network path the phone's traffic takes, as the system reports it: which kinds of
/// interface the path actually uses (not merely which are available), and its gateways.
/// The app fills it from `NWPath`; this type keeps the decisions testable without one.
public struct NetworkPath: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case wifi, cellular, wired, loopback
        /// Not one of the others: a VPN or tunnel interface (`utun`, a WireGuard tunnel).
        case other
    }

    public var satisfied: Bool
    /// The kinds of interface this path uses. Several at once (a tunnel over Wi-Fi,
    /// multipath) are all listed.
    public var uses: Set<Kind>
    /// The path's gateways, as text: they change when the phone joins another network on
    /// the same kind of interface.
    public var gateways: [String]
    public var expensive: Bool
    public var constrained: Bool

    public init(satisfied: Bool, uses: Set<Kind>, gateways: [String] = [], expensive: Bool = false, constrained: Bool = false) {
        self.satisfied = satisfied
        self.uses = uses
        self.gateways = gateways.sorted()
        self.expensive = expensive
        self.constrained = constrained
    }

    /// "Wi-Fi", "Cellular through a VPN", "Wi-Fi and Cellular": what the path uses, with no
    /// guess about which one carries a given connection.
    public var name: String {
        guard satisfied else { return "No network" }
        let physical: [Kind] = [.wifi, .cellular, .wired, .loopback].filter(uses.contains)
        let names = physical.map { kind -> String in
            switch kind {
            case .wifi: "Wi-Fi"
            case .cellular: "Cellular"
            case .wired: "Wired"
            case .loopback: "Loopback"
            case .other: "Other"
            }
        }
        let base = names.isEmpty ? (uses.contains(.other) ? "A VPN or tunnel" : "Unknown") : names.joined(separator: " and ")
        return !names.isEmpty && uses.contains(.other) ? base + " through a VPN or tunnel" : base
    }

    /// What a live display should do when the path changes from `previous` to `next`.
    public enum Response: Equatable, Sendable {
        /// Nothing the connection could notice.
        case none
        /// The route may have moved: the connection must prove it still answers.
        case probe
        /// The network came back or changed while not connected: try again now.
        case retry
    }

    public static func response(from previous: NetworkPath?, to next: NetworkPath, live: Bool) -> Response {
        guard next.satisfied, let previous, previous != next else { return .none }
        let moved = !previous.satisfied || previous.uses != next.uses || previous.gateways != next.gateways
        guard moved else { return .none }
        return live ? .probe : .retry
    }
}
