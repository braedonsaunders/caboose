import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioIngressTests {
    @Test func queuedAndRunningPacketsShareOneLimit() {
        let ingress = AudioIngress()
        var tickets: [AudioIngress.Ticket] = []
        for _ in 0..<1000 { ingress.submit(bytes: 100) { tickets.append($0) } }
        #expect(tickets.count == AudioIngress.packetLimit)
        #expect(ingress.rejected == 1000 - UInt64(AudioIngress.packetLimit))
        // Entering a job does not release capacity; only finishing does.
        #expect(ingress.isCurrent(tickets[0]))
        ingress.submit(bytes: 100) { _ in Issue.record("running job lost its permit") }
        ingress.finish(tickets.removeFirst())
        ingress.submit(bytes: 100) { tickets.append($0) }
        #expect(tickets.count == AudioIngress.packetLimit)
        for ticket in tickets { ingress.finish(ticket) }
    }

    @Test func concurrentProducersCannotOverbook() {
        let ingress = AudioIngress()
        let lock = NSLock()
        var tickets: [AudioIngress.Ticket] = []
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            ingress.submit(bytes: 100) { ticket in
                lock.lock(); tickets.append(ticket); lock.unlock()
            }
        }
        #expect(tickets.count == AudioIngress.packetLimit)
        #expect(ingress.rejected == 1000 - UInt64(AudioIngress.packetLimit))
        for ticket in tickets { ingress.finish(ticket) }
    }

    @Test func byteLimitAndMalformedSizes() {
        let ingress = AudioIngress()
        var tickets: [AudioIngress.Ticket] = []
        for size in [0, -1, Int.max, AudioIngress.byteLimit + 1] {
            ingress.submit(bytes: size) { _ in Issue.record("invalid size admitted") }
        }
        ingress.submit(bytes: AudioIngress.byteLimit) { tickets.append($0) }
        ingress.submit(bytes: 1) { _ in Issue.record("byte bound exceeded") }
        #expect(ingress.rejected == 5)
        ingress.finish(tickets[0])
        ingress.submit(bytes: 1) { tickets.append($0) }
        #expect(tickets.count == 2)
        ingress.finish(tickets[1])
    }

    @Test func stopInvalidatesWorkWithoutReleasingItsMemory() {
        let ingress = AudioIngress()
        var tickets: [AudioIngress.Ticket] = []
        ingress.submit(bytes: AudioIngress.byteLimit) { tickets.append($0) }
        var barriers = 0
        for _ in 0..<100 {
            ingress.invalidate { barriers += 1 }
            ingress.submit(bytes: 1) { _ in Issue.record("old ownership forgotten") }
        }
        #expect(barriers == 100)
        #expect(!ingress.isCurrent(tickets[0]))
        ingress.finish(tickets[0])
        ingress.submit(bytes: 100) { tickets.append($0) }
        #expect(ingress.isCurrent(tickets[1]))
        ingress.finish(tickets[1])
    }

    @Test func rejectedPacketPreservesSmallTimestampGap() {
        let ingress = AudioIngress()
        var continuity = AudioIngressContinuity()
        var timeline = AudioPacketTimeline()
        var first: AudioIngress.Ticket!
        ingress.submit(bytes: AudioIngress.byteLimit) { first = $0 }
        let firstGap = continuity.discontinuity(at: first.sequence)
        #expect(!firstGap)
        #expect(timeline.place(server: 1_000_000, frames: 960) == 1_000_000)
        ingress.submit(bytes: 100) { _ in Issue.record("overload admitted") }
        ingress.finish(first)
        var next: AudioIngress.Ticket!
        ingress.submit(bytes: 100) { next = $0 }
        let droppedGap = continuity.discontinuity(at: next.sequence)
        #expect(droppedGap)
        timeline.reset()
        // Missing 20 ms stays missing, rather than being absorbed by 200 ms jitter tolerance.
        #expect(timeline.place(server: 1_040_000, frames: 960) == 1_040_000)
        ingress.finish(next)
        ingress.submit(bytes: 100) { next = $0 }
        let ordinaryGap = continuity.discontinuity(at: next.sequence)
        #expect(!ordinaryGap)
        #expect(timeline.place(server: 1_061_000, frames: 960) == 1_060_000)
        ingress.finish(next)
    }
}
