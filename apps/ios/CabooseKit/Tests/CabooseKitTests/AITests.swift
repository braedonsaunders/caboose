import Foundation
import Testing
@testable import CabooseKit
#if canImport(FoundationModels)
import FoundationModels
#endif

private let id = "0123456789abcdef0123456789abcdef"

@Suite struct AIJSONTests {
    @Test func keepsKeyOrderAndRoundTrips() throws {
        let text = #"{"z":1,"a":[true,false,null,-2.5e3],"m":{"k":"v\n\u00e9\ud83d\ude00\"q\\"}}"#
        let json = try AIJSON.parse(text)
        #expect(json.pairs?.map(\.key) == ["z", "a", "m"])
        #expect(json["m"]?["k"]?.string == "v\né😀\"q\\")
        #expect(json["a"]?.array?[3].number == -2500)
        #expect(try AIJSON.parse(json.text) == json)
        #expect(json["z"]?.integer == 1)
    }

    @Test func refusesWhatIsNotJSON() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"\u{01}\"", "1 2", "{\"a\":1,}", "\"\\x\"", "NaN"] {
            #expect(throws: AIJSON.ParseError.self, "\(bad)") { try AIJSON.parse(bad) }
        }
        #expect(throws: AIJSON.ParseError.self) { try AIJSON.parse(String(repeating: "[", count: 100) + String(repeating: "]", count: 100), depth: 64) }
    }

    @Test func takesLongStringsWhole() throws {
        let base64 = String(repeating: "QUJD", count: 250_000)
        #expect(try AIJSON.parse("\"\(base64)\"").string?.count == 1_000_000)
    }
}

@Suite struct AIRelayTests {
    @Test func readsARequest() throws {
        let text = """
        {"type":"request","id":"\(id)","request":{"model":"apple-foundation","temperature":0.2,"maxTokens":64,"stop":["END"],"toolChoice":{"name":"look"},
         "messages":[{"role":"system","content":"Be brief."},{"role":"user","content":[{"type":"text","text":"What is this?"},{"type":"image","mediaType":"image/png","data":"iVBORw=="}]}],
         "tools":[{"name":"look","description":"Looks","parameters":{"type":"object","properties":{"x":{"type":"integer"}}}}],
         "responseFormat":{"type":"json","name":"answer","schema":{"type":"object"}}}}
        """
        guard case .request(let rid, let request) = try AIRelay.incoming(text) else { Issue.record("not a request"); return }
        #expect(rid == id)
        #expect(request.model == "apple-foundation")
        #expect(request.messages[1].text == "What is this?")
        #expect(request.messages[1].images.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(request.toolChoice == .named("look"))
        #expect(request.tools[0].parameters["properties"]?["x"]?["type"]?.string == "integer")
        #expect(request.responseFormat == AIRelay.ResponseFormat(name: "answer", schema: .object([("type", .string("object"))])))
        #expect(request.stop == ["END"])
        #expect((request.temperature, request.maxTokens) == (0.2, 64))
        #expect(try AIRelay.incoming(#"{"type":"cancel","id":"\#(id)"}"#) == .cancel(id: id))
    }

    @Test func refusesWithTheRequestID() {
        #expect(throws: AIRelay.InvalidMessage(id: nil, reason: "no request id")) { try AIRelay.incoming(#"{"type":"cancel","id":"x"}"#) }
        #expect(throws: AIRelay.InvalidMessage(id: id, reason: "a request needs a model and messages")) {
            try AIRelay.incoming(#"{"type":"request","id":"\#(id)","request":{"model":"m","messages":[]}}"#)
        }
    }

    @Test func writesEvents() throws {
        #expect(AIRelay.started(id) == #"{"type":"started","id":"\#(id)"}"#)
        #expect(AIRelay.delta(id, content: "Hi\n") == #"{"type":"delta","id":"\#(id)","content":"Hi\n"}"#)
        #expect(AIRelay.delta(id, toolCalls: [.init(index: 0, id: "call_1", name: "look", arguments: "{}")])
                == #"{"type":"delta","id":"\#(id)","toolCalls":[{"index":0,"id":"call_1","name":"look","arguments":"{}"}]}"#)
        #expect(AIRelay.done(id, finish: .toolCalls, usage: .init(promptTokens: 9, completionTokens: 3, cachedTokens: 4))
                == #"{"type":"done","id":"\#(id)","finishReason":"tool_calls","usage":{"promptTokens":9,"completionTokens":3,"cachedTokens":4}}"#)
        #expect(AIRelay.error(id, .init(status: 400, code: "context_length_exceeded", message: "too long"))
                == #"{"type":"error","id":"\#(id)","status":400,"code":"context_length_exceeded","message":"too long"}"#)
        let hello = try AIJSON.parse(AIRelay.hello([.init(id: "apple-foundation", name: "Apple", contextSize: 4096, capabilities: ["tools"], family: "Core")]))
        #expect(hello["models"]?.array?.first?["contextSize"]?.integer == 4096)
    }
}

@Suite struct AIDecisionTests {
    @Test func readsDecisionsAndTheComputersModels() throws {
        #expect(try AIRelay.incoming(#"{"type":"decide","id":"\#(id)","request":{"model":"caboose-decide","prompt":"Task: x\nA B\nNext:","choices":2}}"#)
                == .decide(id: id, AIRelay.DecideRequest(model: "caboose-decide", prompt: "Task: x\nA B\nNext:", choices: 2)))
        let sha = String(repeating: "f", count: 64)
        for bad in [#"{"type":"decide","id":"\#(id)","request":{"model":"m","prompt":"x","choices":33}}"#,
                    #"{"type":"decide","id":"\#(id)","request":{"model":"m","prompt":"","choices":2}}"#,
                    #"{"type":"decide","id":"\#(id)","request":{"model":"m","prompt":"x","choices":2.5}}"#,
                    #"{"type":"models","id":"\#(id)","release":"r5.14","models":[{"name":"m","files":[{"path":"../x","size":1,"sha256":"\#(sha)"}]}]}"#] {
            #expect(throws: AIRelay.InvalidMessage.self, "\(bad)") { try AIRelay.incoming(bad) }
        }
        #expect(try AIRelay.incoming(#"{"type":"models","id":"\#(id)","release":"r5.14","models":[{"name":"caboose-decide","files":[{"path":"model.safetensors","size":3,"sha256":"\#(sha)"}]}]}"#)
                == .models(id: id, AIRelay.ComputerModels(release: "r5.14", models: [.init(name: "caboose-decide", files: [.init(path: "model.safetensors", size: 3, sha256: sha)])])))
        #expect(try AIRelay.incoming(#"{"type":"read","id":"\#(id)","error":"no such model file"}"#) == .unanswered(id: id, reason: "no such model file"))
        let chunk = try #require(AIRelay.chunk(Data(id.utf8) + Data([1, 2, 3])))
        #expect(chunk.id == id && [UInt8](chunk.data) == [1, 2, 3])
        #expect(AIRelay.chunk(Data("XYZ".utf8)) == nil)
    }

    @Test func writesDecisionsAndModelRequests() throws {
        #expect(try AIJSON.parse(AIRelay.decision(id, choice: 2, elapsedMs: 41.25)) == AIJSON.parse(#"{"type":"decision","id":"\#(id)","choice":2,"elapsedMs":41.25}"#))
        #expect(try AIJSON.parse(AIRelay.read(id, model: "caboose-decide", path: "model.safetensors", offset: 5, length: 10_000_000))
                == AIJSON.parse(#"{"type":"read","id":"\#(id)","name":"caboose-decide","path":"model.safetensors","offset":5,"length":1048576}"#))
        let hello = try AIJSON.parse(AIRelay.hello([.init(id: "caboose-decide", name: "Caboose decisions", contextSize: 2048, capabilities: [], decision: true, ownedBy: "caboose")]))
        #expect(hello["models"]?.array?.first?["type"]?.string == "decision")
        #expect(AIRelay.safeName("tokenizer.json") && !AIRelay.safeName(".complete") && !AIRelay.safeName("a/b"))
    }
}

private func message(_ role: AIRelay.Role, _ text: String, calls: [AIRelay.ToolCall] = [], callId: String? = nil) -> AIRelay.Message {
    AIRelay.Message(role: role, parts: text.isEmpty ? [] : [.text(text)], toolCalls: calls, toolCallId: callId)
}

@Suite struct AIConversationTests {
    @Test func splitsTheConversationAtTheLastUserMessage() throws {
        let look = AIRelay.ToolCall(id: "call_1", name: "look", arguments: #"{"x":1}"#)
        let again = AIRelay.ToolCall(id: "call_2", name: "look", arguments: #"{"x":2}"#)
        let conversation = try AIConversation(AIRelay.Request(model: "m", messages: [
            message(.system, "Be brief."), message(.user, "Hi"), message(.assistant, "Hello"),
            message(.system, "Use tools."), message(.user, "Look twice"),
            message(.assistant, "", calls: [look, again]), message(.tool, "a cat", callId: "call_1"), message(.tool, "a dog", callId: "call_2"),
        ]))
        #expect(conversation.instructions == "Be brief.\n\nUse tools.")
        #expect(conversation.history == [.user(message(.user, "Hi")), .assistant(text: "Hello", toolCalls: [])])
        #expect(conversation.prompt.text == "Look twice")
        #expect(conversation.results.map(\.output) == ["a cat", "a dog"])
        #expect(conversation.resultIDs == ["call_1", "call_2"])
    }

    @Test func refusesConversationsATurnCannotStartFrom() {
        #expect(throws: AIRelay.Failure.self) { try AIConversation(AIRelay.Request(model: "m", messages: [message(.system, "x")])) }
        #expect(throws: AIRelay.Failure.self) { try AIConversation(AIRelay.Request(model: "m", messages: [message(.user, "x"), message(.assistant, "prefilled")])) }
        let call = AIRelay.ToolCall(id: "c", name: "t", arguments: "{}")
        #expect(throws: AIRelay.Failure.self) { try AIConversation(AIRelay.Request(model: "m", messages: [message(.user, "x"), message(.assistant, "", calls: [call])])) }
    }

    @Test func dropsTheOldestTurnsToFit() async throws {
        var conversation = try AIConversation(AIRelay.Request(model: "m", messages: [
            message(.user, "one"), message(.assistant, "", calls: [.init(id: "a", name: "t", arguments: "{}")]), message(.tool, "r", callId: "a"), message(.assistant, "1"),
            message(.user, "two"), message(.assistant, "2"), message(.user, "three"),
        ]))
        let tokens = try await conversation.fit(budget: 35) { 10 * ($0.history.count + 1) }
        #expect(conversation.history == [.user(message(.user, "two")), .assistant(text: "2", toolCalls: [])])
        #expect((tokens, conversation.dropped) == (30, 4))
        let none = try await conversation.fit(budget: 5) { 10 * ($0.history.count + 1) }
        #expect(none == 10 && conversation.history.isEmpty)
    }
}

@Suite struct AIStreamTextTests {
    @Test func sendsWhatIsNewAndStopsAtAStopSequence() {
        var text = AIStreamText(stops: ["END"])
        #expect(text.advance(to: "Hel") == "Hel")
        #expect(text.advance(to: "Hello E") == "lo ")
        #expect(text.advance(to: "Hello EN") == "")
        #expect(text.advance(to: "Hello ENX") == "ENX")
        #expect(text.advance(to: "Hello ENX and END more") == " and ")
        #expect(text.stopped)
        #expect(text.advance(to: "Hello ENX and END more and more") == "")
        #expect(text.finish() == "")
        var plain = AIStreamText(stops: ["\n\n"])
        #expect(plain.advance(to: "a\n") == "a")
        #expect(plain.finish() == "\n")
        #expect(plain.sent == "a\n")
    }
}

#if canImport(FoundationModels)
@Suite struct AISchemaTests {
    @Test func convertsTheSupportedSubset() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let converted = try AISchema.generationSchema(AIJSON.parse("""
        {"type":"object","properties":{
          "city":{"type":"string","description":"The city"},
          "unit":{"type":"string","enum":["celsius","fahrenheit"]},
          "days":{"type":"integer","minimum":1,"maximum":10},
          "detail":{"type":["boolean","null"]},
          "hours":{"type":"array","items":{"type":"number"},"maxItems":24},
          "place":{"$ref":"#/$defs/Place"},
          "either":{"anyOf":[{"type":"string"},{"type":"object","properties":{"lat":{"type":"number"}}}]}},
         "required":["city","detail"],
         "$defs":{"Place":{"type":"object","properties":{"name":{"type":"string"},"near":{"$ref":"#/$defs/Place"}}}}}
        """), name: "get weather")
        let encoded = String(decoding: try JSONEncoder().encode(converted), as: UTF8.self)
        for word in ["city", "celsius", "fahrenheit", "days", "hours", "Place", "lat"] { #expect(encoded.contains(word), "\(word)") }
    }

    @Test func explainsWhatItCannotGuide() throws {
        for text in [#"{"type":"object","properties":{"x":{"enum":[1,2]}}}"#, #"{"$ref":"https://example.com/s.json"}"#, #"{"type":"null"}"#] {
            guard #available(iOS 26.0, macOS 26.0, *) else { return }
            #expect(throws: AISchema.Unsupported.self, "\(text)") { try AISchema.generationSchema(AIJSON.parse(text), name: "x") }
        }
    }
}
#endif
