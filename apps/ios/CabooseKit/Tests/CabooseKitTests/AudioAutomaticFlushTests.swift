import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioAutomaticFlushTests {
    private func notify(_ state: inout AudioAutomaticFlushState, _ generation: UInt64, time: Double = 1) -> Bool {
        state.notify(generation: generation, monotonic: time, wall: 1_790_000_000 + time, flushMicros: 123)
    }

    @Test func burstCoalescesAndCleanupPrecedesNextEnqueue() {
        var state = AudioAutomaticFlushState()
        let generation = state.begin()
        let first = notify(&state, generation)
        #expect(first)
        for index in 2...1000 {
            let scheduled = notify(&state, generation, time: Double(index))
            #expect(!scheduled)
        }
        // The existing playback queue may already contain packet work ahead of the
        // drain. That packet takes the latch before enqueue, leaving one drain queued.
        var operations: [String] = []
        let flush = state.take(generation: generation)
        if flush { operations.append("flush") }
        operations.append("enqueue")
        #expect(operations == ["flush", "enqueue"])
        let duplicate = state.take(generation: generation)
        #expect(!duplicate)
        let again = state.finish(generation: generation)
        #expect(!again && !state.scheduled)
        #expect(state.summary.notifications == 1000 && state.summary.recoveries == 1)
        #expect(state.summary.lastMonotonicSeconds == 1000)
    }

    @Test func notificationDuringCleanupSchedulesOnlyOneSuccessor() {
        var state = AudioAutomaticFlushState()
        let generation = state.begin()
        _ = notify(&state, generation)
        let firstFlush = state.take(generation: generation)
        #expect(firstFlush)
        // Callback arrives while renderer.flush is in progress, outside the latch lock.
        let schedule = notify(&state, generation)
        #expect(!schedule)
        let again = state.finish(generation: generation)
        #expect(again && state.scheduled)
        let secondFlush = state.take(generation: generation)
        #expect(secondFlush)
        let finished = state.finish(generation: generation)
        #expect(!finished && !state.scheduled)
        #expect(state.summary.notifications == 2 && state.summary.recoveries == 2)
    }

    @Test func stopAndReRegistrationFenceOldCallbacksAndQueuedDrains() {
        var state = AudioAutomaticFlushState()
        let old = state.begin()
        _ = notify(&state, old)
        state.cancel()
        let afterStop = state.take(generation: old)
        let staleCallback = notify(&state, old)
        #expect(!afterStop && !staleCallback && !state.pending)
        let current = state.begin()
        let newCallback = notify(&state, current)
        #expect(newCallback)
        let staleDrain = state.take(generation: old)
        let staleFinish = state.finish(generation: old)
        #expect(!staleDrain && !staleFinish && state.pending && state.scheduled)
        let currentFlush = state.take(generation: current)
        #expect(currentFlush)
        #expect(state.summary.notifications == 2 && state.summary.recoveries == 1)
        #expect(state.summary.lastEventGeneration == current)
    }

    @Test func cleanupWithoutAnotherNotificationCannotLoopOrResetPlayback() {
        var state = AudioAutomaticFlushState()
        let generation = state.begin()
        _ = notify(&state, generation)
        let cleanup = state.take(generation: generation)
        #expect(cleanup)
        // Explicit flush does not generate an automatic-flush notification (SDK).
        for _ in 0..<100 {
            let anotherFlush = state.take(generation: generation)
            #expect(!anotherFlush)
        }
        let again = state.finish(generation: generation)
        #expect(!again)
        #expect(state.active && state.generation == generation)
        #expect(state.summary.recoveries == 1)
    }

    @Test func latestEventSummaryHasFixedReasonAndFiniteTimestamps() throws {
        var state = AudioAutomaticFlushState()
        let generation = state.begin()
        _ = notify(&state, generation)
        let completeData = try JSONEncoder().encode(state.summary)
        let complete = try #require(JSONSerialization.jsonObject(with: completeData) as? [String: Any])
        #expect(Set(complete.keys) == ["notifications", "recoveries", "reason", "lastEventGeneration", "lastMonotonicSeconds", "lastWallUnixSeconds", "lastFlushMicros"])
        for (key, value) in complete where key != "reason" { #expect(value is NSNumber) }
        _ = state.notify(generation: generation, monotonic: .nan, wall: .infinity, flushMicros: nil)
        let data = try JSONEncoder().encode(state.summary)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["notifications", "recoveries", "reason", "lastEventGeneration"])
        #expect(json["reason"] as? String == "rendererNotification")
        #expect(state.summary.lastFlushMicros == nil)
    }
}
