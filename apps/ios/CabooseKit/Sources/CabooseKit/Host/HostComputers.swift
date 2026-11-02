import Foundation

/// `GET /v1/computers`: a host's computers as a host sign-in sees them, whether it may make
/// another, and the sizes a new one can have. `computers` may be empty.
public struct HostComputerList: Decodable, Equatable, Sendable {
    public struct Computer: Decodable, Equatable, Identifiable, Sendable {
        public struct Settings: Decodable, Equatable, Sendable {
            public var name: String
            public var memoryMb: Int?
            public var vcpus: Int?

            public init(name: String, memoryMb: Int? = nil, vcpus: Int? = nil) {
                self.name = name
                self.memoryMb = memoryMb
                self.vcpus = vcpus
            }
        }

        public var id: String
        /// The lifecycle state the host reports: `parked`, `waking`, `running`, `frozen`,
        /// `parking`, `restarting` or `error`.
        public var state: String
        public var settings: Settings
        public var boot: ComputerBoot?

        public init(id: String, state: String, settings: Settings, boot: ComputerBoot? = nil) {
            self.id = id
            self.state = state
            self.settings = settings
            self.boot = boot
        }

        public var name: String { settings.name.isEmpty ? id : settings.name }

        /// How the computer is, in a word or two.
        public var stateTitle: String {
            if boot?.state == .running { return "Starting" }
            if boot?.state == .failed && state != "running" { return "Didn't start" }
            switch state {
            case "running": return "Running"
            case "frozen": return "Idle"
            case "parked": return "Parked"
            case "waking": return "Waking"
            case "parking": return "Parking"
            case "restarting": return "Restarting"
            case "error": return "Needs attention"
            default: return state.prefix(1).uppercased() + state.dropFirst()
            }
        }
    }

    public struct Size: Decodable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var memoryMb: Int
        public var vcpus: Int
        public var available: Bool

        public init(id: String, name: String, memoryMb: Int, vcpus: Int, available: Bool) {
            self.id = id
            self.name = name
            self.memoryMb = memoryMb
            self.vcpus = vcpus
            self.available = available
        }

        /// "4 GB memory · 2 CPUs".
        public var summary: String {
            let memory = memoryMb % 1024 == 0 ? "\(memoryMb / 1024) GB" : String(format: "%.1f GB", Double(memoryMb) / 1024)
            return "\(memory) memory · \(vcpus) \(vcpus == 1 ? "CPU" : "CPUs")"
        }
    }

    public struct Limits: Decodable, Equatable, Sendable {
        public var computers: Int
        public var running: Int?

        public init(computers: Int, running: Int?) {
            self.computers = computers
            self.running = running
        }
    }

    public var computers: [Computer]
    public var canCreate: Bool
    public var limits: Limits?
    public var defaultComputer: String?
    public var sizes: [Size]

    public init(computers: [Computer], canCreate: Bool, limits: Limits? = nil, defaultComputer: String? = nil, sizes: [Size] = []) {
        self.computers = computers
        self.canCreate = canCreate
        self.limits = limits
        self.defaultComputer = defaultComputer
        self.sizes = sizes
    }

    enum CodingKeys: String, CodingKey { case computers, canCreate, limits, defaultComputer, sizes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        computers = try container.decode([Computer].self, forKey: .computers)
        canCreate = try container.decodeIfPresent(Bool.self, forKey: .canCreate) ?? false
        limits = try container.decodeIfPresent(Limits.self, forKey: .limits)
        defaultComputer = try container.decodeIfPresent(String.self, forKey: .defaultComputer)
        sizes = try container.decodeIfPresent([Size].self, forKey: .sizes) ?? []
    }

    /// The sizes a new computer can have on this host now.
    public var availableSizes: [Size] { sizes.filter(\.available) }

    /// The size offered first: `standard` when it is available, else the first that is.
    public var suggestedSize: Size? {
        availableSizes.first { $0.id == "standard" } ?? availableSizes.first
    }

    /// Every computer slot is taken.
    public var isFull: Bool {
        guard let limits else { return false }
        return computers.count >= limits.computers
    }

    /// Whether this sign-in can make a computer here now.
    public var allowsCreating: Bool { canCreate && !isFull && !availableSizes.isEmpty }

    /// Why a computer cannot be made here now, in words for the owner; nil when it can.
    public var creationBlocker: String? {
        if !canCreate { return "This host isn't ready to make computers yet. Finish setting it up in the Caboose console." }
        if isFull { return "Every computer slot on this host is in use. Delete a computer in the console to make room." }
        if availableSizes.isEmpty { return "This host doesn't have room for another computer right now." }
        return nil
    }

    /// The computer to open: the one chosen before while it still exists, else the host's
    /// default, else the first. Nil when the host has none.
    public func preferred(selected: String?) -> Computer? {
        if let selected, let chosen = computers.first(where: { $0.id == selected }) { return chosen }
        if let defaultComputer, let chosen = computers.first(where: { $0.id == defaultComputer }) { return chosen }
        return computers.first
    }

    /// A name for a new computer: the person's own when the device's name says it
    /// ("Sam's iPhone" → "Sam's Computer"), else "My Computer"; numbered when it is taken.
    public static func suggestedName(deviceName: String, existing: [String]) -> String {
        var base = "My Computer"
        for apostrophe in ["’s ", "'s "] {
            if let range = deviceName.range(of: apostrophe) {
                let owner = deviceName[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !owner.isEmpty, owner.count <= 30 { base = owner + apostrophe + "Computer" }
                break
            }
        }
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
