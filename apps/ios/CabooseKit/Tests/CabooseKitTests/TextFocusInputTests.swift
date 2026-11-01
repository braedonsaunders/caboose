import Testing
@testable import CabooseKit

@Suite struct TextFocusInputTests {
    @Test func aFieldRaisesTheKeyboardAndLeavingItReturns() {
        var policy = TextFocusInput()
        #expect(policy.focus(true, current: .trackpad) == .combo)
        #expect(policy.focus(true, current: .combo) == nil)
        #expect(policy.focus(false, current: .combo) == .trackpad)
        #expect(policy.raisedFrom == nil)
    }

    @Test func onlyTheTrackpadPageIsRaised() {
        var policy = TextFocusInput()
        for page in [LaptopLayout.Input.keyboard, .combo, .gamepad] {
            #expect(policy.focus(true, current: page) == nil)
            #expect(policy.focus(false, current: page) == nil)
        }
    }

    @Test func aPageTheOwnerPicksStays() {
        var policy = TextFocusInput()
        _ = policy.focus(true, current: .trackpad)
        policy.chose(.keyboard)
        #expect(policy.focus(false, current: .keyboard) == nil)
        // Still on the raised page, but the owner moved on from it: nothing to undo.
        _ = policy.focus(true, current: .trackpad)
        #expect(policy.focus(false, current: .gamepad) == nil)
    }
}
