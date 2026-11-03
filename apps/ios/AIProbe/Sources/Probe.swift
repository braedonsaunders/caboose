import Foundation
import FoundationModels
import UIKit

/// Measures Apple's on-device language model on the phone it runs on. Each result is one JSON
/// object printed as a line starting with `PROBE ` (read by `scripts/check-on-device-ai.sh`
/// through `devicectl --console`) and appended to `Documents/probe.jsonl`.
@MainActor
final class Probe {
    private let sink: (String) -> Void
    private let file: URL
    private let model = SystemLanguageModel.default

    init(sink: @escaping (String) -> Void) {
        self.sink = sink
        file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.jsonl")
        try? FileManager.default.removeItem(at: file)
    }

    func emit(_ name: String, _ fields: [String: Any]) {
        var record = fields
        record["probe"] = name
        record["thermal"] = Self.thermal()
        record["footprintMB"] = Self.footprintMB()
        UIDevice.current.isBatteryMonitoringEnabled = true
        record["battery"] = UIDevice.current.batteryLevel
        record["charging"] = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("PROBE \(line)")
        fflush(stdout)
        sink(line)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: file)
        }
    }

    func run(only: Set<String>?, mlx: [String] = []) async {
        let probes: [(String, () async throws -> Void)] = [
            ("info", info), ("tokens", tokens), ("throughput", throughput), ("prefill", prefill),
            ("context", context), ("session", sessionGrowth), ("guided", guided), ("tools", tools), ("toolReplay", toolReplay),
            ("vision", vision), ("reasoning", reasoning), ("concurrency", concurrency), ("pcc", pcc),
        ]
        emit("start", ["device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
                       "physicalMemoryMB": ProcessInfo.processInfo.physicalMemory / 1_048_576,
                       "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
        for (name, probe) in probes where only?.contains(name) ?? true {
            let started = Date()
            do { try await probe() } catch { emit(name, ["error": Self.describe(error)]) }
            emit("\(name).done", ["seconds": Date().timeIntervalSince(started)])
        }
        if !mlx.isEmpty { await MLXProbe(probe: self).run(mlx) }
        emit("finished", [:])
    }

    // MARK: Probes

    func info() async throws {
        var fields: [String: Any] = ["availability": String(describing: model.availability)]
        fields["contextSize"] = model.contextSize
        fields["variant"] = model.variant.displayName
        fields["isCore3"] = model.variant == .core3
        fields["isCoreAdvanced3"] = model.variant == .coreAdvanced3
        fields["capabilities"] = Self.capabilities(model.capabilities)
        fields["languages"] = model.supportedLanguages.count
        fields["supportsCurrentLocale"] = model.supportsLocale()
        let tagging = SystemLanguageModel(useCase: .contentTagging)
        fields["contentTaggingAvailability"] = String(describing: tagging.availability)
        fields["contentTaggingContextSize"] = tagging.contextSize
        fields["contentTaggingVariant"] = tagging.variant.displayName
        fields["availableMemoryMB"] = os_proc_available_memory() / 1_048_576
        emit("info", fields)
    }

    func tokens() async throws {
        for (label, text) in [("english", Self.corpus(sentences: 40)), ("code", Self.code), ("json", Self.json)] {
            let count = try await model.tokenCount(for: text)
            emit("tokens", ["kind": label, "characters": text.count, "tokens": count,
                            "charactersPerToken": Double(text.count) / Double(max(count, 1))])
        }
        emit("tokens", ["kind": "instructions", "tokens": try await model.tokenCount(for: Instructions("You are a helpful assistant."))])
        emit("tokens", ["kind": "emptyTools", "tokens": try await model.tokenCount(for: [any Tool]())])
        emit("tokens", ["kind": "weatherTool", "tokens": try await model.tokenCount(for: [WeatherTool()] as [any Tool])])
    }

    /// Output speed: a long answer, streamed, three times (the first is cold).
    func throughput() async throws {
        for run in 1...3 {
            let session = LanguageModelSession(model: model)
            if run == 3 { session.prewarm(); try await Task.sleep(for: .seconds(2)) }
            try await stream(session, prompt: "Write a detailed essay of about 700 words about the history of railways in Canada.",
                             options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 900), label: "throughput", extra: ["run": run, "prewarmed": run == 3])
        }
        let session = LanguageModelSession(model: model)
        try await stream(session, prompt: "Write a detailed essay of about 700 words about the history of railways in Canada.",
                         options: GenerationOptions(samplingMode: .random(top: 40, seed: 1), temperature: 0.8, maximumResponseTokens: 900), label: "throughput", extra: ["run": 4, "sampling": "topK40"])
    }

    /// Input speed: time to the first token for prompts of growing size.
    func prefill() async throws {
        let limit = model.contextSize
        var targets = [256, 1024, 2048, 3500]
        var size = 8192
        while size < limit - 600 { targets.append(size); size *= 2 }
        targets.append(limit - 400)
        for target in Set(targets).sorted() where target < limit - 200 {
            let text = try await prompt(tokens: target)
            let session = LanguageModelSession(model: model)
            try await stream(session, prompt: text + "\n\nIn one short sentence, what is this text about?",
                             options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40), label: "prefill", extra: ["targetTokens": target])
        }
    }

    /// The real window: a prompt just inside and just outside `contextSize`, and how output counts.
    func context() async throws {
        let limit = model.contextSize
        for (target, maxOut) in [(limit - 150, 100), (limit - 60, 200), (limit + 50, 50), (limit * 2, 50)] {
            let text = try await prompt(tokens: target)
            let session = LanguageModelSession(model: model)
            var fields: [String: Any] = ["promptTokens": try await model.tokenCount(for: text), "maximumResponseTokens": maxOut, "contextSize": limit]
            let started = Date()
            do {
                let response = try await session.respond(to: text + "\nSummarize the above in one sentence.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxOut))
                fields["ok"] = true
                fields["usage"] = Self.usage(response.usage)
                fields["output"] = String(response.content.prefix(120))
            } catch {
                fields["ok"] = false
                fields["error"] = Self.describe(error)
            }
            fields["seconds"] = Date().timeIntervalSince(started)
            emit("context", fields)
        }
    }

    /// A conversation in one session grows until the transcript no longer fits.
    func sessionGrowth() async throws {
        let session = LanguageModelSession(model: model, instructions: "Answer in two sentences.")
        for turn in 1...60 {
            let chunk = Self.corpus(sentences: 25, offset: turn * 100)
            let started = Date()
            do {
                let response = try await session.respond(to: chunk + "\nWhat is the largest number above?", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 60))
                let transcriptTokens = try await model.tokenCount(for: session.transcript)
                emit("session", ["turn": turn, "usage": Self.usage(response.usage), "sessionUsage": Self.usage(session.usage), "transcriptTokens": transcriptTokens,
                                 "entries": session.transcript.count, "seconds": Date().timeIntervalSince(started)])
            } catch {
                emit("session", ["turn": turn, "error": Self.describe(error), "transcriptTokens": (try? await model.tokenCount(for: session.transcript)) ?? -1])
                return
            }
        }
    }

    /// Guided generation from a schema built at run time, as an OpenAI `json_schema` would be.
    func guided() async throws {
        let person = DynamicGenerationSchema(name: "Person", properties: [
            .init(name: "name", schema: .init(type: String.self)),
            .init(name: "age", schema: .init(type: Int.self)),
            .init(name: "city", schema: .init(type: String.self)),
            .init(name: "hobbies", schema: .init(arrayOf: .init(type: String.self), maximumElements: 5)),
        ])
        let schema = try GenerationSchema(root: person, dependencies: [])
        let session = LanguageModelSession(model: model)
        let started = Date()
        let response = try await session.respond(to: "Maria is 34, lives in Lisbon and likes surfing, chess and baking bread. Extract her details.", schema: schema,
                                                 options: GenerationOptions(samplingMode: .greedy))
        emit("guided", ["json": response.content.jsonString, "usage": Self.usage(response.usage), "seconds": Date().timeIntervalSince(started),
                        "schemaTokens": try await model.tokenCount(for: schema)])
    }

    /// Tool calling with a schema built at run time, and a tool whose answer arrives seconds
    /// later (as a client running the tool would answer).
    func tools() async throws {
        let tool = WeatherTool(delay: .seconds(3))
        let session = LanguageModelSession(model: model, tools: [tool], instructions: "Use tools to answer questions about the weather.")
        let started = Date()
        let response = try await session.respond(to: "What's the weather in Toronto right now?", options: GenerationOptions(samplingMode: .greedy))
        var calls: [[String: Any]] = []
        for entry in session.transcript {
            if case .toolCalls(let toolCalls) = entry {
                for call in toolCalls { calls.append(["id": call.id, "name": call.toolName, "arguments": call.arguments.jsonString]) }
            }
        }
        emit("tools", ["answer": response.content, "calls": calls, "seconds": Date().timeIntervalSince(started), "usage": Self.usage(response.usage),
                       "entries": session.transcript.map { Self.kind($0) }])
        // Required mode: does the session stop calling tools once it has their results?
        let counter = CallCounter()
        let required = LanguageModelSession(model: model, tools: [WeatherTool(counter: counter), ClockTool(counter: counter)])
        let second = Date()
        let task = Task { try await required.respond(to: "Is it raining in Paris and what time is it there?", options: GenerationOptions(samplingMode: .greedy, toolCallingMode: .required)) }
        let timer = Task { try await Task.sleep(for: .seconds(30)); task.cancel() }
        var fields: [String: Any] = [:]
        do { fields["answer"] = try await task.value.content } catch { fields["error"] = Self.describe(error) }
        timer.cancel()
        emit("tools", ["mode": "required", "toolCalls": await counter.count, "seconds": Date().timeIntervalSince(second), "entries": required.transcript.map { Self.kind($0) }].merging(fields) { a, _ in a })
    }

    /// Tool results the program sends in a later request, written into a new session's
    /// transcript: which prompt makes the model answer from them.
    func toolReplay() async throws {
        let call = Transcript.ToolCall(id: "call_1", toolName: "get_weather", arguments: try GeneratedContent(json: #"{"city":"Toronto"}"#))
        let base: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: "Use tools to answer questions about the weather."))], toolDefinitions: [Transcript.ToolDefinition(tool: WeatherTool())])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "What's the weather in Toronto right now?"))])),
            .toolCalls(Transcript.ToolCalls([call])),
            .toolOutput(Transcript.ToolOutput(id: "call_1", toolName: "get_weather", segments: [.text(.init(content: #"{"city":"Toronto","temperature_c":-4,"conditions":"heavy snow"}"#))])),
        ]
        for (label, prompt) in [("empty", ""), ("continue", "Answer using the tool results above."), ("repeat", "What's the weather in Toronto right now?")] {
            let session = LanguageModelSession(model: model, tools: [WeatherTool()], transcript: Transcript(entries: base))
            let started = Date()
            do {
                let response = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy))
                emit("toolReplay", ["prompt": label, "answer": response.content, "seconds": Date().timeIntervalSince(started), "entries": session.transcript.map { Self.kind($0) }])
            } catch {
                emit("toolReplay", ["prompt": label, "error": Self.describe(error)])
            }
        }
    }

    func vision() async throws {
        guard model.capabilities.contains(.vision) else { emit("vision", ["supported": false]); return }
        let image = Self.sign(text: "TRACK 42\nCABOOSE")
        let session = LanguageModelSession(model: model)
        let started = Date()
        let response = try await session.respond(options: GenerationOptions(samplingMode: .greedy)) {
            "Read the text in this image exactly, then describe its colours."
            Attachment(image)
        }
        emit("vision", ["supported": true, "answer": response.content, "usage": Self.usage(response.usage), "seconds": Date().timeIntervalSince(started),
                        "imageTokens": (try? await model.tokenCount(for: Attachment(image))) ?? -1])
    }

    func reasoning() async throws {
        guard model.capabilities.contains(.reasoning) else { emit("reasoning", ["supported": false]); return }
        for level in [ContextOptions.ReasoningLevel.light, .deep] {
            let session = LanguageModelSession(model: model)
            let started = Date()
            let response = try await session.respond(to: "A train leaves at 14:35 and the trip takes 3 hours 50 minutes. When does it arrive? Answer with the time only.",
                                                     options: GenerationOptions(samplingMode: .greedy), contextOptions: ContextOptions(reasoningLevel: level))
            emit("reasoning", ["supported": true, "level": String(describing: level), "answer": response.content, "usage": Self.usage(response.usage), "seconds": Date().timeIntervalSince(started)])
        }
    }

    /// Two sessions at once: whether the framework runs them together or one after the other.
    func concurrency() async throws {
        let started = Date()
        async let first = timed { try await LanguageModelSession(model: self.model).respond(to: "List twenty animals, one per line.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)) }
        async let second = timed { try await LanguageModelSession(model: self.model).respond(to: "List twenty countries, one per line.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)) }
        let results = try await [first, second]
        emit("concurrency", ["wall": Date().timeIntervalSince(started), "each": results.map { ["seconds": $0.seconds, "usage": Self.usage($0.usage)] }])
        // The same session cannot take a second request while responding.
        let shared = LanguageModelSession(model: model)
        async let one = try? shared.respond(to: "Count to ten.")
        try await Task.sleep(for: .milliseconds(100))
        var fields: [String: Any] = [:]
        do { _ = try await shared.respond(to: "Count to five."); fields["secondAccepted"] = true } catch { fields["secondError"] = Self.describe(error) }
        _ = await one
        emit("concurrency", fields)
    }

    func pcc() async throws {
        let cloud = PrivateCloudComputeLanguageModel()
        var fields: [String: Any] = ["availability": String(describing: cloud.availability), "capabilities": Self.capabilities(cloud.capabilities)]
        if let size = try? await cloud.contextSize { fields["contextSize"] = size }
        let quota = cloud.quotaUsage
        fields["quota"] = String(describing: quota.status)
        emit("pcc", fields)
        guard cloud.isAvailable else { return }
        let started = Date()
        let answer = try await LanguageModelSession(model: cloud).respond(to: "In two sentences, what is Private Cloud Compute?", options: GenerationOptions(samplingMode: .greedy))
        emit("pcc", ["answer": answer.content, "seconds": Date().timeIntervalSince(started), "usage": Self.usage(answer.usage)])
        let session = LanguageModelSession(model: cloud)
        try await stream(session, prompt: "Write a detailed essay of about 700 words about the history of railways in Canada.",
                         options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 900), label: "pcc.throughput", extra: [:])
        emit("pcc", ["quotaAfter": String(describing: cloud.quotaUsage.status)])
    }

    // MARK: Helpers

    private func timed(_ work: @escaping () async throws -> LanguageModelSession.Response<String>) async throws -> (seconds: Double, usage: LanguageModelSession.Usage) {
        let started = Date()
        let response = try await work()
        return (Date().timeIntervalSince(started), response.usage)
    }

    private func stream(_ session: LanguageModelSession, prompt: String, options: GenerationOptions, label: String, extra: [String: Any]) async throws {
        let started = Date()
        var first: Date?
        var snapshots = 0
        var last: LanguageModelSession.ResponseStream<String>.Snapshot?
        var gaps: [Double] = []
        var previous = started
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let now = Date()
            if first == nil, !snapshot.content.isEmpty { first = now }
            if first != nil { gaps.append(now.timeIntervalSince(previous)) }
            previous = now
            snapshots += 1
            last = snapshot
        }
        let end = Date()
        var fields = extra
        fields["ttft"] = first.map { $0.timeIntervalSince(started) } ?? -1
        fields["total"] = end.timeIntervalSince(started)
        fields["snapshots"] = snapshots
        if let last {
            fields["usage"] = Self.usage(last.usage)
            let out = last.usage.output.totalTokenCount
            if let first, end > first { fields["decodeTokensPerSecond"] = Double(max(out - 1, 0)) / end.timeIntervalSince(first) }
            if let first { fields["prefillTokensPerSecond"] = Double(last.usage.input.totalTokenCount) / first.timeIntervalSince(started) }
            fields["characters"] = last.content.count
            fields["tail"] = String(last.content.suffix(80))
        }
        let sorted = gaps.sorted()
        if !sorted.isEmpty { fields["gapP50ms"] = sorted[sorted.count / 2] * 1000; fields["gapP95ms"] = sorted[sorted.count * 95 / 100] * 1000 }
        emit(label, fields)
    }

    /// Text of about `tokens` tokens by the model's own count.
    private func prompt(tokens target: Int) async throws -> String {
        var sentences = max(target / 20, 1)
        var text = Self.corpus(sentences: sentences)
        for _ in 0..<6 {
            let count = try await model.tokenCount(for: text)
            if abs(count - target) <= max(target / 100, 8) { break }
            sentences = max(Int(Double(sentences) * Double(target) / Double(count)), 1)
            text = Self.corpus(sentences: sentences)
        }
        return text
    }

    static func corpus(sentences: Int, offset: Int = 0) -> String {
        let places = ["Halifax", "Moncton", "Montreal", "Ottawa", "Toronto", "Winnipeg", "Regina", "Calgary", "Kamloops", "Vancouver"]
        let cargo = ["grain", "lumber", "coal", "passengers", "mail", "potash", "steel", "cars", "fish", "paper"]
        return (0..<sentences).map { index in
            let i = index + offset
            return "Train \(i) left \(places[i % 10]) for \(places[(i * 7 + 3) % 10]) at \(i % 24):\(String(format: "%02d", i * 13 % 60)) carrying \(i * 37 % 900 + 10) tonnes of \(cargo[(i * 3) % 10])."
        }.joined(separator: " ")
    }

    static let code = """
    import json, sys
    def load(path):
        with open(path) as f:
            return json.load(f)
    for name in sys.argv[1:]:
        data = load(name)
        total = sum(item["price"] * item.get("count", 1) for item in data["items"])
        print(f"{name}: {total:.2f}")
    """

    static let json = #"{"items":[{"id":1,"name":"widget","price":2.5,"count":4},{"id":2,"name":"gadget","price":10,"count":1},{"id":3,"name":"doohickey","price":0.75,"count":12}],"currency":"CAD"}"#

    static func sign(text: String) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (text as NSString).draw(in: CGRect(x: 0, y: 50, width: 512, height: 200), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white, .paragraphStyle: style])
        }
        return image.cgImage!
    }

    static func usage(_ usage: LanguageModelSession.Usage) -> [String: Int] {
        ["input": usage.input.totalTokenCount, "cached": usage.input.cachedTokenCount, "output": usage.output.totalTokenCount, "reasoning": usage.output.reasoningTokenCount]
    }

    static func capabilities(_ capabilities: LanguageModelCapabilities) -> [String] {
        [("vision", LanguageModelCapabilities.Capability.vision), ("guidedGeneration", .guidedGeneration), ("reasoning", .reasoning), ("toolCalling", .toolCalling)]
            .filter { capabilities.contains($0.1) }.map(\.0)
    }

    static func kind(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .response: "response"
        case .reasoning: "reasoning"
        @unknown default: "unknown"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LanguageModelError, case .contextSizeExceeded(let exceeded) = error {
            return "contextSizeExceeded(contextSize: \(exceeded.contextSize), tokenCount: \(exceeded.tokenCount))"
        }
        return String(describing: error).prefix(600).description
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// A weather tool whose arguments come from a schema built at run time.
actor CallCounter {
    var count = 0
    func add() { count += 1 }
}

struct WeatherTool: Tool {
    var delay: Duration = .zero
    var counter: CallCounter?
    let name = "get_weather"
    let description = "Get the current weather for a city."
    var parameters: GenerationSchema {
        (try? GenerationSchema(root: DynamicGenerationSchema(name: "get_weather_arguments", properties: [
            .init(name: "city", description: "The city name", schema: .init(type: String.self)),
        ]), dependencies: [])) ?? GenerationSchema(type: GeneratedContent.self, properties: [])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        await counter?.add()
        if delay > .zero { try await Task.sleep(for: delay) }
        let city = (try? arguments.value(String.self, forProperty: "city")) ?? "unknown"
        return "{\"city\":\"\(city)\",\"temperature_c\":12,\"conditions\":\"light rain\"}"
    }
}

struct ClockTool: Tool {
    var counter: CallCounter?
    let name = "get_time"
    let description = "Get the current local time in a city."
    var parameters: GenerationSchema {
        (try? GenerationSchema(root: DynamicGenerationSchema(name: "get_time_arguments", properties: [
            .init(name: "city", schema: .init(type: String.self)),
        ]), dependencies: [])) ?? GenerationSchema(type: GeneratedContent.self, properties: [])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        await counter?.add()
        return "{\"time\":\"21:14\"}"
    }
}
