import Testing
@testable import CabooseKit

struct ScrollGestureOwnershipTests {
    @Test func unrelatedRecognizerCannotEndOrChangeThePan() {
        var gesture = ScrollGestureOwnership<Int>()
        gesture.begin(1, contacts: 1)
        let result1 = gesture.end(2)
        #expect(!result1)
        let result2 = gesture.update(2, contacts: 0)
        #expect(!result2)
        let result3 = gesture.update(1, contacts: 1)
        #expect(result3)
        let result4 = gesture.end(1)
        #expect(result4)
        let result5 = gesture.end(1)
        #expect(!result5)
    }

    @Test func contactChangesSuppressTheRemainderUntilANewGesture() {
        for (initial, changed) in [(1, 2), (2, 1)] {
            var gesture = ScrollGestureOwnership<Int>()
            gesture.begin(1, contacts: initial)
            let result6 = gesture.update(1, contacts: changed)
            #expect(!result6)
            #expect(!gesture.isActive)
            let result7 = gesture.update(1, contacts: initial)
            #expect(!result7)
            let result8 = gesture.end(1)
            #expect(!result8)
            gesture.begin(1, contacts: initial)
            let result9 = gesture.update(1, contacts: initial)
            #expect(result9)
        }
    }

    @Test func cancellationRejectsLateEventsAndHardwareHasNoContacts() {
        var gesture = ScrollGestureOwnership<Int>()
        gesture.begin(1, contacts: 1)
        gesture.cancel()
        let result10 = gesture.update(1, contacts: 1)
        #expect(!result10)
        let result11 = gesture.end(1)
        #expect(!result11)
        gesture.begin(2, contacts: 0)
        let result12 = gesture.update(2, contacts: 0)
        #expect(result12)
        let result13 = gesture.end(1)
        #expect(!result13)
        let result14 = gesture.end(2)
        #expect(result14)
    }
}
