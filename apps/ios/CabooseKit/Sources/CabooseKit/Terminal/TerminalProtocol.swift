import Foundation

/// The host's `/v1/terminal` contract (docs/architecture.md § Terminal): binary messages are
/// terminal bytes, text messages are JSON control messages.
public enum TerminalProtocol {
    public static let maxColumns = 1000
    public static let maxRows = 500

    /// The WebSocket URL for a new session (`session == nil`) or a reattach.
    ///
    /// `offset` is how much of the session's output this client already holds; the host then
    /// sends only what follows it. `wake` lets the request wake a parked computer.
    public static func url(base: URL, columns: Int, rows: Int, session: String?, offset: Int?, wake: Bool) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v1/terminal"), resolvingAgainstBaseURL: false)!
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        var query = [URLQueryItem(name: "cols", value: String(clamp(columns, maxColumns))),
                     URLQueryItem(name: "rows", value: String(clamp(rows, maxRows)))]
        if let session, isSessionID(session) {
            query.append(URLQueryItem(name: "session", value: session))
            if let offset, offset >= 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        }
        if wake { query.append(URLQueryItem(name: "wake", value: "1")) }
        components.queryItems = query
        return components.url!
    }

    public static func isSessionID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func clamp(_ value: Int, _ maximum: Int) -> Int { min(max(value, 1), maximum) }
}

/// What the host says on a text message.
public enum TerminalServerMessage: Equatable, Sendable {
    /// The first message on every connection. The binary messages that follow start at
    /// `offset` in the session's output; with `reset`, the client clears its terminal first
    /// and applies `modes` (DEC private modes the replay no longer sets itself).
    case hello(TerminalHello)
    /// The shell ended: with an exit code, or by a signal.
    case exit(code: Int?, signal: Int?)

    public init?(json text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello":
            guard let session = object["session"] as? String, TerminalProtocol.isSessionID(session),
                  let offset = Self.integer(object["offset"]), offset >= 0,
                  let reset = Self.boolean(object["reset"]) else { return nil }
            var modes: [Int: Bool] = [:]
            if let raw = object["modes"] as? [String: Any] {
                for (key, value) in raw {
                    guard let mode = Int(key), let set = Self.boolean(value) else { return nil }
                    modes[mode] = set
                }
            }
            self = .hello(TerminalHello(session: session, offset: offset, reset: reset, modes: modes))
        case "exit":
            let code = Self.integer(object["code"]), signal = Self.integer(object["signal"])
            guard code != nil || signal != nil else { return nil }
            self = .exit(code: code, signal: signal)
        default:
            return nil
        }
    }

    /// JSON numbers arrive as NSNumber; booleans must not pass as integers or the reverse.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return Double(int) == number.doubleValue ? int : nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

public struct TerminalHello: Equatable, Sendable {
    public var session: String
    public var offset: Int
    public var reset: Bool
    public var modes: [Int: Bool]

    public init(session: String, offset: Int, reset: Bool, modes: [Int: Bool] = [:]) {
        self.session = session
        self.offset = offset
        self.reset = reset
        self.modes = modes
    }

    /// What to feed a terminal before the replay: a full reset, then the modes the replay no
    /// longer carries, the alternate screen first so the others apply to it.
    public var preamble: [UInt8] {
        guard reset else { return [] }
        var bytes: [UInt8] = Array("\u{1b}c".utf8)
        let order = modes.keys.sorted { lhs, rhs in
            let screens: Set<Int> = [47, 1047, 1049]
            if screens.contains(lhs) != screens.contains(rhs) { return screens.contains(lhs) }
            return lhs < rhs
        }
        for mode in order {
            bytes += Array("\u{1b}[?\(mode)\(modes[mode]! ? "h" : "l")".utf8)
        }
        return bytes
    }
}

/// What a client sends on a text message.
public enum TerminalClientMessage: Equatable, Sendable {
    case resize(columns: Int, rows: Int)
    /// Ends the session: the shell is hung up, and an `exit` follows.
    case hangup

    public var json: String {
        switch self {
        case .resize(let columns, let rows):
            "{\"type\":\"resize\",\"cols\":\(TerminalProtocol.clamp(columns, TerminalProtocol.maxColumns)),\"rows\":\(TerminalProtocol.clamp(rows, TerminalProtocol.maxRows))}"
        case .hangup:
            "{\"type\":\"hangup\"}"
        }
    }
}

/// Why a connection ended, from its close code or the HTTP status that refused it.
public enum TerminalEnd: Equatable, Sendable {
    /// The shell exited (an `exit` message preceded the close).
    case exited(code: Int?, signal: Int?)
    /// The session no longer exists: the computer restarted, or it was closed elsewhere.
    case sessionEnded
    /// Another device attached to this session.
    case replaced
    /// Nothing went either way for too long.
    case idle
    /// The owner already has as many terminals open as the host allows.
    case tooMany
    /// The owner token was refused.
    case unauthorized
    /// The computer is parked or restarting.
    case notRunning
    /// Anything else: the network dropped, the host or the guest failed. Worth retrying.
    case dropped(String?)

    /// Close codes and reasons from docs/architecture.md § Terminal. URLSession reports
    /// application codes (4000–4999) unreliably, so the reason decides when the code is lost.
    public init(closeCode: Int, reason: String?) {
        switch (closeCode, reason) {
        case (4404, _), (_, "session ended"): self = .sessionEnded
        case (4001, _), (_, "attached elsewhere"): self = .replaced
        case (4408, _), (_, "idle"): self = .idle
        case (1013, _), (_, "too many terminal sessions"): self = .tooMany
        default: self = .dropped(reason.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public init(httpStatus: Int) {
        switch httpStatus {
        case 401: self = .unauthorized
        case 409: self = .notRunning
        case 429: self = .tooMany
        default: self = .dropped("The computer answered \(httpStatus).")
        }
    }

    /// Whether the client should reconnect on its own.
    public var retries: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// One entry of `GET /v1/terminal/sessions`.
public struct TerminalSessionInfo: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The title the shell last set (OSC 0 or 2), or empty.
    public var title: String
    /// The program in the foreground, such as `bash` or `vim`.
    public var command: String?
    public var cwd: String?
    public var cols: Int
    public var rows: Int
    /// Unix milliseconds.
    public var created: Int
    public var attached: Bool

    public init(id: String, title: String, command: String?, cwd: String?, cols: Int, rows: Int, created: Int, attached: Bool) {
        self.id = id
        self.title = title
        self.command = command
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.created = created
        self.attached = attached
    }

    /// A short name for menus: the program and where it is, with the home as `~`.
    public var displayName: String {
        let place = cwd.map(TerminalSessionInfo.abbreviate)
        switch (command, place) {
        case let (command?, place?): return "\(command) — \(place)"
        case let (command?, nil): return command
        case let (nil, place?): return place
        default: return title.isEmpty ? "Terminal" : title
        }
    }

    static func abbreviate(_ path: String) -> String {
        let home = "/home/caboose"
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
