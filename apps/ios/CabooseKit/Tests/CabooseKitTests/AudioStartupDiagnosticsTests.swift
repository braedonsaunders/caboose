import CoreMedia
import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioStartupDiagnosticsTests {
    private func packet(_ time: Double, pts: Int64 = 1_000_000) -> AudioStartupAccumulator.Packet {
        .init(received: time, dispatched: time + 0.001, entered: time + 0.003,
              decoded: time + 0.004, enqueueStarted: time + 0.005, enqueued: time + 0.007,
              finished: time + 0.008, finishedWall: 1_790_000_000 + time + 0.008,
              rawPTS: pts + 100, placedPTS: pts, frames: 960, declaredBytes: 7680,
              copiedBytes: 7680, leadMicros: 120_000)
    }

    @Test func twelveSecondWindowHasAtMost48BucketsAndNoTailGrowth() throws {
        var trace = AudioStartupAccumulator()
        var buckets: [AudioStartupBucket] = []
        for i in 0..<1500 {
            if let bucket = trace.observe(packet(Double(i) * 0.02, pts: Int64(i) * 20_000)) { buckets.append(bucket) }
        }
        let final = trace.finish()
        #expect(final == nil)
        #expect(buckets.count == 48)
        #expect(buckets.map(\.index) == Array(0..<48))
        #expect(buckets.allSatisfy { $0.generation == 1 })
        #expect(buckets.reduce(0) { $0 + $1.timing.packets } == 600)
        let first = try #require(buckets.first)
        #expect(first.rawMinusPlacedMicros == .init(minimum: 100, maximum: 100))
        #expect(first.rawStepMicros == .init(minimum: 20_000, maximum: 20_000))
        #expect(first.decodedFrames == .init(minimum: 960, maximum: 960))
        #expect(first.declaredBytes == .init(minimum: 7680, maximum: 7680))
        #expect(first.copiedBytes == first.declaredBytes)
        #expect(abs(first.timing.queueWait - 0.002) < 1e-9)
        #expect(abs(first.timing.enqueue - 0.002) < 1e-9)
    }

    @Test func ingressGapAndLifecycleResetFenceGenerations() throws {
        var trace = AudioStartupAccumulator()
        _ = trace.observe(packet(10))
        // Delayed queue execution alone must not start a new ingress generation.
        var delayed = packet(10.02); delayed.finished += 2
        _ = trace.observe(delayed)
        let first = try #require(trace.observe(packet(11.02)))
        #expect(first.generation == 1 && first.timing.packets == 2)
        #expect(first.timing.total > 2)
        let resumed = try #require(trace.reset())
        #expect(resumed.generation == 2 && resumed.index == 0)
        #expect(resumed.rawStepMicros == nil && resumed.placedStepMicros == nil)
        _ = trace.observe(packet(11.03))
        let stopped = try #require(trace.reset())
        #expect(stopped.generation == 3)
        let empty = trace.reset()
        #expect(empty == nil)
    }

    @Test func lateAndMismatchedPacketsAreCountedWithoutRetainingPayloads() throws {
        var trace = AudioStartupAccumulator()
        var first = packet(0); first.leadMicros = nil
        _ = trace.observe(first)
        var second = packet(0.02, pts: 1_020_000)
        second.leadMicros = -13_525; second.copiedBytes = 7000
        _ = trace.observe(second)
        let bucket = try #require(trace.finish())
        #expect(bucket.latePlacementCount == 1 && bucket.byteMismatchCount == 1)
        #expect(bucket.leadMicros == .init(minimum: -13_525, maximum: -13_525))
        let row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bucket)) as? [String: Any])
        let allowed: Set<String> = ["generation", "index", "windowStartMonotonicSeconds", "firstReceiptMonotonicSeconds", "lastFinishedMonotonicSeconds", "firstReceiptWallUnixSeconds", "rawMinusPlacedMicros", "rawStepMicros", "placedStepMicros", "decodedFrames", "declaredBytes", "copiedBytes", "leadMicros", "byteMismatchCount", "latePlacementCount", "timing"]
        #expect(Set(row.keys) == allowed)
        func numerical(_ value: Any) -> Bool {
            if value is NSNumber { return true }
            if let dictionary = value as? [String: Any] { return dictionary.values.allSatisfy(numerical) }
            return false
        }
        #expect(row.values.allSatisfy(numerical))
    }

    @Test func staleAndNonfiniteIngressCannotCreateInvalidBuckets() throws {
        var trace = AudioStartupAccumulator()
        _ = trace.observe(packet(10))
        let stale = trace.observe(packet(9))
        let invalid = trace.observe(packet(.nan))
        #expect(stale == nil && invalid == nil)
        let first = try #require(trace.finish())
        #expect(first.timing.packets == 1 && first.generation == 1)
    }

    @Test func leadUsesTheSameSingleHostReadAsPlacementWithoutWritingRate() {
        var reads = 0
        var writes: [Float] = []
        let clock = MediaClock(hostTime: {
            reads += 1
            return CMTime(value: 10_000_000 + Int64(reads - 1) * 20_000, timescale: 1_000_000)
        }, rateWriter: { rate, _, _ in writes.append(rate) })
        let first = clock.placement(audio: 1_000_000)
        #expect(first.decision == .start(880_000) && first.leadMicros == nil && reads == 1)
        clock.start(at: 880_000)
        let next = clock.placement(audio: 1_020_000)
        #expect(next.decision == .play && next.leadMicros == 120_000 && reads == 3)
        #expect(writes == [1])
    }

    @Test func sharedWriterKeepsAtMost48StartupRecordsAndOverallCaps() throws {
        var buffer = AudioDiagnosticBuffer()
        var trace = AudioStartupAccumulator()
        _ = trace.observe(packet(0))
        let bucket = try #require(trace.finish())
        func record(_ i: Int, startup: Bool) -> AudioDiagnosticRecord {
            .init(kind: startup ? .startup : .interval, monotonicSeconds: Double(i), wallUnixSeconds: 1_790_000_000,
                  packets: i, failures: 0, restarts: 0, delayMicros: 120_000, requestedRate: 1,
                  observedRate: nil, projectedMicros: nil, renderedMicros: nil, timestampRegressions: 0,
                  startup: startup ? bucket : nil, clockGeneration: 1)
        }
        for i in 0..<200 {
            _ = buffer.append(record(i, startup: i % 5 != 0))
        }
        #expect(buffer.records.count <= 64)
        #expect(buffer.records.filter { $0.kind == .startup }.count == 48)
        let data = try #require(AudioDiagnosticBuffer.snapshot(buffer.records))
        #expect(data.count <= 128 * 1024)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count <= 64)
        #expect(rows.filter { $0["kind"] as? String == "startup" }.count <= 48)
        #expect(rows.allSatisfy { $0["renderedMicros"] == nil && $0["observedRate"] == nil })
    }
}
