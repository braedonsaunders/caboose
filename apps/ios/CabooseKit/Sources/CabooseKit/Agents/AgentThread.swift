import Foundation

/// One entry of an agent task's transcript, as `GET /v1/agent/tasks/:id/transcript` and the
/// control socket's `agent.task.event` carry it (docs/architecture.md § Agents). One flat shape
/// for every type; each type fills the fields it has.
public struct TranscriptEntry: Decodable, Equatable, Sendable {
    public struct PlanEntry: Decodable, Equatable, Sendable {
        public var content: String
        /// ACP: pending, in_progress or completed.
        public var status: String
        public init(content: String, status: String) { self.content = content; self.status = status }
    }

    public struct Cost: Decodable, Equatable, Sendable {
        public var amount: Double
        public var currency: String
    }

    public var type: String
    public var at: String?
    public var turn: Int?
    public var text: String?
    public var attachments: [String]?
    public var toolId: String?
    public var title: String?
    /// ACP tool kind: read, edit, delete, move, search, execute, think, fetch, other.
    public var kind: String?
    /// ACP tool status: pending, in_progress, completed, failed.
    public var status: String?
    public var detail: String?
    public var entries: [PlanEntry]?
    public var requestId: String?
    public var tool: String?
    public var summary: String?
    public var auto: Bool?
    public var allow: Bool?
    public var message: String?
    public var used: Double?
    public var size: Double?
    public var cost: Cost?
    public var stopReason: String?

    public init(type: String, at: String? = nil, turn: Int? = nil, text: String? = nil, attachments: [String]? = nil,
                toolId: String? = nil, title: String? = nil, kind: String? = nil, status: String? = nil, detail: String? = nil,
                entries: [PlanEntry]? = nil, requestId: String? = nil, tool: String? = nil, summary: String? = nil,
                auto: Bool? = nil, allow: Bool? = nil, message: String? = nil, used: Double? = nil, size: Double? = nil,
                cost: Cost? = nil, stopReason: String? = nil) {
        self.type = type; self.at = at; self.turn = turn; self.text = text; self.attachments = attachments
        self.toolId = toolId; self.title = title; self.kind = kind; self.status = status; self.detail = detail
        self.entries = entries; self.requestId = requestId; self.tool = tool; self.summary = summary
        self.auto = auto; self.allow = allow; self.message = message; self.used = used; self.size = size
        self.cost = cost; self.stopReason = stopReason
    }
}

/// A task's conversation folded for display: turns, each the owner's prompt and what the agent
/// did and said, with consecutive tool calls grouped, a turn's plan kept current in place, and
/// permission requests marked with their answers.
public struct AgentThread: Equatable, Sendable {
    public struct Tool: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: String
        public var status: String
        public var detail: String?

        public var isDone: Bool { status == "completed" }
        public var isFailed: Bool { status == "failed" }
        public var isActive: Bool { status == "pending" || status == "in_progress" }
    }

    public struct Permission: Equatable, Sendable {
        public var requestId: String?
        public var tool: String
        public var summary: String
        /// Answered by the runner because the task does not ask first.
        public var auto: Bool
        /// The owner's answer, once given; nil while waiting.
        public var allowed: Bool?
        public var message: String?
    }

    public enum Item: Identifiable, Equatable, Sendable {
        case text(id: Int, String)
        case thought(id: Int, String)
        case tools(id: Int, [Tool])
        case plan(id: Int, [TranscriptEntry.PlanEntry])
        case permission(id: Int, Permission)
        case notice(id: Int, String)

        public var id: Int {
            switch self {
            case .text(let id, _), .thought(let id, _), .tools(let id, _), .plan(let id, _), .permission(let id, _), .notice(let id, _): id
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case finished(stopReason: String, summary: String)
        case failed(String)
        case signInRequired(String)
    }

    public struct Usage: Equatable, Sendable {
        public var used: Double
        public var size: Double
        public var fraction: Double { size > 0 ? min(1, used / size) : 0 }
    }

    public struct Turn: Identifiable, Equatable, Sendable {
        public var id: Int { number }
        public var number: Int
        public var prompt: String
        public var attachments: [String]
        public var items: [Item] = []
        public var outcome: Outcome?
        /// The context window the agent last reported: tokens used of its size.
        public var usage: Usage?
        public var cost: TranscriptEntry.Cost?

        public init(number: Int, prompt: String, attachments: [String] = []) {
            self.number = number
            self.prompt = prompt
            self.attachments = attachments
        }

        /// The turn's plan, as last updated.
        public var plan: [TranscriptEntry.PlanEntry]? {
            for item in items.reversed() { if case .plan(_, let entries) = item { return entries } }
            return nil
        }

        /// Every tool call in the turn, in order.
        public var tools: [Tool] {
            items.flatMap { item -> [Tool] in if case .tools(_, let tools) = item { tools } else { [] } }
        }

        /// The agent's last message in the turn.
        public var lastText: String? {
            for item in items.reversed() { if case .text(_, let text) = item { return text } }
            return nil
        }
    }

    public private(set) var turns: [Turn] = []
    /// Earlier transcript was left out because it was too long to read whole.
    public var truncated = false
    private var nextItem = 0

    public init() {}

    /// Folds a transcript read from the start; `prompt` names turn 1 when the transcript does not.
    public init(entries: [TranscriptEntry], prompt: String? = nil, truncated: Bool = false) {
        self.truncated = truncated
        if let prompt, entries.first?.type != "user" { turns = [Turn(number: 1, prompt: prompt)] }
        for entry in entries { append(entry) }
    }

    public var lastTurn: Turn? { turns.last }

    /// One line on what the agent is doing now: the tool it is running, or its plan's current step.
    public var activity: String? {
        guard let turn = turns.last, turn.outcome == nil else { return nil }
        if let tool = turn.tools.last(where: \.isActive) { return tool.title }
        if let step = turn.plan?.first(where: { $0.status == "in_progress" }) { return step.content }
        switch turn.items.last {
        case .text(_, let text)?: return text
        case .thought?: return "Thinking"
        default: return nil
        }
    }

    /// Plan progress for the current turn: steps completed, and steps in all.
    public var progress: (done: Int, total: Int)? {
        guard let plan = turns.last?.plan, !plan.isEmpty else { return nil }
        return (plan.filter { $0.status == "completed" }.count, plan.count)
    }

    /// Starts a turn the owner just sent, before the runner reports it.
    public mutating func begin(turn number: Int, prompt: String) {
        if let index = turns.firstIndex(where: { $0.number == number }) {
            turns[index].prompt = prompt
        } else {
            turns.append(Turn(number: number, prompt: prompt))
        }
    }

    /// The host clears its last-answer summary when another turn starts. Keep that
    /// answer in the conversation if the transcript has not supplied it yet.
    public mutating func retainAnswer(_ summary: String, turn number: Int) {
        guard !summary.isEmpty, let index = turns.firstIndex(where: { $0.number == number }),
              turns[index].lastText == nil else { return }
        turns[index].items.append(.text(id: newID(), summary))
        if turns[index].outcome == nil { turns[index].outcome = .finished(stopReason: "end_turn", summary: summary) }
    }

    /// Transcript snapshots are append-only but can lag control events. A stale read
    /// must not erase an answer already displayed. Explicit truncation still wins.
    public mutating func retainCompletedTurns(from previous: AgentThread) {
        guard !truncated else { return }
        for turn in previous.turns where turn.outcome != nil {
            if let index = turns.firstIndex(where: { $0.number == turn.number }) {
                if turns[index].outcome == nil { turns[index] = turn }
            } else { turns.append(turn) }
        }
        turns.sort { $0.number < $1.number }
        nextItem = max(nextItem, previous.nextItem)
    }

    public mutating func append(_ entry: TranscriptEntry) {
        if entry.type == "user", let number = entry.turn {
            if let index = turns.firstIndex(where: { $0.number == number }) {
                turns[index].prompt = entry.text ?? turns[index].prompt
                turns[index].attachments = entry.attachments ?? turns[index].attachments
            } else {
                turns.append(Turn(number: number, prompt: entry.text ?? "", attachments: entry.attachments ?? []))
            }
            return
        }
        if turns.isEmpty { turns.append(Turn(number: entry.turn ?? 1, prompt: "")) }
        let index = entry.turn.flatMap { number in turns.firstIndex { $0.number == number } } ?? turns.count - 1
        switch entry.type {
        case "text": add(.text(id: newID(), entry.text ?? ""), to: index)
        case "thought": add(.thought(id: newID(), entry.text ?? ""), to: index)
        case "notice": add(.notice(id: newID(), entry.text ?? ""), to: index)
        case "tool":
            let tool = Tool(id: entry.toolId ?? "", title: entry.title ?? "Tool", kind: entry.kind ?? "other",
                            status: entry.status ?? "pending", detail: entry.detail)
            if case .tools(let id, var tools)? = turns[index].items.last {
                tools.append(tool)
                turns[index].items[turns[index].items.count - 1] = .tools(id: id, tools)
            } else {
                add(.tools(id: newID(), [tool]), to: index)
            }
        case "tool_update":
            update(tool: entry, in: index)
        case "plan":
            let plan = entry.entries ?? []
            if let at = turns[index].items.firstIndex(where: { if case .plan = $0 { true } else { false } }) {
                turns[index].items[at] = .plan(id: turns[index].items[at].id, plan)
            } else {
                add(.plan(id: newID(), plan), to: index)
            }
        case "permission":
            add(.permission(id: newID(), Permission(requestId: entry.requestId, tool: entry.tool ?? "Tool", summary: entry.summary ?? "",
                                                    auto: entry.auto ?? false, allowed: (entry.auto ?? false) ? true : nil)), to: index)
        case "permission_resolved":
            for turn in turns.indices.reversed() {
                guard let at = turns[turn].items.firstIndex(where: {
                    if case .permission(_, let permission) = $0 { permission.requestId == entry.requestId } else { false }
                }), case .permission(let id, var permission) = turns[turn].items[at] else { continue }
                permission.allowed = entry.allow ?? false
                permission.message = entry.message
                turns[turn].items[at] = .permission(id: id, permission)
                break
            }
        case "usage":
            if let used = entry.used, let size = entry.size { turns[index].usage = Usage(used: used, size: size) }
            turns[index].cost = entry.cost ?? turns[index].cost
        case "turn_end": turns[index].outcome = .finished(stopReason: entry.stopReason ?? "end_turn", summary: entry.summary ?? "")
        case "turn_failed": turns[index].outcome = .failed(entry.message ?? "The agent failed.")
        case "auth_required": turns[index].outcome = .signInRequired(entry.message ?? "")
        default: break
        }
    }

    private mutating func newID() -> Int {
        nextItem += 1
        return nextItem
    }

    private mutating func add(_ item: Item, to index: Int) { turns[index].items.append(item) }

    private mutating func update(tool entry: TranscriptEntry, in index: Int) {
        for turn in ([index] + turns.indices.reversed().filter { $0 != index }) {
            for (at, item) in turns[turn].items.enumerated() {
                guard case .tools(let id, var tools) = item, let position = tools.firstIndex(where: { $0.id == entry.toolId }) else { continue }
                tools[position].title = entry.title ?? tools[position].title
                tools[position].kind = entry.kind ?? tools[position].kind
                tools[position].status = entry.status ?? tools[position].status
                turns[turn].items[at] = .tools(id: id, tools)
                return
            }
        }
    }
}
