import Foundation

/// How a chat request becomes one turn of a language model session: the instructions, the
/// conversation before the turn, the prompt, and the tool results the turn already has.
/// Apple's sessions take a transcript and a prompt, where the OpenAI API sends the whole
/// conversation every time.
public struct AIConversation: Equatable, Sendable {
    public enum Entry: Equatable, Sendable {
        case user(AIRelay.Message)
        case assistant(text: String, toolCalls: [AIRelay.ToolCall])
        case toolOutput(callId: String, name: String, text: String)
    }

    /// The system and developer messages, joined.
    public var instructions: String
    /// The conversation before the turn, oldest first.
    public var history: [Entry]
    /// The last user message: the turn's prompt.
    public var prompt: AIRelay.Message
    /// The tool calls the model made in this turn and the results the program sent for them,
    /// in order. Empty when the turn starts now.
    public var results: [(call: AIRelay.ToolCall, output: String)]
    /// Messages dropped from the front of the history so the conversation fits.
    public var dropped = 0

    public static func == (a: AIConversation, b: AIConversation) -> Bool {
        a.instructions == b.instructions && a.history == b.history && a.prompt == b.prompt && a.dropped == b.dropped
            && a.results.count == b.results.count && zip(a.results, b.results).allSatisfy { $0.call == $1.call && $0.output == $1.output }
    }

    /// The ids of the results, which name a turn waiting for them.
    public var resultIDs: Set<String> { Set(results.map(\.call.id)) }

    public init(_ request: AIRelay.Request) throws(AIRelay.Failure) {
        let messages = request.messages
        guard let last = messages.lastIndex(where: { $0.role == .user }) else {
            throw AIRelay.Failure(status: 400, code: "invalid_request", message: "The conversation needs a user message.")
        }
        instructions = messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        prompt = messages[last]
        var names: [String: String] = [:]
        history = []
        for message in messages[..<last] {
            switch message.role {
            case .system: continue
            case .user: history.append(.user(message))
            case .assistant:
                for call in message.toolCalls { names[call.id] = call.name }
                history.append(.assistant(text: message.text, toolCalls: message.toolCalls))
            case .tool:
                let id = message.toolCallId ?? ""
                history.append(.toolOutput(callId: id, name: names[id] ?? "tool", text: message.text))
            }
        }
        var calls: [AIRelay.ToolCall] = []
        var outputs: [String: String] = [:]
        for message in messages[(last + 1)...] {
            switch message.role {
            case .system: continue
            case .assistant:
                guard !message.toolCalls.isEmpty else {
                    throw AIRelay.Failure(status: 400, code: "invalid_request", message: "The last message must be the user's, or tool results.")
                }
                calls += message.toolCalls
            case .tool: outputs[message.toolCallId ?? ""] = message.text
            case .user: break
            }
        }
        results = calls.compactMap { call in outputs[call.id].map { (call, $0) } }
        if results.count < calls.count {
            throw AIRelay.Failure(status: 400, code: "invalid_request", message: "Every tool call needs a tool message with its result.")
        }
    }

    /// Drops the oldest turns until `count` says the conversation fits `budget` tokens. A turn
    /// is a user message and what followed it; the prompt and instructions always stay.
    public mutating func fit(budget: Int, count: (AIConversation) async throws -> Int) async throws -> Int {
        var tokens = try await count(self)
        while tokens > budget, !history.isEmpty {
            var cut = 1
            while cut < history.count { if case .user = history[cut] { break }; cut += 1 }
            history.removeFirst(cut)
            dropped += cut
            tokens = try await count(self)
        }
        return tokens
    }
}

/// The answer's text as it streams in cumulative snapshots: what is new each time, holding back
/// a tail that could be the start of a stop sequence, and where a stop sequence ends it.
public struct AIStreamText: Sendable {
    public let stops: [String]
    /// What has been sent.
    public private(set) var sent = ""
    public private(set) var stopped = false
    private var seen = ""

    public init(stops: [String]) { self.stops = stops.filter { !$0.isEmpty } }

    /// The new text to send for `snapshot`, the whole answer so far.
    public mutating func advance(to snapshot: String) -> String {
        guard !stopped, snapshot.hasPrefix(seen) || seen.isEmpty else { return "" }
        seen = snapshot
        if let range = stops.compactMap({ snapshot.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            stopped = true
            return take(upTo: String(snapshot[..<range.lowerBound]))
        }
        let hold = stops.map { stop in (1..<max(stop.count, 1)).reversed().first { snapshot.hasSuffix(stop.prefix($0)) } ?? 0 }.max() ?? 0
        return take(upTo: String(snapshot.dropLast(hold)))
    }

    /// The text held back, sent when the answer ends without a stop sequence.
    public mutating func finish() -> String {
        stopped ? "" : take(upTo: seen)
    }

    private mutating func take(upTo text: String) -> String {
        guard text.hasPrefix(sent), text.count > sent.count else { return "" }
        let delta = String(text.dropFirst(sent.count))
        sent = text
        return delta
    }
}
