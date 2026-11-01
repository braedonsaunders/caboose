import Foundation

/// `GET /v1/running-apps` (docs/architecture.md, Running apps): the apps the computer runs,
/// each one cgroup scope with its whole process tree, and their live resource use.
///
/// Decoding is tolerant of a newer host: unknown fields are ignored, unknown enum values
/// decode as `.other`, and an app or process that cannot be read is dropped rather than
/// failing the whole listing.
public struct RunningAppsListing: Decodable, Equatable, Sendable {
    public struct Machine: Decodable, Equatable, Sendable {
        public var cpus: Int
        public var memoryBytes: Int

        public init(cpus: Int, memoryBytes: Int) {
            self.cpus = cpus
            self.memoryBytes = memoryBytes
        }
    }

    public var version: Int
    /// Unix milliseconds of the guest's latest sample.
    public var sampledAt: Double
    /// What the rates are measured over; 0 before a second sample.
    public var intervalMs: Int
    /// The computer's limits.
    public var machine: Machine
    public var apps: [RunningApp]
    /// Every service with a unit file, running or not.
    public var services: [RunningService]
    /// The host lists services: a host that predates them omits the field.
    public var listsServices: Bool

    /// Rates (CPU, IO, GPU) are measured: the guest has taken two samples.
    public var measured: Bool { intervalMs > 0 }

    public init(version: Int = 1, sampledAt: Double = 0, intervalMs: Int = 1000, machine: Machine, apps: [RunningApp],
                services: [RunningService]? = nil) {
        self.version = version
        self.sampledAt = sampledAt
        self.intervalMs = intervalMs
        self.machine = machine
        self.apps = apps
        self.services = services ?? []
        self.listsServices = services != nil
    }

    private enum CodingKeys: String, CodingKey { case version, sampledAt, intervalMs, machine, apps, services }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sampledAt = try c.decodeIfPresent(Double.self, forKey: .sampledAt) ?? 0
        intervalMs = try c.integer(.intervalMs) ?? 0
        machine = try c.decode(Machine.self, forKey: .machine)
        apps = try c.decodeIfPresent([Lossy<RunningApp>].self, forKey: .apps)?.compactMap(\.value) ?? []
        let services = try? c.decodeIfPresent([Lossy<RunningService>].self, forKey: .services)
        self.services = services?.compactMap(\.value) ?? []
        listsServices = services != nil
    }
}

/// One app: a scope and every process in it.
public struct RunningApp: Decodable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case app, session, other
    }

    /// How the guest placed it in its scope.
    public enum Origin: String, Sendable {
        case launch, window, game, terminal, agent, session, other
    }

    /// A listening socket.
    public struct Port: Decodable, Hashable, Sendable {
        public enum Transport: String, Sendable { case tcp, udp, other }

        public var transport: Transport
        public var address: String
        public var port: Int

        public init(_ transport: Transport, address: String, port: Int) {
            self.transport = transport
            self.address = address
            self.port = port
        }

        private enum CodingKeys: String, CodingKey { case transport = "protocol", address, port }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            transport = c.enumeration(.transport, default: .other)
            address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
            port = try c.decode(Int.self, forKey: .port)
        }
    }

    public struct IO: Decodable, Equatable, Sendable {
        public var readBytesPerSecond: Double
        public var writeBytesPerSecond: Double

        public init(readBytesPerSecond: Double = 0, writeBytesPerSecond: Double = 0) {
            self.readBytesPerSecond = readBytesPerSecond
            self.writeBytesPerSecond = writeBytesPerSecond
        }
    }

    public struct GPU: Decodable, Equatable, Sendable {
        public var streams: Int
        public var surfaces: Int
        public var toPhoneBytesPerSecond: Double
        public var fromPhoneBytesPerSecond: Double

        public init(streams: Int, surfaces: Int, toPhoneBytesPerSecond: Double, fromPhoneBytesPerSecond: Double) {
            self.streams = streams
            self.surfaces = surfaces
            self.toPhoneBytesPerSecond = toPhoneBytesPerSecond
            self.fromPhoneBytesPerSecond = fromPhoneBytesPerSecond
        }
    }

    public struct Process: Decodable, Identifiable, Equatable, Sendable {
        public enum State: String, Sendable {
            case running, sleeping, waiting, stopped, zombie, idle, other
        }

        public var pid: Int
        public var ppid: Int
        public var name: String
        /// Its arguments joined by spaces; empty when unreadable.
        public var command: String
        public var state: State
        /// Of one CPU.
        public var cpuPercent: Double
        /// Resident set.
        public var memoryBytes: Int

        public var id: Int { pid }

        public init(pid: Int, ppid: Int = 1, name: String, command: String = "", state: State = .sleeping,
                    cpuPercent: Double = 0, memoryBytes: Int = 0) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.command = command
            self.state = state
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
        }

        private enum CodingKeys: String, CodingKey { case pid, ppid, name, command, state, cpuPercent, memoryBytes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = try c.decode(Int.self, forKey: .pid)
            ppid = try c.integer(.ppid) ?? 0
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
            state = c.enumeration(.state, default: .other)
            cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
            memoryBytes = try c.integer(.memoryBytes) ?? 0
        }
    }

    /// The scope: `session.scope` or `app-<key>-<n>.scope`, with systemd's escapes (`\x2d`).
    public var id: String
    public var kind: Kind
    /// The desktop entry it was launched from or matched to.
    public var desktopId: String?
    public var name: String
    public var origin: Origin
    /// Unix milliseconds the scope was made; 0 for the session.
    public var startedAt: Double
    /// The owner display's window ids (toplevels and dialogs) of its processes.
    public var windows: [Int]
    /// Of one CPU, over the listing's interval.
    public var cpuPercent: Double
    /// Charged memory less inactive page cache.
    public var memoryBytes: Int
    public var io: IO
    /// Live GPU use, or nil for an app that has none.
    public var gpu: GPU?
    public var processCount: Int
    /// Its listening sockets; the session's are Caboose's own.
    public var ports: [Port]
    /// At most 256, busiest first.
    public var processes: [Process]

    public init(id: String, kind: Kind = .app, desktopId: String? = nil, name: String, origin: Origin = .launch,
                startedAt: Double = 0, windows: [Int] = [], cpuPercent: Double = 0, memoryBytes: Int = 0,
                io: IO = IO(), gpu: GPU? = nil, processCount: Int? = nil, ports: [Port] = [], processes: [Process] = []) {
        self.ports = ports
        self.id = id
        self.kind = kind
        self.desktopId = desktopId
        self.name = name
        self.origin = origin
        self.startedAt = startedAt
        self.windows = windows
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.io = io
        self.gpu = gpu
        self.processCount = processCount ?? processes.count
        self.processes = processes
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, desktopId, name, origin, startedAt, windows, cpuPercent, memoryBytes, io, gpu, processCount, ports, processes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "An app needs an id")
        }
        kind = c.enumeration(.kind, default: .other)
        desktopId = try c.decodeIfPresent(String.self, forKey: .desktopId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        origin = c.enumeration(.origin, default: .other)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        windows = try c.decodeIfPresent([Lossy<Int>].self, forKey: .windows)?.compactMap(\.value) ?? []
        cpuPercent = try c.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0
        memoryBytes = try c.integer(.memoryBytes) ?? 0
        io = (try? c.decodeIfPresent(IO.self, forKey: .io)) ?? IO()
        gpu = try? c.decodeIfPresent(GPU.self, forKey: .gpu)
        processes = try c.decodeIfPresent([Lossy<Process>].self, forKey: .processes)?.compactMap(\.value) ?? []
        processCount = try c.integer(.processCount) ?? processes.count
        ports = (try? c.decodeIfPresent([Lossy<Port>].self, forKey: .ports))??.compactMap(\.value) ?? []
    }
}

/// What `POST /v1/running-apps/:id/quit` answers: the number of windows asked to close.
public struct RunningAppQuitReply: Decodable, Equatable, Sendable {
    public var closed: Int
}

/// What Force Quit and Kill answer: whether the app has ended, and whether it had to be killed.
public struct RunningAppEndReply: Decodable, Equatable, Sendable {
    public var ended: Bool
    public var killed: Bool
}

/// The running-apps routes, with the app's id percent-encoded as one path segment.
public enum RunningAppsRoute {
    public static let list = "/v1/running-apps"

    public enum Action: String, Sendable {
        /// Ask every window to close.
        case quit
        /// SIGTERM every process, then kill what remains after 5 s.
        case forceQuit = "force-quit"
        /// Kill every process at once.
        case kill
    }

    public static func path(_ action: Action, id: String) -> String {
        "\(list)/\(encode(id))/\(action.rawValue)"
    }

    /// Everything but RFC 3986's unreserved ASCII is escaped: a scope's backslashes
    /// (`app-firefox\x2desr-3.scope`) become `%5C`, and a `/`, `?`, `#` or `%` cannot change
    /// the route.
    public static func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// An element that is dropped, not fatal, when it cannot be decoded.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// An integer the host may have written as a whole-valued float.
    func integer(_ key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        guard let value = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        guard value.isFinite, abs(value) < 9e18 else { return nil }
        return Int(value.rounded())
    }

    func enumeration<Value: RawRepresentable>(_ key: Key, default fallback: Value) -> Value where Value.RawValue == String {
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }
}
