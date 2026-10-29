import Testing
@testable import CabooseKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PointerClickDriverTests {
    private final class Clock {
        struct Wait {
            let duration: UInt64
            let continuation: CheckedContinuation<Void, any Error>
            func resume() { continuation.resume() }
        }

        private var waits: [Wait] = []
        private var observer: CheckedContinuation<Wait, Never>?

        func sleep(_ duration: UInt64) async throws {
            try await withCheckedThrowingContinuation { continuation in
                let wait = Wait(duration: duration, continuation: continuation)
                if let observer {
                    self.observer = nil
                    observer.resume(returning: wait)
                } else {
                    waits.append(wait)
                }
            }
        }

        // A registered sleep is a barrier: the driver has finished the preceding
        // synchronous edge and is suspended at the next interval. A yield count
        // does not establish that ordering when the full suite shares the executor.
        func next(_ duration: UInt64) async -> Wait {
            let wait: Wait
            if !waits.isEmpty {
                wait = waits.removeFirst()
            } else {
                precondition(observer == nil)
                wait = await withCheckedContinuation { observer = $0 }
            }
            #expect(wait.duration == duration)
            return wait
        }
    }

    @Test func tapsHaveDownAndUpIntervalsAndStayOrdered() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [String] = []
        driver.click { edges.append($0 ? "A down" : "A up"); return true }
        driver.click { edges.append($0 ? "B down" : "B up"); return true }
        let firstDown = await clock.next(100_000_000)
        #expect(edges == ["A down"])
        firstDown.resume()
        let firstUp = await clock.next(20_000_000)
        #expect(edges == ["A down", "A up"])
        firstUp.resume()
        let secondDown = await clock.next(100_000_000)
        #expect(edges == ["A down", "A up", "B down"])
        secondDown.resume()
        let secondUp = await clock.next(20_000_000)
        #expect(edges == ["A down", "A up", "B down", "B up"])
        secondUp.resume()
    }

    @Test func cancellationReleasesOnceAndDropsQueuedClicks() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [String] = []
        driver.click { edges.append($0 ? "A down" : "A up"); return true }
        driver.click { edges.append($0 ? "queued down" : "queued up"); return true }
        let oldDown = await clock.next(100_000_000)
        driver.cancel()
        #expect(edges == ["A down", "A up"])
        // Drain the old timer alongside a fresh click; its next registered interval
        // proves the actor has progressed without relying on a fixed number of yields.
        driver.click { edges.append($0 ? "C down" : "C up"); return true }
        let newDown = await clock.next(100_000_000)
        oldDown.resume()
        newDown.resume()
        let newUp = await clock.next(20_000_000)
        #expect(edges == ["A down", "A up", "C down", "C up"])
        newUp.resume()
    }

    @Test func staleTargetIsSkippedBeforePressing() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [Bool] = []
        driver.click { _ in false }
        driver.click { edges.append($0); return true }
        let down = await clock.next(100_000_000)
        #expect(edges == [true])
        down.resume()
        let up = await clock.next(20_000_000)
        #expect(edges == [true, false])
        up.resume()
    }

    @Test func oldTimerCannotReleaseANewerClick() async {
        let clock = Clock()
        let driver = PointerClickDriver(sleep: clock.sleep)
        var edges: [String] = []
        driver.click { edges.append($0 ? "A down" : "A up"); return true }
        let oldDown = await clock.next(100_000_000)
        driver.cancel()
        driver.click { edges.append($0 ? "B down" : "B up"); return true }
        let newDown = await clock.next(100_000_000)
        oldDown.resume()
        #expect(edges == ["A down", "A up", "B down"])
        newDown.resume()
        let newUp = await clock.next(20_000_000)
        #expect(edges == ["A down", "A up", "B down", "B up"])
        newUp.resume()
    }
}
