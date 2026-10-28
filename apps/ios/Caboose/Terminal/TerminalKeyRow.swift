import CabooseKit
import UIKit

/// Adapts the shared keyboard accessory to terminal bytes; the visual controls and
/// held-key repetition are the same as desktop and app cards.
@MainActor
final class TerminalKeyRow {
    enum Action {
        case key(TerminalKeys.Key)
        case control
        case alt
        case dismissKeyboard
    }

    let view = KeyBar(showsAutocorrect: false)
    var onAction: ((Action) -> Void)?

    init() {
        view.onAction = { [weak self] action in
            switch action {
            case .modifier("control"): self?.onAction?(.control)
            case .modifier("mod1"): self?.onAction?(.alt)
            case .dismissKeyboard: self?.onAction?(.dismissKeyboard)
            case .text(let text): self?.onAction?(.key(.text(text)))
            case .key(let name):
                let key: TerminalKeys.Key? = switch name {
                case "Escape": .escape
                case "Tab": .tab
                case "Left": .left
                case "Right": .right
                case "Up": .up
                case "Down": .down
                case "Home": .home
                case "End": .end
                case "Page_Up": .pageUp
                case "Page_Down": .pageDown
                default: nil
                }
                if let key { self?.onAction?(.key(key)) }
            default: break
            }
        }
    }

    func show(control: Bool, alt: Bool) {
        var modifiers = Set<String>()
        if control { modifiers.insert("control") }
        if alt { modifiers.insert("mod1") }
        view.show(activeModifiers: modifiers)
    }
}
