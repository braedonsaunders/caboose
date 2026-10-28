import Foundation

/// What the owner said to Caboose and what the iPhone's own model did about it: the
/// conversation the Agents tab shows beside the computer's agent tasks. Kept on the phone.
public struct ConversationMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case working, done, failed }

    public var id: UUID
    public var date: Date
    public var prompt: String
    public var steps: [String]
    public var reply: String?
    public var status: Status
    public var seconds: Double?
    /// The computer agent task the request was handed to, if it was.
    public var taskID: String?

    public init(id: UUID = UUID(), date: Date = Date(), prompt: String, steps: [String] = [], reply: String? = nil,
                status: Status = .working, seconds: Double? = nil, taskID: String? = nil) {
        self.id = id; self.date = date; self.prompt = prompt; self.steps = steps; self.reply = reply
        self.status = status; self.seconds = seconds; self.taskID = taskID
    }
}

/// The conversation's messages, oldest first, at most `limit` of them, saved as JSON.
public struct ConversationLog: Codable, Equatable, Sendable {
    public static let limit = 80
    public private(set) var messages: [ConversationMessage] = []

    public init(messages: [ConversationMessage] = []) {
        self.messages = Array(messages.suffix(Self.limit))
    }

    public mutating func append(_ message: ConversationMessage) {
        messages.append(message)
        if messages.count > Self.limit { messages.removeFirst(messages.count - Self.limit) }
    }

    public mutating func update(_ id: UUID, _ change: (inout ConversationMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    public mutating func remove(_ id: UUID) { messages.removeAll { $0.id == id } }

    public mutating func clear() { messages = [] }

    /// A message still `working` when the app quit was cut off; it is shown as failed.
    public mutating func settleInterrupted() {
        for index in messages.indices where messages[index].status == .working {
            messages[index].status = .failed
            messages[index].reply = messages[index].reply ?? "Interrupted when Caboose closed."
        }
    }

    public static func load(from url: URL) -> ConversationLog {
        guard let data = try? Data(contentsOf: url), var log = try? JSONDecoder().decode(ConversationLog.self, from: data) else { return ConversationLog() }
        log.settleInterrupted()
        return log
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// One row of the conversation: something the iPhone handled, or a task started on the
/// computer directly (one the iPhone handed over appears inside its message instead).
public enum ConversationItem<Task: Identifiable>: Identifiable where Task.ID == String {
    case message(ConversationMessage)
    case task(Task)

    public var id: String {
        switch self {
        case .message(let message): "m:\(message.id.uuidString)"
        case .task(let task): "t:\(task.id)"
        }
    }

    /// Messages and tasks in the order they began, oldest first.
    public static func merge(messages: [ConversationMessage], tasks: [Task], started: (Task) -> Date?) -> [ConversationItem] {
        let handed = Set(messages.compactMap(\.taskID))
        let dated: [(Date, ConversationItem)] = messages.map { ($0.date, .message($0)) }
            + tasks.filter { !handed.contains($0.id) }.map { (started($0) ?? .distantPast, .task($0)) }
        return dated.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
