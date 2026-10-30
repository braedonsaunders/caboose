import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioDiagnosticsTests {
    private func record(_ index: Int = 0) -> AudioDiagnosticRecord {
        AudioDiagnosticRecord(kind: .interval, monotonicSeconds: Double(index), wallUnixSeconds: 1_790_000_000,
                              packets: index, failures: 0, restarts: 0, delayMicros: 120_000,
                              requestedRate: 1, observedRate: 1, projectedMicros: 2_000_000,
                              renderedMicros: 1_999_999, timestampRegressions: 0,
                              interval: AudioTimingInterval())
    }

    @Test func stalledWriterKeepsOnlyNewest64AndQueuesOneDrain() {
        var buffer = AudioDiagnosticBuffer()
        #expect(buffer.append(record(0)))
        let firstRevision = buffer.revision
        for index in 1..<10_000 { #expect(!buffer.append(record(index))) }
        #expect(buffer.records.count == 64)
        #expect(buffer.records.first?.packets == 9_936)
        #expect(buffer.records.last?.packets == 9_999)
        #expect(!buffer.finish(revision: firstRevision))
        #expect(buffer.scheduled)
        #expect(buffer.finish(revision: buffer.revision))
        #expect(!buffer.scheduled)
        #expect(buffer.append(record(10_000)))
    }

    @Test func byteLimitIncludesPunctuationAndDropsOldest() throws {
        let one = try #require(AudioDiagnosticBuffer.snapshot([record(3)]))
        let data = try #require(AudioDiagnosticBuffer.snapshot([record(1), record(2), record(3)], maximumBytes: one.count))
        #expect(data == one)
        #expect(AudioDiagnosticBuffer.snapshot([record()], maximumBytes: 2) == Data("[]".utf8))
        #expect(AudioDiagnosticBuffer.snapshot([record()], maximumBytes: 1) == nil)
        let many = try #require(AudioDiagnosticBuffer.snapshot((0..<1000).map { record($0) }))
        #expect(many.count <= 128 * 1024)
        let array = try #require(JSONSerialization.jsonObject(with: many) as? [[String: Any]])
        #expect(array.count <= 64)
        #expect(array.last?["packets"] as? Int == 999)
    }

    @Test func nonfiniteRecordDoesNotPoisonValidNeighbors() throws {
        var invalid = record(2)
        invalid.observedRate = .nan
        let data = try #require(AudioDiagnosticBuffer.snapshot([record(1), invalid, record(3)]))
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.compactMap { $0["packets"] as? Int } == [1, 3])
    }

    @Test func schemaAllowsOnlyFixedFieldsAndNumericPayloads() throws {
        var sample = record()
        sample.kind = .restart
        sample.rendererStatus = 1; sample.frameMin = 960; sample.frameMax = 960
        sample.arrivalMaxSeconds = 0.02; sample.rawPTSMicros = 3; sample.placedPTSMicros = 4
        sample.receiptToDispatchMS = 0; sample.queueMS = 1; sample.decodeMS = 2
        sample.preparationMS = 3; sample.enqueueMS = 4; sample.totalMS = 10
        sample.finishedMonotonicSeconds = 2
        let data = try #require(AudioDiagnosticBuffer.snapshot([sample]))
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let row = try #require(array.first)
        let allowed: Set<String> = ["kind", "monotonicSeconds", "wallUnixSeconds", "packets", "failures", "restarts", "delayMicros", "requestedRate", "observedRate", "projectedMicros", "renderedMicros", "timestampRegressions", "rendererStatus", "frameMin", "frameMax", "arrivalMaxSeconds", "interval", "rawPTSMicros", "placedPTSMicros", "receiptToDispatchMS", "queueMS", "decodeMS", "preparationMS", "enqueueMS", "totalMS", "finishedMonotonicSeconds"]
        #expect(Set(row.keys) == allowed)
        for (key, value) in row where key != "kind" && key != "interval" { #expect(value is NSNumber) }
        #expect(row["kind"] as? String == "restart")
        let interval = try #require(row["interval"] as? [String: Any])
        #expect(Set(interval.keys) == ["receipts", "packets", "receiptGap", "incomingWait", "incomingWork", "audioReceiptGap", "dispatchGap", "queueEntryGap", "decodeCompletionGap", "enqueueCompletionGap", "receiptToDispatch", "queueWait", "decode", "prepare", "enqueue", "total"])
        #expect(interval.values.allSatisfy { $0 is NSNumber })
    }
}
