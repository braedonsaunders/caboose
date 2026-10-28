import XCTest
@testable import CabooseKit

final class AgentThreadTests: XCTestCase {
    private func entry(_ json: String) -> TranscriptEntry {
        try! JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8))
    }

    func testFoldsATurnGroupingToolsAndKeepingThePlanInPlace() {
        let thread = AgentThread(entries: [
            entry(#"{"type":"user","turn":1,"text":"Fix the tests"}"#),
            entry(#"{"type":"thought","text":"Read the failures first."}"#),
            entry(#"{"type":"plan","entries":[{"content":"Run tests","status":"in_progress"},{"content":"Fix","status":"pending"}]}"#),
            entry(#"{"type":"tool","toolId":"a","title":"Run pnpm test","kind":"execute","status":"pending","detail":"pnpm test"}"#),
            entry(#"{"type":"tool","toolId":"b","title":"Read a.ts","kind":"read","status":"pending"}"#),
            entry(#"{"type":"tool_update","toolId":"a","title":"Run pnpm test","kind":"execute","status":"completed"}"#),
            entry(#"{"type":"plan","entries":[{"content":"Run tests","status":"completed"},{"content":"Fix","status":"in_progress"}]}"#),
            entry(#"{"type":"text","text":"One test fails on a.ts."}"#),
            entry(#"{"type":"usage","used":5000,"size":200000,"cost":{"amount":0.01,"currency":"USD"}}"#),
            entry(#"{"type":"turn_end","turn":1,"stopReason":"end_turn","summary":"One test fails on a.ts."}"#),
        ])
        XCTAssertEqual(thread.turns.count, 1)
        let turn = thread.turns[0]
        XCTAssertEqual(turn.prompt, "Fix the tests")
        XCTAssertEqual(turn.items.count, 4) // thought, plan, tools, text
        guard case .plan(_, let plan) = turn.items[1] else { return XCTFail("plan stays where it first appeared") }
        XCTAssertEqual(plan.map(\.status), ["completed", "in_progress"])
        guard case .tools(_, let tools) = turn.items[2] else { return XCTFail("consecutive tools are one group") }
        XCTAssertEqual(tools.map(\.id), ["a", "b"])
        XCTAssertTrue(tools[0].isDone)
        XCTAssertEqual(tools[0].detail, "pnpm test")
        XCTAssertEqual(turn.lastText, "One test fails on a.ts.")
        XCTAssertEqual(turn.usage?.fraction ?? 0, 0.025, accuracy: 0.0001)
        XCTAssertEqual(turn.cost?.amount, 0.01)
        XCTAssertEqual(turn.outcome, .finished(stopReason: "end_turn", summary: "One test fails on a.ts."))
        XCTAssertNil(thread.activity, "a finished turn is doing nothing")
    }

    func testReportsWhatARunningTurnIsDoing() {
        var thread = AgentThread(entries: [], prompt: "Tidy Downloads")
        XCTAssertEqual(thread.turns.first?.prompt, "Tidy Downloads")
        thread.append(entry(#"{"type":"plan","entries":[{"content":"List files","status":"completed"},{"content":"Sort by type","status":"in_progress"},{"content":"Report","status":"pending"}]}"#))
        XCTAssertEqual(thread.activity, "Sort by type")
        XCTAssertEqual(thread.progress?.done, 1)
        XCTAssertEqual(thread.progress?.total, 3)
        thread.append(entry(#"{"type":"tool","toolId":"m","title":"Move 12 PDFs","kind":"move","status":"in_progress"}"#))
        XCTAssertEqual(thread.activity, "Move 12 PDFs")
        thread.append(entry(#"{"type":"tool_update","toolId":"m","status":"failed"}"#))
        XCTAssertEqual(thread.activity, "Sort by type")
        XCTAssertTrue(thread.turns[0].tools[0].isFailed)
    }

    func testRepliesStartNewTurnsAndTheOwnersTurnIsNotDuplicated() {
        var thread = AgentThread(entries: [
            entry(#"{"type":"user","turn":1,"text":"hi"}"#),
            entry(#"{"type":"turn_end","turn":1,"stopReason":"end_turn","summary":"Hello."}"#),
        ])
        thread.begin(turn: 2, prompt: "and then?")
        thread.append(entry(#"{"type":"user","turn":2,"text":"and then?"}"#))
        thread.append(entry(#"{"type":"text","text":"Then this."}"#))
        XCTAssertEqual(thread.turns.map(\.number), [1, 2])
        XCTAssertEqual(thread.turns[1].lastText, "Then this.")
        XCTAssertNil(thread.turns[1].outcome)
    }

    func testPermissionsAreMarkedWithTheirAnswers() {
        let request = "6f1c2a8e-1d2b-4c3d-8e4f-5a6b7c8d9e0f"
        var thread = AgentThread(entries: [
            entry(#"{"type":"user","turn":1,"text":"delete it"}"#),
            entry(#"{"type":"permission","requestId":null,"tool":"Read","summary":"a.txt","auto":true}"#),
            entry(#"{"type":"permission","requestId":"\#(request)","tool":"Delete","summary":"a.txt","auto":false}"#),
        ])
        guard case .permission(_, let automatic) = thread.turns[0].items[0], case .permission(_, let waiting) = thread.turns[0].items[1] else {
            return XCTFail("two permissions")
        }
        XCTAssertEqual(automatic.allowed, true)
        XCTAssertNil(waiting.allowed)
        thread.append(entry(#"{"type":"permission_resolved","requestId":"\#(request)","allow":false,"message":"keep it"}"#))
        guard case .permission(_, let answered) = thread.turns[0].items[1] else { return XCTFail() }
        XCTAssertEqual(answered.allowed, false)
        XCTAssertEqual(answered.message, "keep it")
    }

    func testSignInAndFailureEndTurns() {
        let thread = AgentThread(entries: [
            entry(#"{"type":"user","turn":1,"text":"a"}"#),
            entry(#"{"type":"turn_failed","turn":1,"message":"exited"}"#),
            entry(#"{"type":"user","turn":2,"text":"b"}"#),
            entry(#"{"type":"auth_required","turn":2,"message":"log in"}"#),
        ])
        XCTAssertEqual(thread.turns[0].outcome, .failed("exited"))
        XCTAssertEqual(thread.turns[1].outcome, .signInRequired("log in"))
    }

    func testATruncatedTranscriptStillFoldsIntoTheCurrentTurn() {
        let thread = AgentThread(entries: [entry(#"{"type":"text","text":"mid-turn"}"#)], prompt: "long task", truncated: true)
        XCTAssertTrue(thread.truncated)
        XCTAssertEqual(thread.turns.first?.prompt, "long task")
        XCTAssertEqual(thread.turns.first?.lastText, "mid-turn")
    }
}

final class ModelProviderTests: XCTestCase {
    func testOpenRouterSetsProviderKeyAndModel() {
        let env = ModelProvider.openRouter.environment(key: "  sk-or-v1-0123456789abcdef \n", model: "anthropic/claude-sonnet")
        XCTAssertEqual(env, ["GOOSE_PROVIDER": "openrouter", "GOOSE_DISABLE_KEYRING": "1",
                             "OPENROUTER_API_KEY": "sk-or-v1-0123456789abcdef", "GOOSE_MODEL": "anthropic/claude-sonnet"])
        XCTAssertEqual(ModelProvider.anthropic.environment(key: "sk-ant-0123456789abcdefghij", model: "ignored"),
                       ["ANTHROPIC_API_KEY": "sk-ant-0123456789abcdefghij"])
    }

    func testKeysAreOneLongWord() {
        XCTAssertTrue(ModelProvider.plausible(key: "sk-or-v1-0123456789abcdef"))
        XCTAssertFalse(ModelProvider.plausible(key: "short"))
        XCTAssertFalse(ModelProvider.plausible(key: "sk-or-v1-0123456789 abcdef"))
    }

    func testConnectedProviderIsReadFromTheAgentsEnvironmentNames() {
        XCTAssertEqual(ModelProvider.connected(agent: "goose", environment: ["GOOSE_MODEL", "OPENROUTER_API_KEY"]), .openRouter)
        XCTAssertNil(ModelProvider.connected(agent: "goose", environment: []))
        XCTAssertNil(ModelProvider.connected(agent: "claude-acp", environment: ["OPENROUTER_API_KEY"]))
    }

    func testRanksToolModelsWithLeadingVendorsFirst() throws {
        let json = #"""
        {"data":[
          {"id":"some/old","name":"Old","created":1,"supported_parameters":["tools"]},
          {"id":"anthropic/claude-a","name":"Claude A","created":10,"supported_parameters":["tools"],"pricing":{"prompt":"0.000003","completion":"0.000015"}},
          {"id":"anthropic/claude-b","name":"Claude B","created":20,"supported_parameters":["tools"]},
          {"id":"openai/gpt","name":"GPT","created":15,"supported_parameters":["tools","temperature"]},
          {"id":"some/new","name":"New","created":30,"supported_parameters":["tools"]},
          {"id":"some/chat-only","name":"Chat","created":40,"supported_parameters":["temperature"]}
        ]}
        """#
        let models = try OpenRouterModel.decodeList(Data(json.utf8))
        XCTAssertEqual(OpenRouterModel.ranked(models).map(\.id), ["anthropic/claude-b", "openai/gpt", "some/new", "anthropic/claude-a", "some/old"])
        let price = try XCTUnwrap(models.first { $0.id == "anthropic/claude-a" }?.pricePerMillion)
        XCTAssertEqual(price.input, 3, accuracy: 0.0001)
        XCTAssertEqual(price.output, 15, accuracy: 0.0001)
    }
}
