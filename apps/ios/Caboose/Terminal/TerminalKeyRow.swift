import CabooseKit
import UIKit

/// The row above the keyboard with the keys a shell needs that the phone keyboard lacks.
/// Ctrl and Alt are sticky: tap one, and the next key, from this row or the keyboard, gets it.
/// Arrow keys repeat while held.
@MainActor
final class TerminalKeyRow: UIInputView, UIInputViewAudioFeedback {
    enum Action {
        case key(TerminalKeys.Key)
        case control
        case alt
        case dismissKeyboard
    }

    var onAction: ((Action) -> Void)?
    private var controlButton: UIButton?
    private var altButton: UIButton?
    private var repeatTimer: Timer?

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let dismiss = button(image: "keyboard.chevron.compact.down", label: String(localized: "Hide Keyboard"), action: .dismissKeyboard)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 50),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
        let control = button(title: "ctrl", label: String(localized: "Control"), action: .control)
        let alt = button(title: "alt", label: String(localized: "Option"), action: .alt)
        controlButton = control
        altButton = alt
        let items: [UIButton] = [
            button(title: "esc", label: String(localized: "Escape"), action: .key(.escape)),
            button(title: "tab", label: String(localized: "Tab"), action: .key(.tab)),
            control, alt,
            button(image: "arrow.left", label: String(localized: "Left"), action: .key(.left), repeats: true),
            button(image: "arrow.up", label: String(localized: "Up"), action: .key(.up), repeats: true),
            button(image: "arrow.down", label: String(localized: "Down"), action: .key(.down), repeats: true),
            button(image: "arrow.right", label: String(localized: "Right"), action: .key(.right), repeats: true),
        ] + ["|", "~", "/", "-", "_", "`", "\\", ":", "*", "$"].map { button(title: $0, label: $0, action: .key(.text($0))) } + [
            button(title: "home", label: String(localized: "Home"), action: .key(.home)),
            button(title: "end", label: String(localized: "End"), action: .key(.end)),
            button(title: "pgup", label: String(localized: "Page Up"), action: .key(.pageUp), repeats: true),
            button(title: "pgdn", label: String(localized: "Page Down"), action: .key(.pageDown), repeats: true),
        ]
        items.forEach(stack.addArrangedSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows which sticky modifiers the next key will get.
    func show(control: Bool, alt: Bool) {
        if let controlButton { highlight(controlButton, control) }
        if let altButton { highlight(altButton, alt) }
    }

    private func highlight(_ button: UIButton, _ on: Bool) {
        var configuration = button.configuration
        configuration?.baseForegroundColor = on ? UIColor(red: 0x0E / 255, green: 0x16 / 255, blue: 0x26 / 255, alpha: 1) : .label
        configuration?.background.backgroundColor = on ? TerminalTheme.amber : nil
        button.configuration = configuration
        button.accessibilityTraits = on ? [.button, .selected] : .button
    }

    private func button(title: String? = nil, image: String? = nil, label: String, action: Action, repeats: Bool = false) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.baseForegroundColor = .label
        if let title {
            configuration.title = title
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
                return attributes
            }
        }
        if let image {
            configuration.image = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        if repeats {
            button.addAction(UIAction { [weak self] _ in self?.press(action, repeating: true) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                button.addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
            }
        } else {
            button.addAction(UIAction { [weak self] _ in self?.press(action, repeating: false) }, for: .touchUpInside)
        }
        return button
    }

    private func press(_ action: Action, repeating: Bool) {
        UIDevice.current.playInputClick()
        onAction?(action)
        guard repeating else { return }
        stopRepeating()
        // Repeat like a held key: a pause, then a steady rate.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.onAction?(action) }
                }
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
