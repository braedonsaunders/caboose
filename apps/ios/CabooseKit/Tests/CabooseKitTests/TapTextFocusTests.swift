import Testing
@testable import CabooseKit

struct TapTextFocusTests {
    let request = TapTextFocus(since: 10, serial: 4)

    @Test func doubleTapWaitsForGuestEditingInsteadOfOpeningKeyboardUnconditionally() {
        #expect(request.keyboardWanted(at: 10.1, serial: 4, isText: false) == nil)
        #expect(request.keyboardWanted(at: 10.1, serial: 5, isText: true) == true)
        #expect(request.keyboardWanted(at: 10.1, serial: 5, isText: false) == false)
    }

    @Test func unchangedCursorAnswersAfterFocusGracePeriod() {
        #expect(request.keyboardWanted(at: 10.4, serial: 4, isText: true) == true)
        #expect(request.keyboardWanted(at: 10.4, serial: 4, isText: false) == false)
    }

    @Test func guestsWithoutTextOrCursorReportsUseExistingFallback() {
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: nil) == nil)
        #expect(request.keyboardWanted(at: 11.3, serial: 5, isText: nil) == true)
    }

    @Test func tappingAFieldCannotDismissAnAlreadyVisibleKeyboard() {
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: false, keyboardVisible: true) == true)
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: nil, keyboardVisible: true) == true)
        // Once explicitly dismissed, an ordinary pointer does not reopen it.
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: false, keyboardVisible: false) == false)
    }
}
