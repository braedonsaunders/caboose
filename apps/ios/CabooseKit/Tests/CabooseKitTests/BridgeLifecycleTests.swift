import Testing
@testable import CabooseKit

// #expect captures its expression immutably, so each mutating step is taken first.
@Suite struct BridgeLifecycleTests {
    private func ready() -> BridgeLifecycle {
        var life = BridgeLifecycle()
        life.connect()
        _ = life.setActive(true)
        return life
    }

    @Test func showsOneRequestAtATimeInOrder() throws {
        var life = ready()
        let first = life.receive("a", dialogs: true), second = life.receive("b", dialogs: true), again = life.receive("a", dialogs: true)
        #expect(first == .queued && second == .queued && again == .duplicate)
        let a = try #require(life.next())
        let none = life.next(), whileShown = life.receive("a", dialogs: true)
        #expect(a.request == "a" && none == nil && whileShown == .duplicate)
        let answered = life.finish(a), answeredTwice = life.finish(a)
        #expect(answered && !answeredTwice)
        let b = life.next()
        #expect(b?.request == "b")
    }

    @Test func declinesWhenTheOwnerUsesComputerDialogsOrNothingIsConnected() {
        var life = ready()
        let off = life.receive("a", dialogs: false)
        _ = life.disconnect()
        let unconnected = life.receive("b", dialogs: true)
        #expect(off == .declined && unconnected == .declined)
        var full = ready()
        let queued = (0..<BridgeLifecycle.queueLimit).map { full.receive("\($0)", dialogs: true) }
        let over = full.receive("over", dialogs: true)
        #expect(queued.allSatisfy { $0 == .queued } && over == .declined)
    }

    /// A picker that returns after the phone switched computers must not upload or answer.
    @Test func aResetFencesEveryCallbackFromBefore() throws {
        var life = ready()
        _ = life.receive("a", dialogs: true)
        let shown = try #require(life.next())
        let dismissed = life.reset()
        let stillCurrent = life.isCurrent(shown), answered = life.finish(shown)
        #expect(dismissed == shown && !stillCurrent && !answered)
        life.connect()
        _ = life.receive("b", dialogs: true)
        let next = try #require(life.next())
        let lateAnswer = life.finish(shown)
        #expect(next.generation != shown.generation)
        #expect(!lateAnswer, "the old dismissal cannot clear the new request")
        #expect(life.isCurrent(next))
    }

    @Test func losingTheConnectionOrTheForegroundReturnsEverythingToTheComputer() throws {
        var life = ready()
        _ = life.receive("a", dialogs: true)
        _ = life.receive("b", dialogs: true)
        let shown = try #require(life.next())
        let dismissed = life.disconnect()
        #expect(dismissed == shown && life.queue.isEmpty && life.current == nil)
        life.connect()
        _ = life.receive("c", dialogs: true)
        let c = try #require(life.next())
        let backgrounded = life.setActive(false)
        _ = life.setActive(true)
        let stale = life.next()
        #expect(backgrounded == c)
        #expect(stale == nil, "nothing stale comes back in the foreground")
        #expect(!life.isCurrent(c))
    }

    @Test func aWithdrawnRequestIsDroppedOrDismissed() throws {
        var life = ready()
        _ = life.receive("a", dialogs: true)
        _ = life.receive("b", dialogs: true)
        let a = try #require(life.next())
        let waiting = life.withdraw("b"), shown = life.withdraw("a"), next = life.next()
        #expect(waiting == nil && shown == a && next == nil)
        #expect(!life.isCurrent(a))
    }
}

@Suite struct LocationConsentTests {
    @Test func consentBelongsToOneComputer() {
        var consent = LocationConsent()
        consent.set(true, for: "computer-a")
        #expect(consent.allows("computer-a"))
        #expect(!consent.allows("computer-b"), "switching computers does not carry consent")
        #expect(!consent.allows(nil))
        consent.set(false, for: "computer-a")
        #expect(!consent.allows("computer-a"))
        #expect(LocationConsent(["b", "a"]).stored == ["a", "b"])
    }
}
