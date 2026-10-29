import Testing
@testable import CabooseKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PointerClickDriverTests {
    @MainActor private final class Clock {
        @MainActor final class Wait {
            let duration: UInt64
            private var continuation: CheckedContinuation<Void, any Error>?

            init(_ duration: UInt64, _ continuation: CheckedContinuation<Void, any Error>) {
                self.duration = duration
                self.continuation = continuation
            }

            func resume() {
                guard let continuation else { Issue.record("Timer resumed twice"); return }
                self.continuation = nil
                continuation.resume()
            }

            func cancel() {
                let continuation = continuation
                self.continuation = nil
                continuation?.resume(throwing: CancellationError())
            }
        }

        enum Failure: Error { case timerNotRegistered, taskDidNotFinish }
        private var waits: [Wait] = []
        private var allWaits: [Wait] = []
        private var observer: (Int, CheckedContinuation<Wait, any Error>)?
        private var nextObserver = 0
        private var closed = false
        private var tasks: [Task<Void, Never>] = []
        private let timeoutDuration: Duration

        init(timeout: Duration) { timeoutDuration = timeout }

        func sleep(_ duration: UInt64) async throws {
            guard !closed else { throw CancellationError() }
            // Deliberately keep cancelled timers pending until the test resumes them:
            // oldTimerCannotReleaseANewerClick exercises a late, successful sleep return.
            try await withCheckedThrowingContinuation { continuation in
                let wait = Wait(duration, continuation)
                allWaits.append(wait)
                if let observer {
                    self.observer = nil
                    observer.1.resume(returning: wait)
                } else {
                    waits.append(wait)
                }
            }
        }

        // A registered sleep is a barrier: the driver has finished the preceding
        // synchronous edge and is suspended at the next interval.
        func next(_ duration: UInt64) async throws -> Wait {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let wait: Wait
            if !waits.isEmpty {
                wait = waits.removeFirst()
            } else {
                precondition(observer == nil)
                nextObserver += 1
                let ticket = nextObserver
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: self?.timeoutDuration ?? .seconds(5)) } catch { return }
                    self?.failObserver(ticket, error: Failure.timerNotRegistered)
                }
                defer { timeout.cancel() }
                wait = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { observer = (ticket, $0) }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.failObserver(ticket, error: CancellationError())
                    }
                }
            }
            #expect(wait.duration == duration)
            return wait
        }

        private func failObserver(_ ticket: Int, error: any Error) {
            guard let observer, observer.0 == ticket else { return }
            self.observer = nil
            observer.1.resume(throwing: error)
        }

        func capture(_ driver: PointerClickDriver) throws -> Task<Void, Never> {
            let task = try #require(driver.task)
            tasks.append(task)
            return task
        }

        private func abort() {
            closed = true
            if let observer { failObserver(observer.0, error: CancellationError()) }
            allWaits.forEach { $0.cancel() }
            waits.removeAll()
            allWaits.removeAll()
        }

        func finish(_ task: Task<Void, Never>) async throws {
            var timedOut = false
            let timeout = Task {
                do { try await Task.sleep(for: timeoutDuration) } catch { return }
                timedOut = true
                abort()
            }
            defer { timeout.cancel() }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                Task { @MainActor [weak self] in self?.abort() }
            }
            try Task.checkCancellation()
            if timedOut { throw Failure.taskDidNotFinish }
        }

        func close(_ driver: PointerClickDriver) async {
            if let task = driver.task { tasks.append(task) }
            driver.cancel()
            abort()
            for task in tasks { await task.value }
            tasks.removeAll()
        }
    }

    private func withDriver(timeout: Duration = .seconds(5), _ body: (Clock, PointerClickDriver) async throws -> Void) async throws {
        let clock = Clock(timeout: timeout)
        let driver = PointerClickDriver(sleep: clock.sleep)
        do {
            try await body(clock, driver)
        } catch {
            await clock.close(driver)
            throw error
        }
        await clock.close(driver)
    }

    @Test func anUnregisteredTimerFailsWithinTheBound() async throws {
        try await withDriver(timeout: .milliseconds(20)) { clock, _ in
            do {
                _ = try await clock.next(100_000_000)
                Issue.record("Missing timer unexpectedly registered")
            } catch Clock.Failure.timerNotRegistered {}
        }
    }

    @Test func aStuckTaskTimesOutAndDrainsItsTimer() async throws {
        try await withDriver(timeout: .milliseconds(20)) { clock, driver in
            var edges: [Bool] = []
            driver.click { edges.append($0); return true }
            let task = try clock.capture(driver)
            _ = try await clock.next(100_000_000)
            do {
                try await clock.finish(task)
                Issue.record("Unadvanced timer unexpectedly finished")
            } catch Clock.Failure.taskDidNotFinish {}
            #expect(edges == [true, false])
            #expect(driver.task == nil)
        }
    }

    @Test func cancellationDrainsThePendingTaskAndTimer() async throws {
        var edges: [Bool] = []
        let check = Task {
            try await withDriver { clock, driver in
                driver.click { edges.append($0); return true }
                let task = try clock.capture(driver)
                _ = try await clock.next(100_000_000)
                withUnsafeCurrentTask { $0?.cancel() }
                try await clock.finish(task)
            }
        }
        do {
            try await check.value
            Issue.record("Cancelled completion wait unexpectedly succeeded")
        } catch is CancellationError {}
        #expect(edges == [true, false])
    }

    @Test func tapsHaveDownAndUpIntervalsAndStayOrdered() async throws {
        try await withDriver { clock, driver in
            var edges: [String] = []
            driver.click { edges.append($0 ? "A down" : "A up"); return true }
            driver.click { edges.append($0 ? "B down" : "B up"); return true }
            let task = try clock.capture(driver)
            let firstDown = try await clock.next(100_000_000)
            #expect(edges == ["A down"])
            firstDown.resume()
            let firstUp = try await clock.next(20_000_000)
            #expect(edges == ["A down", "A up"])
            firstUp.resume()
            let secondDown = try await clock.next(100_000_000)
            try await clock.finish(task)
            let finalTask = try clock.capture(driver)
            #expect(edges == ["A down", "A up", "B down"])
            secondDown.resume()
            let secondUp = try await clock.next(20_000_000)
            #expect(edges == ["A down", "A up", "B down", "B up"])
            secondUp.resume()
            try await clock.finish(finalTask)
            #expect(driver.task == nil)
        }
    }

    @Test func cancellationReleasesOnceAndDropsQueuedClicks() async throws {
        try await withDriver { clock, driver in
            var edges: [String] = []
            driver.click { edges.append($0 ? "A down" : "A up"); return true }
            driver.click { edges.append($0 ? "queued down" : "queued up"); return true }
            let oldTask = try clock.capture(driver)
            let oldDown = try await clock.next(100_000_000)
            driver.cancel()
            #expect(edges == ["A down", "A up"])
            oldDown.resume()
            try await clock.finish(oldTask)
            #expect(edges == ["A down", "A up"])
            #expect(driver.task == nil)
            // A new click must start itself rather than a cancelled queued target.
            driver.click { edges.append($0 ? "C down" : "C up"); return true }
            let newTask = try clock.capture(driver)
            let newDown = try await clock.next(100_000_000)
            newDown.resume()
            let newUp = try await clock.next(20_000_000)
            #expect(edges == ["A down", "A up", "C down", "C up"])
            newUp.resume()
            try await clock.finish(newTask)
            #expect(driver.task == nil)
        }
    }

    @Test func staleTargetIsSkippedBeforePressing() async throws {
        try await withDriver { clock, driver in
            var edges: [Bool] = []
            driver.click { _ in false }
            driver.click { edges.append($0); return true }
            let task = try clock.capture(driver)
            let down = try await clock.next(100_000_000)
            #expect(edges == [true])
            down.resume()
            let up = try await clock.next(20_000_000)
            #expect(edges == [true, false])
            up.resume()
            try await clock.finish(task)
            #expect(driver.task == nil)
        }
    }

    @Test func oldTimerCannotReleaseANewerClick() async throws {
        try await withDriver { clock, driver in
            var edges: [String] = []
            driver.click { edges.append($0 ? "A down" : "A up"); return true }
            let oldTask = try clock.capture(driver)
            let oldDown = try await clock.next(100_000_000)
            driver.cancel()
            driver.click { edges.append($0 ? "B down" : "B up"); return true }
            let newTask = try clock.capture(driver)
            let newDown = try await clock.next(100_000_000)
            oldDown.resume()
            try await clock.finish(oldTask)
            #expect(edges == ["A down", "A up", "B down"])
            newDown.resume()
            let newUp = try await clock.next(20_000_000)
            #expect(edges == ["A down", "A up", "B down", "B up"])
            newUp.resume()
            try await clock.finish(newTask)
            #expect(driver.task == nil)
        }
    }
}
