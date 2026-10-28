import Foundation

/// A tap asks the guest whether it entered editing; a double tap can also just zoom or
/// select. This request ends after one answer, so later cursor changes cannot reopen a
/// manually dismissed keyboard. Text-input-v3 takes precedence in DisplaySession.
struct TapTextFocus {
    let since: TimeInterval
    let serial: Int

    func keyboardWanted(at now: TimeInterval, serial current: Int, isText: Bool?) -> Bool? {
        let elapsed = now - since
        guard current != serial || elapsed > 0.35 else { return nil }
        if let isText { return isText }
        // Preserve the legacy fallback for guests that report neither text input nor cursors.
        return elapsed > 1.2 ? true : nil
    }
}
