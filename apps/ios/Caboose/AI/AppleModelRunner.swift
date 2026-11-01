import CabooseKit
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Runs Caboose AI requests (docs/ai.md § Phone) on Apple's on-device model.
///
/// A request becomes one turn of a `LanguageModelSession`: its conversation is the session's
/// transcript and its last user message the prompt. A program's tools are tools of the
/// session whose answers come from the program: when the model calls one, the request ends
/// with the call (`tool_calls`), and the session waits for the program's next request, which
/// carries the result, and continues the same turn. Results that arrive after the session
/// gave up waiting are written into a new session's transcript, which answers from them.
@MainActor
final class AppleModelRunner {
    static let modelID = "apple-foundation"
    /// How long a turn waits for the program to send the results of the tools it called.
    static let toolWait: Duration = .seconds(120)

    let model = SystemLanguageModel.default
    /// Turns waiting for tool results, by the ids of the calls they made.
    private var waiting: [String: Turn] = [:]
    /// The turn each running request is a leg of.
    private var legs: [String: Turn] = [:]

    /// Why the model cannot answer now, or nil.
    var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This iPhone cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off in Settings."
        case .unavailable(.modelNotReady): "Apple's model is still downloading."
        case .unavailable: "Apple's model is not available."
        }
    }

    /// The models to offer: none while Apple's is unavailable.
    func models() -> [AIRelay.Model] {
        guard unavailableReason == nil else { return [] }
        var capabilities = ["tools", "json"]
        var family: String?
        if #available(iOS 27.0, *) {
            if model.capabilities.contains(.vision) { capabilities.append("vision") }
            if model.capabilities.contains(.reasoning) { capabilities.append("reasoning") }
            family = model.variant.displayName
        }
        return [AIRelay.Model(id: Self.modelID, name: "Apple Foundation Model (on iPhone)", contextSize: model.contextSize, capabilities: capabilities, family: family)]
    }

    /// Runs one request, sending its events; returns when this request's part is over.
    func run(id: String, request: AIRelay.Request, send: @escaping (String) -> Void) async {
        do {
            guard unavailableReason == nil else { throw AIRelay.Failure(status: 503, code: "model_unavailable", message: unavailableReason ?? "") }
            guard request.model == Self.modelID else {
                throw AIRelay.Failure(status: 404, code: "model_not_found", message: "This iPhone has no model \(request.model).")
            }
            let conversation = try AIConversation(request)
            let ids = conversation.resultIDs
            if !ids.isEmpty, let turn = waiting[ids.first!], turn.waitingFor == ids {
                for call in ids { waiting[call] = nil }
                try await leg(of: turn, id: id) { turn.resume(id: id, send: send, results: conversation.results) }
                return
            }
            let turn = try await Turn(runner: self, request: request, conversation: conversation)
            try await leg(of: turn, id: id) { turn.start(id: id, send: send) }
        } catch let failure as AIRelay.Failure {
            send(AIRelay.error(id, failure))
        } catch is CancellationError {
        } catch {
            send(AIRelay.error(id, Self.failure(error)))
        }
    }

    private func leg(of turn: Turn, id: String, begin: () -> Void) async throws {
        legs[id] = turn
        defer { legs[id] = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ended: CheckedContinuation<Void, any Error>) in
                turn.legEnded = ended
                begin()
            }
        } onCancel: {
            // The program went away: nothing will read the rest of this turn.
            Task { @MainActor in turn.cancel() }
        }
    }

    /// A turn that sent tool calls and waits for their results.
    fileprivate func wait(_ turn: Turn, for calls: Set<String>) {
        for call in calls { waiting[call] = turn }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.toolWait)
            guard let self, turn.waitingFor == calls else { return }
            for call in calls where self.waiting[call] === turn { self.waiting[call] = nil }
            turn.cancel()
        }
    }

    /// The connection closed: every turn ends.
    func cancelAll() {
        for turn in waiting.values { turn.cancel() }
        waiting = [:]
        for turn in legs.values { turn.cancel() }
    }

    static func failure(_ error: any Error) -> AIRelay.Failure {
        if let failure = error as? AIRelay.Failure { return failure }
        if let unsupported = error as? AISchema.Unsupported { return AIRelay.Failure(status: 400, code: "unsupported_schema", message: unsupported.reason) }
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded(let exceeded):
                return AIRelay.Failure(status: 400, code: "context_length_exceeded",
                                       message: "The conversation needs \(exceeded.tokenCount) tokens; \(modelID) holds \(exceeded.contextSize), prompt and answer together.")
            case .rateLimited: return AIRelay.Failure(status: 429, code: "rate_limited", message: "Apple's model is busy; try again shortly.")
            case .unsupportedLanguageOrLocale: return AIRelay.Failure(status: 400, code: "unsupported_language", message: "Apple's model does not support this language.")
            case .timeout: return AIRelay.Failure(status: 503, code: "model_timeout", message: "Apple's model did not answer in time.")
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return AIRelay.Failure(status: 400, code: "unsupported", message: error.localizedDescription)
            default: break
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return AIRelay.Failure(status: 400, code: "context_length_exceeded", message: "The conversation is longer than \(modelID) holds, prompt and answer together.")
            case .rateLimited: return AIRelay.Failure(status: 429, code: "rate_limited", message: "Apple's model is busy; try again shortly.")
            case .unsupportedLanguageOrLocale: return AIRelay.Failure(status: 400, code: "unsupported_language", message: "Apple's model does not support this language.")
            case .assetsUnavailable: return AIRelay.Failure(status: 503, code: "model_unavailable", message: "Apple's model is not available right now.")
            case .unsupportedGuide, .decodingFailure: return AIRelay.Failure(status: 400, code: "unsupported_schema", message: error.localizedDescription)
            default: break
            }
        }
        return AIRelay.Failure(status: 500, code: "model_error", message: error.localizedDescription)
    }

    /// Whether an error means the model declined to answer, which ends the answer with
    /// `content_filter` rather than failing it.
    static func filtered(_ error: any Error) -> Bool {
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            if case .guardrailViolation = error { return true }
            if case .refusal = error { return true }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { return true }
            if case .refusal = error { return true }
        }
        return false
    }
}

/// One turn of a session: the model's answer to the prompt, across the requests that carry
/// its tool calls and their results.
@MainActor
private final class Turn {
    let runner: AppleModelRunner
    let session: LanguageModelSession
    let prompt: AIRelay.Message
    let options: GenerationOptions
    let schema: GenerationSchema?
    let maxTokens: Int?
    let stops: [String]
    /// A required tool call: the session would call tools again after their results, so the
    /// turn ends with its calls and the program's next request starts a new one.
    let forcesTools: Bool

    var legEnded: CheckedContinuation<Void, any Error>?
    private var id = ""
    private var send: (String) -> Void = { _ in }
    private var text: AIStreamText
    private var stream: Task<Void, Never>?
    /// Calls made since the last leg began, and the tools waiting on their results.
    private var calls: [(id: String, name: String, arguments: String, result: CheckedContinuation<String, any Error>)] = []
    private var flush: Task<Void, Never>?
    private(set) var waitingFor: Set<String> = []
    private var cancelled = false

    init(runner: AppleModelRunner, request: AIRelay.Request, conversation: AIConversation) async throws {
        self.runner = runner
        let model = runner.model
        // Results for calls of a turn no session waits for any more: the turn is written into
        // the transcript with them, and the model answers from them to an empty prompt.
        let continuing = !conversation.results.isEmpty
        prompt = continuing ? AIRelay.Message(role: .user, parts: []) : conversation.prompt
        maxTokens = request.maxTokens
        stops = request.stop
        forcesTools = request.toolChoice == .required || { if case .named = request.toolChoice { true } else { false } }()
        text = AIStreamText(stops: request.stop)
        if let format = request.responseFormat, let shape = format.schema {
            schema = try AISchema.generationSchema(shape, name: format.name)
        } else {
            schema = nil
        }
        options = Self.options(request)

        var instructions = conversation.instructions
        if request.responseFormat != nil, schema == nil {
            instructions += (instructions.isEmpty ? "" : "\n\n") + "Answer with one JSON object and nothing else."
        }
        let offered: [AIRelay.Tool] = switch request.toolChoice {
        case .none: []
        case .named(let name): request.tools.filter { $0.name == name }
        case .auto, .required: request.tools
        }
        var tools: [any Tool] = []
        let box = TurnBox()
        for tool in offered {
            tools.append(ClientTool(name: tool.name, description: tool.description,
                                    parameters: try AISchema.generationSchema(tool.parameters, name: "\(tool.name)_arguments"), turn: box))
        }
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: instructions.isEmpty ? [] : [.text(.init(content: instructions))],
                                                                 toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
        }
        var history = conversation
        // The answer needs room too: what the program allows it, or a quarter of the window.
        let budget = model.contextSize - min(request.maxTokens ?? model.contextSize / 4, model.contextSize / 2)
        if #available(iOS 26.4, *) {
            let fixed = entries
            let prompt = conversation.prompt.text + conversation.results.map(\.output).joined(separator: "\n")
            let used = try await history.fit(budget: budget) { conversation in
                let transcript = fixed + Self.entries(conversation.history)
                return try await model.tokenCount(for: transcript) + model.tokenCount(for: prompt)
            }
            if used > budget {
                throw AIRelay.Failure(status: 400, code: "context_length_exceeded",
                                      message: "The last message and instructions need \(used) tokens; \(AppleModelRunner.modelID) holds \(model.contextSize), prompt and answer together.")
            }
        }
        entries += Self.entries(history.history)
        if continuing {
            entries += Self.entries([.user(conversation.prompt), .assistant(text: "", toolCalls: conversation.results.map(\.call))]
                                    + conversation.results.map { .toolOutput(callId: $0.call.id, name: $0.call.name, text: $0.output) })
        }
        session = LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: entries))
        box.turn = self
    }

    static func options(_ request: AIRelay.Request) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode? = if request.temperature == 0 {
            .greedy
        } else if let k = request.topK {
            .random(top: k, seed: request.seed)
        } else if let p = request.topP, p < 1 {
            .random(probabilityThreshold: p, seed: request.seed)
        } else if let seed = request.seed {
            .random(probabilityThreshold: 1, seed: seed)
        } else {
            nil
        }
        let temperature = request.temperature == 0 ? nil : request.temperature
        if #available(iOS 27.0, *) {
            let mode: GenerationOptions.ToolCallingMode? = switch request.toolChoice {
            case .required, .named: .required
            case .none: .disallowed
            case .auto: nil
            }
            return GenerationOptions(samplingMode: sampling, temperature: temperature, maximumResponseTokens: request.maxTokens, toolCallingMode: mode)
        }
        return GenerationOptions(samplingMode: sampling, temperature: temperature, maximumResponseTokens: request.maxTokens)
    }

    static func entries(_ history: [AIConversation.Entry]) -> [Transcript.Entry] {
        history.compactMap { entry in
            switch entry {
            case .user(let message):
                return .prompt(Transcript.Prompt(segments: [.text(.init(content: message.text))]))
            case .assistant(let text, let calls):
                if calls.isEmpty { return .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))])) }
                return .toolCalls(Transcript.ToolCalls(calls.map { call in
                    Transcript.ToolCall(id: call.id, toolName: call.name, arguments: (try? GeneratedContent(json: call.arguments)) ?? GeneratedContent(kind: .structure(properties: [:], orderedKeys: [])))
                }))
            case .toolOutput(let callId, let name, let text):
                return .toolOutput(Transcript.ToolOutput(id: callId, toolName: name, segments: [.text(.init(content: text))]))
            }
        }
    }

    // MARK: Legs

    func start(id: String, send: @escaping (String) -> Void) {
        begin(id: id, send: send)
        let images = prompt.images.compactMap(Self.image)
        if images.count < prompt.images.count { end(throwing: AIRelay.Failure(status: 400, code: "invalid_image", message: "An image could not be read.")); return }
        if !images.isEmpty, !Self.sees(runner.model) {
            end(throwing: AIRelay.Failure(status: 400, code: "unsupported", message: "Apple's model on this iPhone does not take images."))
            return
        }
        let promptText = prompt.text
        stream = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let schema {
                    let responses = session.streamResponse(schema: schema, options: options) { Self.prompt(promptText, images) }
                    var last: LanguageModelSession.ResponseStream<GeneratedContent>.Snapshot?
                    for try await snapshot in responses { last = snapshot }
                    if let last, !cancelled { send(AIRelay.delta(self.id, content: last.rawContent.jsonString)); finish(last.usageCounts) }
                } else {
                    var last: LanguageModelSession.ResponseStream<String>.Snapshot?
                    for try await snapshot in session.streamResponse(options: options) { Self.prompt(promptText, images) } {
                        last = snapshot
                        let delta = text.advance(to: snapshot.content)
                        if !delta.isEmpty { self.send(AIRelay.delta(self.id, content: delta)) }
                        if text.stopped { break }
                    }
                    let rest = text.finish()
                    if !rest.isEmpty { self.send(AIRelay.delta(self.id, content: rest)) }
                    finish(last?.usageCounts)
                }
            } catch {
                if cancelled || error is CancellationError { end(throwing: CancellationError()); return }
                if AppleModelRunner.filtered(error) {
                    self.send(AIRelay.done(self.id, finish: .contentFilter, usage: .init(promptTokens: 0, completionTokens: 0)))
                    end(throwing: nil)
                    return
                }
                end(throwing: error)
            }
        }
    }

    /// The program sent the results: the waiting tools return them and the turn goes on.
    func resume(id: String, send: @escaping (String) -> Void, results: [(call: AIRelay.ToolCall, output: String)]) {
        begin(id: id, send: send)
        let outputs = Dictionary(results.map { ($0.call.id, $0.output) }, uniquingKeysWith: { first, _ in first })
        waitingFor = []
        let waiting = calls
        calls = []
        text = AIStreamText(stops: stops)
        for call in waiting { call.result.resume(returning: outputs[call.id] ?? "") }
    }

    private func begin(id: String, send: @escaping (String) -> Void) {
        self.id = id
        self.send = send
        send(AIRelay.started(id))
    }

    /// A tool of this turn was called. Calls made together go to the program together.
    func called(name: String, arguments: GeneratedContent) async throws -> String {
        let callID = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                calls.append((callID, name, arguments.jsonString, result))
                flush?.cancel()
                flush = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.sendCalls()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func sendCalls() {
        guard !calls.isEmpty, !cancelled else { return }
        send(AIRelay.delta(id, toolCalls: calls.enumerated().map { index, call in
            AIRelay.ToolCallDelta(index: index, id: call.id, name: call.name, arguments: call.arguments)
        }))
        let usage = session.transcriptUsage
        send(AIRelay.done(id, finish: .toolCalls, usage: usage))
        if forcesTools {
            end(throwing: nil)
            cancel()
            return
        }
        waitingFor = Set(calls.map(\.id))
        runner.wait(self, for: waitingFor)
        end(throwing: nil)
    }

    private func finish(_ usage: AIRelay.Usage?) {
        guard !cancelled else { return }
        let counts = usage ?? .init(promptTokens: 0, completionTokens: 0)
        let finish: AIRelay.FinishReason = if let maxTokens, counts.completionTokens >= maxTokens, !text.stopped { .length } else { .stop }
        send(AIRelay.done(id, finish: finish, usage: counts))
        end(throwing: nil)
    }

    private func end(throwing error: (any Error)?) {
        guard let ended = legEnded else { return }
        legEnded = nil
        if let error { ended.resume(throwing: error) } else { ended.resume() }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        for call in calls { call.result.resume(throwing: CancellationError()) }
        calls = []
        waitingFor = []
        stream?.cancel()
        end(throwing: CancellationError())
    }

    // MARK: Prompts

    @PromptBuilder
    static func prompt(_ text: String, _ images: [CGImage]) -> Prompt {
        text
        if #available(iOS 27.0, *) { images.map { Attachment($0) } }
    }

    static func sees(_ model: SystemLanguageModel) -> Bool {
        if #available(iOS 27.0, *) { return model.capabilities.contains(.vision) }
        return false
    }

    static func image(_ image: AIRelay.Image) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Lets the session's tools reach their turn, which is made after them.
private final class TurnBox: @unchecked Sendable {
    @MainActor weak var turn: Turn?
}

/// A program's tool: the model calls it, and the program answers.
private struct ClientTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let turn: TurnBox

    func call(arguments: GeneratedContent) async throws -> String {
        guard let turn = await turn.turn else { throw CancellationError() }
        return try await turn.called(name: name, arguments: arguments)
    }
}

private extension LanguageModelSession.ResponseStream.Snapshot {
    var usageCounts: AIRelay.Usage? {
        guard #available(iOS 27.0, *) else { return nil }
        return AIRelay.Usage(promptTokens: usage.input.totalTokenCount, completionTokens: usage.output.totalTokenCount,
                             cachedTokens: usage.input.cachedTokenCount, reasoningTokens: usage.output.reasoningTokenCount > 0 ? usage.output.reasoningTokenCount : nil)
    }
}

private extension LanguageModelSession {
    var transcriptUsage: AIRelay.Usage {
        guard #available(iOS 27.0, *) else { return .init(promptTokens: 0, completionTokens: 0) }
        return AIRelay.Usage(promptTokens: usage.input.totalTokenCount, completionTokens: usage.output.totalTokenCount, cachedTokens: usage.input.cachedTokenCount)
    }
}
