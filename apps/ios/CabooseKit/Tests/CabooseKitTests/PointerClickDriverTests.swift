import Testing
@testable import CabooseKit

@MainActor
struct PointerClickDriverTests {
    private final class Clock {
        var waits: [(UInt64, CheckedContinuation<Void, any Error>)] = []
        func sleep(_ duration: UInt64) async throws {
            try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
        }
        func advance() async {
            for _ in 0..<100 where waits.isEmpty { await Task.yield() }
            guard !waits.isEmpty else { Issue.record("Expected a scheduled click edge"); return }
            waits.removeFirst().1.resume()
            for _ in 0..<10 { await Task.yield() }
        }
    }

    @Test func tapsHaveDownAndUpIntervalsAndStayOrdered() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [String] = []
        driver.click { edges.append($0 ? "A down" : "A up"); return true }
        driver.click { edges.append($0 ? "B down" : "B up"); return true }
        #expect(edges == ["A down"])
        await clock.advance()
        #expect(edges == ["A down", "A up"])
        await clock.advance()
        #expect(edges == ["A down", "A up", "B down"])
        await clock.advance()
        #expect(edges == ["A down", "A up", "B down", "B up"])
        await clock.advance()
    }

    @Test func cancellationReleasesOnceAndDropsQueuedClicks() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [Bool] = []
        driver.click { edges.append($0); return true }
        driver.click { edges.append($0); return true }
        for _ in 0..<10 { await Task.yield() }
        driver.cancel()
        #expect(edges == [true, false])
        await clock.advance()
        #expect(edges == [true, false])
    }

    @Test func staleTargetIsSkippedBeforePressing() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [Bool] = []
        driver.click { _ in false }
        driver.click { edges.append($0); return true }
        #expect(edges == [true])
        await clock.advance()
        await clock.advance()
        #expect(edges == [true, false])
    }

    @Test func oldTimerCannotReleaseANewerClick() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [String] = []
        driver.click { edges.append($0 ? "A down" : "A up"); return true }
        for _ in 0..<10 { await Task.yield() }
        driver.cancel()
        driver.click { edges.append($0 ? "B down" : "B up"); return true }
        await clock.advance()
        #expect(edges == ["A down", "A up", "B down"])
        await clock.advance()
        await clock.advance()
        #expect(edges == ["A down", "A up", "B down", "B up"])
    }
}
