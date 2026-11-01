import Foundation

/// A service on the computer (docs/architecture.md, Services): one in the listing's
/// `services`, with its live use, or the status a service route answers, without it.
public struct RunningService: Decodable, Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case system, owner, other }

    public enum State: String, Sendable {
        case inactive, activating, active, deactivating, failed, other
    }

    public enum Restart: String, CaseIterable, Identifiable, Sendable {
        case no
        case onFailure = "on-failure"
        case always
        case other

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .no: "Never"
            case .onFailure: "On Failure"
            case .always: "Always"
            case .other: "Other"
            }
        }
    }

    public struct Exit: Decodable, Equatable, Sendable {
        public var code: Int?
        public var signal: Int?
        /// Unix milliseconds.
        public var at: Double

        public init(code: Int? = nil, signal: Int? = nil, at: Double) {
            self.code = code
            self.signal = signal
            self.at = at
        }
    }

    /// `<name>.service`.
    public var id: String
    public var name: String
    public var description: String
    public var source: Source
    public var state: State
    /// Why it failed or is restarting, or why its unit file is refused.
    public var error: String?
    /// Starts with the computer.
    public var autostart: Bool
    public var restart: Restart
    public var requires: [String]
    /// Unix milliseconds of the last state change.
    public var since: Double
    /// Automatic restarts since the daemon started.
    public var restarts: Int
    public var lastExit: Exit?
    public var cpuPercent: Double
    public var memoryBytes: Int
    public var io: RunningApp.IO
    public var gpu: RunningApp.GPU?
    public var processCount: Int
    public var processes: [RunningApp.Process]
    public var ports: [RunningApp.Port]

    public init(name: String, description: String = "", source: Source = .owner, state: State = .inactive,
                error: String? = nil, autostart: Bool = false, restart: Restart = .onFailure, requires: [String] = [],
                since: Double = 0, restarts: Int = 0, lastExit: Exit? = nil, cpuPercent: Double = 0,
                memoryBytes: Int = 0, io: RunningApp.IO = .init(), gpu: RunningApp.GPU? = nil,
                processCount: Int = 0, processes: [RunningApp.Process] = [], ports: [RunningApp.Port] = []) {
        self.id = name + ".service"
        self.name = name
        self.description = description
        self.source = source
        self.state = state
        self.error = error
        self.autostart = autostart
        self.restart = restart
        self.requires = requires
        self.since = since
        self.restarts = restarts
        self.lastExit = lastExit
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.io = io
        self.gpu = gpu
        self.processCount = processCount
        self.processes = processes
        self.ports = ports
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, source, state, error, autostart, restart, requires, since, restarts, lastExit
        case cpuPercent, memoryBytes, io, gpu, processCount, processes, ports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        guard let resolved = name ?? id.map(RunningService.name(fromID:)), !resolved.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "A service needs a name")
        }
        self.name = resolved
        self.id = id ?? resolved + ".service"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = c.enumeration(.source, default: .other)
        state = c.enumeration(.state, default: .other)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        autostart = (try? c.decodeIfPresent(Bool.self, forKey: .autostart)) ?? false
        restart = c.enumeration(.restart, default: .other)
        requires = (try? c.decodeIfPresent([Lossy<String>].self, forKey: .requires))??.compactMap(\.value) ?? []
        since = (try? c.decodeIfPresent(Double.self, forKey: .since)) ?? 0
        restarts = (try? c.integer(.restarts)) ?? 0
        lastExit = try? c.decodeIfPresent(Exit.self, forKey: .lastExit)
        cpuPercent = (try? c.decodeIfPresent(Double.self, forKey: .cpuPercent)) ?? 0
        memoryBytes = (try? c.integer(.memoryBytes)) ?? 0
        io = (try? c.decodeIfPresent(RunningApp.IO.self, forKey: .io)) ?? .init()
        gpu = try? c.decodeIfPresent(RunningApp.GPU.self, forKey: .gpu)
        processes = (try? c.decodeIfPresent([Lossy<RunningApp.Process>].self, forKey: .processes))??.compactMap(\.value) ?? []
        processCount = (try? c.integer(.processCount)) ?? processes.count
        ports = (try? c.decodeIfPresent([Lossy<RunningApp.Port>].self, forKey: .ports))??.compactMap(\.value) ?? []
    }

    /// `web.service` → `web`.
    public static func name(fromID id: String) -> String {
        id.hasSuffix(".service") ? String(id.dropLast(8)) : id
    }

    /// Running or on its way: it has processes worth showing.
    public var isRunning: Bool { state == .active || state == .activating || state == .deactivating }
    public var canStart: Bool { state == .inactive || state == .failed }
    public var canStop: Bool { state == .active || state == .activating }
    public var canRestart: Bool { state == .active || state == .failed }
    /// Only the owner's services can be removed.
    public var canDelete: Bool { source == .owner }
    /// The error is worth showing in a list: it failed, or is restarting after a failure.
    public var showsError: Bool { (state == .failed || state == .activating) && !(error ?? "").isEmpty }
}

/// The service routes, with the service's name (without `.service`) percent-encoded.
public enum ServicesRoute {
    public enum Action: String, Sendable { case start, stop, restart, enable, disable }

    public static func path(name: String) -> String { "/v1/services/\(RunningAppsRoute.encode(name))" }

    public static func path(_ action: Action, name: String) -> String { path(name: name) + "/" + action.rawValue }

    /// The last `lines` (1–2000) of its log.
    public static func logs(name: String, lines: Int) -> String {
        path(name: name) + "/logs?lines=\(min(2000, max(1, lines)))"
    }
}

/// What `PUT /v1/services/:name` takes: an owner service, made from the New Service form.
public struct ServiceDefinition: Encodable, Equatable, Sendable {
    public enum Problem: Error, Equatable, LocalizedError {
        case name
        case command(ShellWords.Problem)
        case emptyCommand
        case environmentName(String)
        case duplicateEnvironment(String)

        public var errorDescription: String? {
            switch self {
            case .name:
                "A name is 1 to 64 letters, digits, “_”, “.”, “@” or “-”, starting with a letter or digit."
            case .command(let problem): problem.errorDescription
            case .emptyCommand: "Enter the command to run."
            case .environmentName(let name):
                "“\(name)” is not a variable name: use letters, digits and “_”, not starting with a digit."
            case .duplicateEnvironment(let name): "“\(name)” is set twice."
            }
        }
    }

    public var command: [String]
    public var description: String?
    public var workingDirectory: String?
    public var environment: [String: String]?
    public var restart: String
    public var autostart: Bool

    /// The checked definition from the form's fields. Blank optional fields are left out;
    /// environment rows with neither a name nor a value are ignored.
    public static func make(name: String, commandLine: String, description: String = "", workingDirectory: String = "",
                            environment: [(name: String, value: String)] = [], restart: RunningService.Restart = .onFailure,
                            autostart: Bool = true) throws -> ServiceDefinition {
        guard isValidName(name) else { throw Problem.name }
        let words: [String]
        do { words = try ShellWords.split(commandLine) } catch let problem as ShellWords.Problem { throw Problem.command(problem) }
        guard !words.isEmpty else { throw Problem.emptyCommand }
        var variables: [String: String] = [:]
        for row in environment {
            let key = row.name.trimmingCharacters(in: .whitespaces)
            if key.isEmpty && row.value.isEmpty { continue }
            guard isValidVariable(key) else { throw Problem.environmentName(key) }
            guard variables[key] == nil else { throw Problem.duplicateEnvironment(key) }
            variables[key] = row.value
        }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServiceDefinition(command: words, description: description.isEmpty ? nil : description,
                                 workingDirectory: directory.isEmpty ? nil : directory,
                                 environment: variables.isEmpty ? nil : variables,
                                 restart: (restart == .other ? .onFailure : restart).rawValue, autostart: autostart)
    }

    /// 1–64 of `A-Z a-z 0-9 _ . @ -`, not starting with a punctuation character.
    public static func isValidName(_ name: String) -> Bool {
        guard (1 ... 64).contains(name.unicodeScalars.count), let first = name.unicodeScalars.first,
              alphanumerics.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { alphanumerics.contains($0) || "_.@-".unicodeScalars.contains($0) }
    }

    static func isValidVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !digits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { alphanumerics.contains($0) || $0 == "_" }
    }

    private static let digits = CharacterSet(charactersIn: "0123456789")
    private static let alphanumerics = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
}

/// A command line split into words the way a POSIX shell would, without running anything:
/// blanks separate words; `'…'` keeps everything literally; `"…"` keeps everything but a
/// backslash before `"`, `\`, `$`, `` ` `` or a newline; a backslash outside quotes keeps the
/// next character. Nothing is expanded: `$HOME`, `~` and `*` stay as written.
public enum ShellWords {
    public enum Problem: Error, Equatable, LocalizedError {
        case unterminatedSingleQuote
        case unterminatedDoubleQuote
        case trailingBackslash

        public var errorDescription: String? {
            switch self {
            case .unterminatedSingleQuote: "The command has a ' without its closing '."
            case .unterminatedDoubleQuote: "The command has a \" without its closing \"."
            case .trailingBackslash: "The command ends with a \\ that escapes nothing."
            }
        }
    }

    public static func split(_ line: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var characters = line.makeIterator()
        while let character = characters.next() {
            switch character {
            case " ", "\t", "\n", "\r", "\r\n":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                var closed = false
                while let next = characters.next() {
                    if next == "'" { closed = true; break }
                    word.append(next)
                }
                guard closed else { throw Problem.unterminatedSingleQuote }
            case "\"":
                inWord = true
                var closed = false
                while let next = characters.next() {
                    if next == "\"" { closed = true; break }
                    if next == "\\" {
                        guard let escaped = characters.next() else { throw Problem.unterminatedDoubleQuote }
                        switch escaped {
                        case "\"", "\\", "$", "`": word.append(escaped)
                        case "\n": break
                        default: word.append("\\"); word.append(escaped)
                        }
                        continue
                    }
                    word.append(next)
                }
                guard closed else { throw Problem.unterminatedDoubleQuote }
            case "\\":
                guard let escaped = characters.next() else { throw Problem.trailingBackslash }
                if escaped == "\n" { continue }
                inWord = true
                word.append(escaped)
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
