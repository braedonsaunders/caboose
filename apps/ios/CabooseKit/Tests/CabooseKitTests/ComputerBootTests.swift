import Foundation
import Testing
@testable import CabooseKit

/// A computer's boot as the host reports it, the event stream it comes over, and what the
/// spinning-up screen shows of it.
@Suite struct ComputerBootTests {
    static let running = #"""
    {"boot":{"id":"b1","state":"running","startedAt":"2026-11-01T10:00:00.000Z","finishedAt":null,"error":null,"steps":[
      {"id":"image","label":"Downloading the system image","state":"active","detail":"1.2 GB of 3.4 GB","progress":{"completed":1200,"total":3400}},
      {"id":"network","label":"Setting up its network","state":"pending","detail":null,"progress":null},
      {"id":"disk","label":"Making its disk","state":"pending","detail":null,"progress":null},
      {"id":"start","label":"Starting it up","state":"pending","detail":null,"progress":null},
      {"id":"display","label":"Opening its display","state":"pending","detail":null,"progress":null}]}}
    """#

    static func boot(_ id: String = "b1", _ state: ComputerBoot.State = .running, steps: [ComputerBoot.Step] = [], error: String? = nil) -> ComputerBoot {
        ComputerBoot(id: id, state: state, startedAt: "2026-11-01T10:00:00Z", error: error, steps: steps)
    }

    @Test func bootDecodes() throws {
        let boot = try #require(try ComputerBootEnvelope.decode(Data(Self.running.utf8)).boot)
        #expect(boot.id == "b1" && boot.state == .running && !boot.isFinished)
        #expect(boot.steps.map(\.id) == ["image", "network", "disk", "start", "display"])
        #expect(boot.steps[0].progress?.fraction.map { abs($0 - 1200.0 / 3400.0) < 1e-9 } == true)
        #expect(boot.startDate == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        #expect(try ComputerBootEnvelope.decode(Data(#"{"boot":null}"#.utf8)).boot == nil)
    }

    @Test func unknownStepStatesClaimNothing() throws {
        let json = #"{"id":"x","label":"Something new","state":"warming","detail":null,"progress":null}"#
        let step = try JSONDecoder().decode(ComputerBoot.Step.self, from: Data(json.utf8))
        #expect(step.state == .pending)
    }

    @Test func progressIsOnlyAFractionWithATotal() {
        #expect(ComputerBoot.Step.Progress(completed: 5, total: nil).fraction == nil)
        #expect(ComputerBoot.Step.Progress(completed: 5, total: 0).fraction == nil)
        #expect(ComputerBoot.Step.Progress(completed: 15, total: 10).fraction == 1)
    }

    @Test func failedStepIsTheOneThatFailed() {
        let failed = Self.boot("b1", .failed, steps: [
            .init(id: "image", label: "Image", state: .skipped),
            .init(id: "disk", label: "Disk", state: .failed),
        ], error: "The disk could not be made: no space left on the host")
        #expect(failed.failedStep?.id == "disk")
        let interrupted = Self.boot("b1", .failed, steps: [.init(id: "start", label: "Start", state: .active)])
        #expect(interrupted.failedStep?.id == "start")
        #expect(Self.boot().failedStep == nil)
    }

    // MARK: Server-Sent Events

    @Test func eventsArriveOnTheirBlankLine() {
        var parser = ServerSentEvents()
        #expect(parser.feed(Array("event: boot\ndata: {\"boot\":null}\n".utf8)).isEmpty)
        let events = parser.feed(Array("\n".utf8))
        #expect(events == [.init(name: "boot", data: #"{"boot":null}"#)])
    }

    @Test func eventsSurviveAnySplitAndLineEnding() {
        let stream = ": keepalive\r\n\r\nevent: boot\r\ndata: one\r\n\r\nevent:boot\rdata:two\r\rdata: a\ndata: b\nid: 7\n\n"
        let bytes = Array(stream.utf8)
        var whole = ServerSentEvents()
        let expected: [ServerSentEvents.Event] = [
            .init(name: "boot", data: "one"), .init(name: "boot", data: "two"), .init(name: "message", data: "a\nb", id: "7"),
        ]
        #expect(whole.feed(bytes) == expected)
        // Byte by byte, including a CRLF split across two reads.
        var pieces = ServerSentEvents()
        var collected: [ServerSentEvents.Event] = []
        for byte in bytes { collected += pieces.feed([byte]) }
        #expect(collected == expected)
    }

    @Test func commentsAndUnfinishedEventsAreDropped() {
        var parser = ServerSentEvents()
        #expect(parser.feed(Array(": keepalive\n\n: keepalive\n\nretry: 10\n\n".utf8)).isEmpty)
        #expect(parser.feed(Array("event: boot\ndata: partial".utf8)).isEmpty)
        parser.finish()
        #expect(parser.feed(Array("\n\n".utf8)).isEmpty)
    }

    @Test func aWholeBootStreamDecodes() throws {
        let body = "event: boot\ndata: " + Self.running.replacingOccurrences(of: "\n", with: "") + "\n\n"
        var parser = ServerSentEvents()
        let events = parser.feed(Array(body.utf8))
        #expect(events.count == 1)
        let boot = try ComputerBootEnvelope.decode(Data(try #require(events.first).data.utf8)).boot
        #expect(boot?.steps.count == 5)
    }

    // MARK: Tracking

    @Test func trackerFollowsTheHost() {
        var tracker = BootTracker()
        #expect(tracker.link == .connecting && tracker.boot == nil)
        let first = Self.boot(steps: [.init(id: "image", label: "Image", state: .active)])
        let changed1 = tracker.apply(first)
        #expect(changed1)
        #expect(tracker.link == .live && !tracker.isFinished)
        let changed2 = tracker.apply(first)
        #expect(!changed2, "the same report changes nothing")
        tracker.dropped(reason: "The network connection was lost.")
        tracker.dropped(reason: "The network connection was lost.")
        #expect(tracker.link == .reconnecting(attempt: 2, reason: "The network connection was lost."))
        #expect(tracker.boot == first, "a dropped stream keeps the last report on screen")
        let changed3 = tracker.apply(nil)
        #expect(!changed3)
        #expect(tracker.link == .live)
        let changed4 = tracker.apply(Self.boot("b1", .succeeded, steps: [.init(id: "image", label: "Image", state: .done)]))
        #expect(changed4)
        #expect(tracker.succeeded && tracker.isFinished)
    }

    @Test func retryingSetsTheFailedAttemptAside() {
        var tracker = BootTracker()
        let failed = Self.boot("b1", .failed, error: "No space")
        tracker.apply(failed)
        #expect(tracker.failed)
        tracker.retrying()
        #expect(tracker.boot == nil && tracker.link == .connecting)
        let changed5 = tracker.apply(failed)
        #expect(!changed5, "a late report of the old attempt is not shown again")
        let changed6 = tracker.apply(Self.boot("b2"))
        #expect(changed6)
        #expect(tracker.boot?.id == "b2")
    }

    @Test func reconnectsBackOff() {
        #expect([1, 2, 3, 4, 5, 9].map(BootTracker.reconnectDelay) == [1, 2, 4, 8, 8, 8])
    }

    // MARK: Presentation

    @Test func stepsReadHonestly() {
        let boot = Self.boot(steps: [
            .init(id: "image", label: "Downloading the system image", state: .skipped),
            .init(id: "network", label: "Setting up its network", state: .done),
            .init(id: "disk", label: "Making its disk", state: .active, detail: "  "),
            .init(id: "start", label: "Starting it up", state: .pending),
            .init(id: "image2", label: "Copying", state: .active, detail: "1 GB of 2 GB", progress: .init(completed: 1, total: 2)),
            .init(id: "image3", label: "Copying", state: .active, progress: .init(completed: 1, total: nil)),
            .init(id: "display", label: "Opening its display", state: .failed, detail: "The display did not answer"),
        ])
        let rows = BootStepPresentation.steps(of: boot)
        #expect(rows.map(\.indicator) == [.notNeeded, .done, .working(fraction: nil), .waiting, .working(fraction: 0.5), .working(fraction: nil), .failed])
        #expect(rows[0].detail == "Not needed")
        #expect(rows[2].detail == nil)
        #expect(rows[4].detail == "1 GB of 2 GB")
        #expect(rows[6].detail == "The display did not answer")
        #expect(BootStepPresentation.position(in: boot)! == (3, 7))
        #expect(BootStepPresentation.settled(in: boot) == 2)
    }
}
