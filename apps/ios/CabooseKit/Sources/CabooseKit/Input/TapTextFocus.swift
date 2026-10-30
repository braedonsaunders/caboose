import Foundation

/// A tap asks the guest whether it entered editing; a double tap can also just zoom or
/// select. This request ends after one answer, so later cursor changes cannot reopen a
/// manually dismissed keyboard. Text-input-v3 takes precedence in DisplaySession.
public struct TapTextFocus {
    let since: TimeInterval
    let serial: Int

    public init(since: TimeInterval, serial: Int) { self.since = since; self.serial = serial }

    public func keyboardWanted(at now: TimeInterval, serial current: Int, isText: Bool?, keyboardVisible: Bool = false) -> Bool? {
        // A tap's cursor heuristic may open input, but cannot revoke the person's
        // explicit keyboard choice. Dismissal belongs to the keyboard's own controls.
        if keyboardVisible { return true }
        let elapsed = now - since
        guard current != serial || elapsed > 0.35 else { return nil }
        if let isText { return isText }
        // Missing cursor/text-input evidence is not an editable field. End the
        // request without opening input; the owner can still request it manually.
        return elapsed > 1.2 ? false : nil
    }
}
