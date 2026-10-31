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

    @Test func missingTextOrCursorReportsNeverOpenTheKeyboard() {
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: nil) == nil)
        #expect(request.keyboardWanted(at: 11.3, serial: 5, isText: nil) == false)
        #expect(request.keyboardWanted(at: 20, serial: 4, isText: nil) == false)
    }

    @Test func tappingWhatTakesNoTextHidesTheKeyboard() {
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: false, keyboardVisible: true) == false)
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: true, keyboardVisible: true) == true)
        // Without evidence either way, a keyboard that is up stays up.
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: nil, keyboardVisible: true) == nil)
        #expect(request.keyboardWanted(at: 11.3, serial: 5, isText: nil, keyboardVisible: true) == true)
        // Once dismissed, an ordinary pointer does not reopen it.
        #expect(request.keyboardWanted(at: 10.4, serial: 5, isText: false, keyboardVisible: false) == false)
    }
}
