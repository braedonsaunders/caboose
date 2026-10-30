import Foundation

extension GamepadReport {
    /// A controller in the W3C standard mapping (the on-screen controller's, and a paired
    /// controller's as read) as the computer's gamepad: a button counts as pressed past half its
    /// travel, sticks turn up-positive, and the triggers become the last two axes.
    public init(_ state: GameGamepadState) {
        let pairs: [(GameGamepadState.Button, Bit)] = [
            (.south, .south), (.east, .east), (.west, .west), (.north, .north),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.select, .view), (.start, .menu), (.home, .home), (.leftStick, .leftStick), (.rightStick, .rightStick),
            (.up, .dpadUp), (.down, .dpadDown), (.left, .dpadLeft), (.right, .dpadRight),
        ]
        var buttons = 0
        for (button, bit) in pairs where state[button] > 0.5 { buttons |= bit.mask }
        func stick(_ value: Double) -> Double { value.isNaN ? 0 : min(1, max(-1, value)) }
        func trigger(_ value: Double) -> Double { value.isNaN ? 0 : min(1, max(0, value)) }
        // The standard mapping's y is down-positive; the computer's is up-positive.
        let axes = [stick(state[.leftX]), -stick(state[.leftY]), stick(state[.rightX]), -stick(state[.rightY]),
                    trigger(state[.leftTrigger]), trigger(state[.rightTrigger])].map { $0 == 0 ? 0 : $0 }
        self.init(buttons: buttons, axes: axes)
    }
}
