import Foundation

/// Laptop's input following text focus: the Trackpad page turns into Keyboard & Trackpad
/// when a text field on the computer takes focus, and back when focus leaves it. Only a
/// change it made itself is undone; a page the owner picks in between stays.
public struct TextFocusInput: Equatable, Sendable {
    /// The page to return to, while a field holds the keyboard this raised.
    public private(set) var raisedFrom: LaptopLayout.Input?

    public init() {}

    /// Text focus is now `focused` with `current` showing: the page to show, if it changes.
    public mutating func focus(_ focused: Bool, current: LaptopLayout.Input) -> LaptopLayout.Input? {
        if focused {
            guard raisedFrom == nil, current == .trackpad else { return nil }
            raisedFrom = current
            return .combo
        }
        guard let back = raisedFrom else { return nil }
        raisedFrom = nil
        return current == .combo ? back : nil
    }

    /// The owner chose `input`: anything raised stays where they put it.
    public mutating func chose(_ input: LaptopLayout.Input) {
        if input != .combo { raisedFrom = nil }
    }
}
