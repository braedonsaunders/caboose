import Foundation

/// What the Task Manager shows of a `RunningAppsListing`: the apps in an order, how much of
/// the computer they use, and which running apps a dock entry is.
public enum TaskManager {
    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case cpu, memory, name

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .name: "Name"
            }
        }
    }

    /// The apps the owner can end, in `order`. The session scope is apart (`session(in:)`).
    public static func apps(in listing: RunningAppsListing, sortedBy order: Sort) -> [RunningApp] {
        sorted(listing.apps.filter { !$0.isSession }, by: order)
    }

    /// Caboose's own processes and whatever no app claims: shown, never ended.
    public static func session(in listing: RunningAppsListing) -> RunningApp? {
        listing.apps.first { $0.isSession }
    }

    /// Busiest first for CPU and memory (ties by name), A to Z for name; the id breaks the rest.
    public static func sorted(_ apps: [RunningApp], by order: Sort) -> [RunningApp] {
        apps.sorted { a, b in
            switch order {
            case .cpu where a.cpuPercent != b.cpuPercent: return a.cpuPercent > b.cpuPercent
            case .memory where a.memoryBytes != b.memoryBytes: return a.memoryBytes > b.memoryBytes
            default:
                let names = a.name.localizedStandardCompare(b.name)
                return names == .orderedSame ? a.id < b.id : names == .orderedAscending
            }
        }
    }

    public static func sorted(_ processes: [RunningApp.Process], by order: Sort) -> [RunningApp.Process] {
        processes.sorted { a, b in
            switch order {
            case .cpu where a.cpuPercent != b.cpuPercent: return a.cpuPercent > b.cpuPercent
            case .memory where a.memoryBytes != b.memoryBytes: return a.memoryBytes > b.memoryBytes
            default:
                let names = a.name.localizedStandardCompare(b.name)
                return names == .orderedSame ? a.pid < b.pid : names == .orderedAscending
            }
        }
    }

    /// Failed services first, so they are seen; then those running, in `order`; then the
    /// rest by name.
    public static func services(in listing: RunningAppsListing, sortedBy order: Sort) -> [RunningService] {
        func rank(_ service: RunningService) -> Int {
            switch service.state {
            case .failed: 0
            case .active, .activating, .deactivating, .other: 1
            case .inactive: 2
            }
        }
        return listing.services.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if rank(a) == 1 {
                switch order {
                case .cpu where a.cpuPercent != b.cpuPercent: return a.cpuPercent > b.cpuPercent
                case .memory where a.memoryBytes != b.memoryBytes: return a.memoryBytes > b.memoryBytes
                default: break
                }
            }
            let names = a.name.localizedStandardCompare(b.name)
            return names == .orderedSame ? a.id < b.id : names == .orderedAscending
        }
    }

    /// Listening sockets as the owner reads them: `TCP 8080` on every address, else with
    /// its address (`TCP 127.0.0.1:631`, `UDP [::1]:53`). The same port on IPv4 and IPv6
    /// wildcards is shown once; the order is by port.
    public static func portLabels(_ ports: [RunningApp.Port]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        let ordered = ports.sorted { ($0.port, $0.transport.rawValue, $0.address) < ($1.port, $1.transport.rawValue, $1.address) }
        for port in ordered {
            let name = port.transport == .other ? "Port" : port.transport.rawValue.uppercased()
            let address = port.address
            let label: String
            if ["", "*", "0.0.0.0", "::", "[::]"].contains(address) {
                label = "\(name) \(port.port)"
            } else if address.contains(":"), !address.hasPrefix("[") {
                label = "\(name) [\(address)]:\(port.port)"
            } else {
                label = "\(name) \(address):\(port.port)"
            }
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels
    }

    /// Everything listed, the session included, against the computer's limits.
    public struct Totals: Equatable, Sendable {
        /// Summed over every CPU: up to `cpus * 100`.
        public var cpuPercent: Double
        public var memoryBytes: Int
        public var cpus: Int
        public var machineMemoryBytes: Int

        /// The share of the whole computer's CPU, 0 to 1.
        public var cpuShare: Double { cpus > 0 ? min(1, max(0, cpuPercent / Double(cpus * 100))) : 0 }
        /// The share of the computer's memory, 0 to 1.
        public var memoryShare: Double {
            machineMemoryBytes > 0 ? min(1, max(0, Double(memoryBytes) / Double(machineMemoryBytes))) : 0
        }
    }

    public static func totals(_ listing: RunningAppsListing) -> Totals {
        Totals(cpuPercent: listing.apps.reduce(0) { $0 + max(0, $1.cpuPercent) },
               memoryBytes: listing.apps.reduce(0) { $0 + max(0, $1.memoryBytes) },
               cpus: listing.machine.cpus, machineMemoryBytes: listing.machine.memoryBytes)
    }

    // MARK: Formatting

    /// Binary units, as Activity Monitor shows memory: `512 B`, `1.5 KB`, `340 MB`, `2.1 GB`.
    public static func bytes(_ value: Int) -> String { bytes(Double(value)) }

    public static func bytes(_ value: Double) -> String {
        var amount = value.isFinite ? max(0, value) : 0
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount.rounded())) B" }
        // 1023.96 KB reads as 1.0 MB, not 1024 KB.
        if amount.rounded() >= 1024, unit < units.count - 1 { return "1.0 \(units[unit + 1])" }
        return amount < 99.95 ? String(format: "%.1f", amount) + " " + units[unit]
                              : "\(Int(amount.rounded())) \(units[unit])"
    }

    /// Bytes per second: `0 B/s`, `1.2 MB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// A percentage: one decimal below 10, whole above; never negative.
    public static func percent(_ value: Double) -> String {
        let amount = value.isFinite ? max(0, value) : 0
        if amount < 0.05 { return "0%" }
        return amount < 9.95 ? String(format: "%.1f%%", amount) : "\(Int(amount.rounded()))%"
    }

    // MARK: A dock entry's running apps

    /// The running apps behind a dock or taskbar entry: those owning any of its windows (the
    /// display protocol's window ids the shell groups under the entry), then those launched
    /// from or matched to its desktop entry. The session is never one of them.
    public static func matching(windowIDs: some Sequence<Int>, desktopID: String?, in apps: [RunningApp]) -> [RunningApp] {
        let windows = Set(windowIDs)
        let candidates = apps.filter { !$0.isSession }
        var found = candidates.filter { !windows.isDisjoint(with: $0.windows) }
        if let desktopID {
            for app in candidates where !found.contains(where: { $0.id == app.id }) {
                if let id = app.desktopId, sameDesktopID(id, desktopID) { found.append(app) }
            }
        }
        return found
    }

    /// Desktop ids compare without case and with or without `.desktop`.
    public static func sameDesktopID(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        return !a.isEmpty && a == b
    }

    private static func normalized(_ id: String) -> String {
        let lowered = id.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasSuffix(".desktop") ? String(lowered.dropLast(8)) : lowered
    }
}

extension RunningApp {
    /// Caboose's session scope: its own services and anything no app claims.
    public var isSession: Bool { kind == .session }

    /// How the app is present to the owner.
    public enum Presence: Equatable, Sendable {
        /// It has this many windows (toplevels and dialogs).
        case windows(Int)
        /// It runs with no window, such as Steam closed to its tray.
        case background
        /// A terminal session from the phone, which has no window by nature.
        case terminal
        /// An agent task's processes, which have none either.
        case agent
    }

    public var presence: Presence {
        if !windows.isEmpty { return .windows(windows.count) }
        switch origin {
        case .terminal: return .terminal
        case .agent: return .agent
        default: return .background
        }
    }

    /// Running without a window: closing its windows is not how it ends.
    public var isBackground: Bool { !isSession && presence == .background }

    /// Quit asks its windows to close, so it needs some.
    public var canQuit: Bool { !isSession && !windows.isEmpty }

    /// Force Quit and Kill end any app but the session.
    public var canEnd: Bool { !isSession }
}

/// Quit asks politely; an app still listed some seconds later is offered Force Quit, as a
/// Mac offers it for an app that does not respond.
public struct QuitFollowUp: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 5

    public let delay: TimeInterval
    private(set) var asked: [String: Date] = [:]

    public init(delay: TimeInterval = Self.defaultDelay) {
        self.delay = delay
    }

    /// The owner asked an app to quit at `time`.
    public mutating func quitRequested(_ id: String, at time: Date) {
        asked[id] = time
    }

    /// An app ended or was ended another way: nothing to offer for it.
    public mutating func forget(_ id: String) {
        asked[id] = nil
    }

    public var pending: Set<String> { Set(asked.keys) }

    /// After a listing at `now`: the apps asked to quit at least `delay` ago that are still
    /// listed, each returned once. Apps no longer listed have quit and are forgotten.
    public mutating func due(listed: some Sequence<String>, now: Date) -> [String] {
        let listed = Set(listed)
        var due: [String] = []
        for (id, time) in asked.sorted(by: { $0.value < $1.value }) {
            if !listed.contains(id) {
                asked[id] = nil
            } else if now.timeIntervalSince(time) >= delay {
                asked[id] = nil
                due.append(id)
            }
        }
        return due
    }
}
