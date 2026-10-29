import Testing
@testable import CabooseKit

struct ScrollGestureOwnershipTests {
    @Test func unrelatedRecognizerCannotEndOrChangeThePan() {
        var gesture = ScrollGestureOwnership<Int>()
        gesture.begin(1, contacts: 1)
        #expect(!gesture.end(2))
        #expect(!gesture.update(2, contacts: 0))
        #expect(gesture.update(1, contacts: 1))
        #expect(gesture.end(1))
        #expect(!gesture.end(1))
    }

    @Test func contactChangesSuppressTheRemainderUntilANewGesture() {
        for (initial, changed) in [(1, 2), (2, 1)] {
            var gesture = ScrollGestureOwnership<Int>()
            gesture.begin(1, contacts: initial)
            #expect(!gesture.update(1, contacts: changed))
            #expect(!gesture.isActive)
            #expect(!gesture.update(1, contacts: initial))
            #expect(!gesture.end(1))
            gesture.begin(1, contacts: initial)
            #expect(gesture.update(1, contacts: initial))
        }
    }

    @Test func cancellationRejectsLateEventsAndHardwareHasNoContacts() {
        var gesture = ScrollGestureOwnership<Int>()
        gesture.begin(1, contacts: 1)
        gesture.cancel()
        #expect(!gesture.update(1, contacts: 1))
        #expect(!gesture.end(1))
        gesture.begin(2, contacts: 0)
        #expect(gesture.update(2, contacts: 0))
        #expect(!gesture.end(1))
        #expect(gesture.end(2))
    }
}
