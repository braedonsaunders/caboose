import Foundation

/// One attempt at starting a computer, as its host reports it (`GET /v1/computers/<id>/boot`):
/// each step the runtime takes, in its real order, with what it is doing now.
public struct ComputerBoot: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case running, succeeded, failed
    }

    public struct Step: Decodable, Equatable, Identifiable, Sendable {
        public enum State: String, Decodable, Sendable {
            case pending, active, done, skipped, failed

            /// A state a newer host may add reads as not started: nothing is claimed for it.
            public init(from decoder: Decoder) throws {
                self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
            }
        }

        public struct Progress: Decodable, Equatable, Sendable {
            public var completed: Double
            /// Nil when the host does not know how much there is.
            public var total: Double?

            public init(completed: Double, total: Double?) {
                self.completed = completed
                self.total = total
            }

            /// How much is done, 0…1; nil unless the total is known.
            public var fraction: Double? {
                guard let total, total > 0 else { return nil }
                return min(max(completed / total, 0), 1)
            }
        }

        /// `image`, `network`, `disk`, `start` or `display`.
        public var id: String
        public var label: String
        public var state: State
        public var detail: String?
        public var progress: Progress?

        public init(id: String, label: String, state: State, detail: String? = nil, progress: Progress? = nil) {
            self.id = id
            self.label = label
            self.state = state
            self.detail = detail
            self.progress = progress
        }
    }

    public var id: String
    public var state: State
    public var startedAt: String
    public var finishedAt: String?
    /// What failed, in words for the owner, when `state` is failed.
    public var error: String?
    public var steps: [Step]

    public init(id: String, state: State, startedAt: String, finishedAt: String? = nil, error: String? = nil, steps: [Step]) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.steps = steps
    }

    /// Whether this attempt has ended: no further event follows it.
    public var isFinished: Bool { state != .running }

    /// When the attempt began, parsed from `startedAt`.
    public var startDate: Date? { Self.date(startedAt) }
    public var finishDate: Date? { finishedAt.flatMap(Self.date) }

    /// The step that failed: the one marked failed, or else the one that was under way.
    public var failedStep: Step? {
        guard state == .failed else { return nil }
        return steps.first { $0.state == .failed } ?? steps.first { $0.state == .active }
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// `{ "boot": Boot | null }`, the body of the boot routes and of each boot event.
public struct ComputerBootEnvelope: Decodable, Equatable, Sendable {
    public var boot: ComputerBoot?

    public init(boot: ComputerBoot?) { self.boot = boot }

    public static func decode(_ data: Data) throws -> ComputerBootEnvelope {
        try JSONDecoder().decode(ComputerBootEnvelope.self, from: data)
    }
}

/// A Server-Sent Events decoder (the WHATWG event-stream format): fed the stream's bytes as
/// they arrive, in pieces of any size, it returns each event once its blank line has come.
/// Comments (`: keepalive`) and unknown fields are ignored; lines may end in LF, CRLF or CR.
public struct ServerSentEvents: Sendable {
    public struct Event: Equatable, Sendable {
        /// The `event:` field; `message` when there was none.
        public var name: String
        public var data: String
        public var id: String?

        public init(name: String, data: String, id: String? = nil) {
            self.name = name
            self.data = data
            self.id = id
        }
    }

    private var line: [UInt8] = []
    private var lastWasCR = false
    private var name = ""
    private var data: [String] = []
    private var hasData = false
    private var id: String?

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [Event] where Bytes.Element == UInt8 {
        var events: [Event] = []
        for byte in bytes {
            if lastWasCR {
                lastWasCR = false
                if byte == 0x0A { continue } // the LF of a CRLF
            }
            switch byte {
            case 0x0A:
                if let event = endLine() { events.append(event) }
            case 0x0D:
                lastWasCR = true
                if let event = endLine() { events.append(event) }
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// The event pending when the stream ends; the format discards it, and so does this.
    public mutating func finish() {
        line.removeAll()
        resetEvent()
    }

    private mutating func endLine() -> Event? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { resetEvent() }
            guard hasData else { return nil }
            return Event(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"), id: id)
        }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            var rest = text[text.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value)); hasData = true
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    private mutating func resetEvent() {
        name = ""
        data.removeAll()
        hasData = false
    }
}

/// What the spinning-up screen knows of a boot: the latest attempt the host reported and
/// whether the phone is in touch with it. Only the host's events move it.
public struct BootTracker: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        /// Reading the boot for the first time.
        case connecting
        case live
        /// The stream dropped; the boot is read again on `attempt`.
        case reconnecting(attempt: Int, reason: String)
    }

    public private(set) var boot: ComputerBoot?
    public private(set) var link: Link = .connecting
    /// Attempts the owner has retried past: an event about one of them is old news.
    public private(set) var superseded: Set<String> = []

    public init(boot: ComputerBoot? = nil) {
        self.boot = boot
    }

    /// A boot the host reported, from the stream or a request. Returns whether it changed
    /// what is shown.
    @discardableResult
    public mutating func apply(_ incoming: ComputerBoot?) -> Bool {
        if link != .live { link = .live }
        guard let incoming, !superseded.contains(incoming.id) else { return false }
        guard incoming != boot else { return false }
        boot = incoming
        return true
    }

    /// The stream ended or failed before the boot finished.
    public mutating func dropped(reason: String) {
        let attempt: Int
        if case .reconnecting(let previous, _) = link { attempt = previous + 1 } else { attempt = 1 }
        link = .reconnecting(attempt: attempt, reason: reason)
    }

    /// The owner asked to try again: the failed attempt is set aside and the next one shown.
    public mutating func retrying() {
        if let boot { superseded.insert(boot.id) }
        boot = nil
        link = .connecting
    }

    /// Seconds to wait before reading the boot again after `attempt` drops: 1, 2, 4, then 8.
    public static func reconnectDelay(attempt: Int) -> Double {
        min(8, pow(2, Double(max(0, attempt - 1))))
    }

    public var isFinished: Bool { boot?.isFinished == true }
    public var succeeded: Bool { boot?.state == .succeeded }
    public var failed: Bool { boot?.state == .failed }
}

/// How one boot step reads on screen.
public struct BootStepPresentation: Equatable, Identifiable, Sendable {
    public enum Indicator: Equatable, Sendable {
        case waiting
        /// Under way. `fraction` is set only when the host knows how much there is.
        case working(fraction: Double?)
        case done
        /// The boot did not need this step (the image was already here, it was already running).
        case notNeeded
        case failed
    }

    public var id: String
    public var title: String
    public var detail: String?
    public var indicator: Indicator

    public init(_ step: ComputerBoot.Step) {
        id = step.id
        title = step.label
        let detail = step.detail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch step.state {
        case .pending: indicator = .waiting
        case .active: indicator = .working(fraction: step.progress?.fraction)
        case .done: indicator = .done
        case .skipped: indicator = .notNeeded
        case .failed: indicator = .failed
        }
        self.detail = detail ?? (step.state == .skipped ? "Not needed" : nil)
    }

    public static func steps(of boot: ComputerBoot) -> [BootStepPresentation] {
        boot.steps.map(BootStepPresentation.init)
    }

    /// "Step 2 of 5": the step under way (or that failed) among the boot's steps.
    public static func position(in boot: ComputerBoot) -> (index: Int, count: Int)? {
        guard let index = boot.steps.firstIndex(where: { $0.state == .active || $0.state == .failed }) else { return nil }
        return (index + 1, boot.steps.count)
    }

    /// Steps finished or not needed, of all of them: what has really been got through.
    public static func settled(in boot: ComputerBoot) -> Int {
        boot.steps.filter { $0.state == .done || $0.state == .skipped }.count
    }
}
