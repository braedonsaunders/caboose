import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioRateProvenanceTests {
    private func begin(_ state: inout AudioRateProvenanceState, time: Double = 1) -> AudioRateProvenanceState.Ticket? {
        state.begin(reason: .start, stopCaller: nil, requested: 1.001, before: 1,
                    monotonic: time, wall: 1_790_000_000 + time)
    }

    private func requireBegin(_ state: inout AudioRateProvenanceState, time: Double = 1) throws -> AudioRateProvenanceState.Ticket {
        let ticket = begin(&state, time: time)
        return try #require(ticket)
    }

    @Test func notificationOrderIsRetainedWithoutInferringItsCause() throws {
        var state = AudioRateProvenanceState(generation: 7)
        state.changed(generation: 7, rate: 1, monotonic: 0, wall: 100)
        let ticket = try requireBegin(&state)
        state.changed(generation: 7, rate: 0, monotonic: 2, wall: 102)
        #expect(state.snapshot.latestRateChange?.openWriteSequence == ticket.sequence)
        state.end(ticket, after: 1.001, monotonic: 3)
        state.changed(generation: 7, rate: 1.001, monotonic: 4, wall: 104)
        #expect(state.snapshot.latestRateChange?.openWriteSequence == nil)
        #expect(state.snapshot.latestZeroRateChange?.monotonicSeconds == 2)
        let write = try #require(state.snapshot.writes.first)
        #expect(write.notificationsBefore == 1 && write.notificationsAfter == 2)
        #expect(write.beginMonotonicSeconds == 1 && write.endMonotonicSeconds == 3)
        #expect(write.beforeRate == 1 && write.afterRate == 1.001)
        #expect(state.snapshot.rateChangeCount == 3 && state.snapshot.zeroRateChangeCount == 1)
    }

    @Test func cancellationAndOtherGenerationsCannotCompleteOrNotify() throws {
        var old = AudioRateProvenanceState(generation: 1)
        let ticket = try requireBegin(&old)
        old.invalidate()
        old.end(ticket, after: 0, monotonic: 2)
        old.changed(generation: 1, rate: 0, monotonic: 3, wall: 103)
        #expect(old.snapshot.writes.first?.endMonotonicSeconds == nil)
        #expect(old.snapshot.rateChangeCount == 0)
        let ignored = begin(&old)
        #expect(ignored == nil)
        var current = AudioRateProvenanceState(generation: 2)
        let newTicket = try requireBegin(&current)
        current.end(ticket, after: 0, monotonic: 4)
        current.changed(generation: 1, rate: 0, monotonic: 5, wall: 105)
        #expect(current.snapshot.writes.first?.endMonotonicSeconds == nil)
        #expect(current.snapshot.rateChangeCount == 0)
        current.end(newTicket, after: 1, monotonic: 6)
        #expect(current.snapshot.writes.first?.afterRate == 1)
    }

    @Test func onlyExactCurrentWriteCanFinish() throws {
        var state = AudioRateProvenanceState(generation: 1)
        let first = try requireBegin(&state)
        state.end(first, after: 1, monotonic: 2)
        let second = try requireBegin(&state, time: 3)
        state.end(first, after: 0, monotonic: 4)
        #expect(state.snapshot.writes[0].afterRate == 1)
        #expect(state.snapshot.writes[1].afterRate == nil)
        state.end(second, after: 0, monotonic: 5)
        #expect(state.snapshot.writes[1].afterRate == 0)
    }

    @Test func stopReasonsAndInterruptionCountsRemainDistinct() throws {
        var state = AudioRateProvenanceState(generation: 1)
        state.interrupted(began: true, monotonic: 1, wall: 101)
        let ticket = state.begin(reason: .stop, stopCaller: .interruptionBegan, requested: 0,
                                 before: 1, monotonic: 2, wall: 102)
        let stop = try #require(ticket)
        state.end(stop, after: 0, monotonic: 3)
        state.interrupted(began: false, monotonic: 4, wall: 104)
        #expect(state.snapshot.interruptionBeganCount == 1 && state.snapshot.interruptionEndedCount == 1)
        #expect(state.snapshot.latestInterruption?.began == false)
        #expect(state.snapshot.writes.first?.stopCaller == .interruptionBegan)
        #expect(state.snapshot.writes.first?.reason == .stop)
    }

    @Test func writeHistoryAndExistingArtifactBoundsSurviveEventStorm() throws {
        var state = AudioRateProvenanceState(generation: 1)
        for index in 1...1000 {
            let ticket = try requireBegin(&state, time: Double(index))
            state.changed(generation: 1, rate: 0, monotonic: Double(index), wall: 100)
            state.end(ticket, after: 1, monotonic: Double(index) + 0.1)
        }
        #expect(state.snapshot.writes.count == 16)
        #expect(state.snapshot.writes.first?.sequence == 985 && state.snapshot.writes.last?.sequence == 1000)
        #expect(state.snapshot.rateChangeCount == 1000 && state.snapshot.writeCount == 1000)
        let record = AudioDiagnosticRecord(kind: .interval, monotonicSeconds: 1000, wallUnixSeconds: 100,
                                          packets: 1, failures: 0, restarts: 0, delayMicros: 120_000,
                                          requestedRate: 1, observedRate: 1, projectedMicros: 1,
                                          renderedMicros: 1, timestampRegressions: 0,
                                          rateProvenance: state.snapshot)
        let data = try #require(AudioDiagnosticBuffer.snapshot(Array(repeating: record, count: 1000)))
        #expect(data.count <= AudioDiagnosticBuffer.maximumBytes)
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(!array.isEmpty && array.count <= 64)
        let trace = try #require(array.last?["rateProvenance"] as? [String: Any])
        #expect(trace["writeCount"] as? Int == 1000)
    }

    @Test func invalidNumbersDoNotEnterTrace() throws {
        var state = AudioRateProvenanceState(generation: 1)
        let invalid = state.begin(reason: .start, stopCaller: nil, requested: .nan, before: 1,
                                  monotonic: 1, wall: 100)
        #expect(invalid == nil)
        state.changed(generation: 1, rate: .infinity, monotonic: 1, wall: 100)
        state.interrupted(began: true, monotonic: .nan, wall: 100)
        #expect(state.snapshot.rateChangeCount == 0 && state.snapshot.interruptionBeganCount == 0)
        _ = try JSONEncoder().encode(state.snapshot)
    }
}
