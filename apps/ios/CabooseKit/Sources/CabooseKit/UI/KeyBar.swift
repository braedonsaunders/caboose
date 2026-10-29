#if canImport(UIKit)
import UIKit

/// One accessory for remote apps, desktop input and native terminals. The dismissal
/// control stays above the scrolling keys, so it never moves into toolbar overflow.
@MainActor
public final class KeyBar: UIInputView, UIInputViewAudioFeedback {
    public enum Action {
        case key(String)
        case text(String)
        case modifier(String)
        case autocorrect
        case dismissKeyboard
    }

    public var onAction: ((Action) -> Void)?
    private var modifierButtons: [String: UIButton] = [:]
    private var autocorrectButton: UIButton?
    private var repeatTimer: Timer?
    public var enableInputClicksWhenVisible: Bool { true }

    public init(showsAutocorrect: Bool = true) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 88), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let header = UIStackView()
        header.axis = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false
        if showsAutocorrect {
            let button = button(title: "Aa", label: String(localized: "Autocorrect"), action: .autocorrect)
            autocorrectButton = button
            header.addArrangedSubview(button)
        }
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(button(image: "keyboard.chevron.compact.down", label: String(localized: "Hide Keyboard"), action: .dismissKeyboard))
        addSubview(header)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 88),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        let items: [(String, String, Action)] = [
            ("esc", "Escape", .key("Escape")), ("tab", "Tab", .key("Tab")),
            ("ctrl", "Control", .modifier("control")), ("alt", "Option", .modifier("mod1")),
            ("←", "Left", .key("Left")), ("↑", "Up", .key("Up")),
            ("↓", "Down", .key("Down")), ("→", "Right", .key("Right")),
        ] + ["|", "~", "/", "-", "_", "`", "\\", ":", "*", "$"].map { ($0, $0, .text($0)) } + [
            ("home", "Home", .key("Home")), ("end", "End", .key("End")),
            ("pgup", "Page Up", .key("Page_Up")), ("pgdn", "Page Down", .key("Page_Down")),
        ]
        for (title, label, action) in items {
            let repeats: Bool
            if case .key(let name) = action { repeats = ["Left", "Up", "Down", "Right", "Page_Up", "Page_Down"].contains(name) }
            else { repeats = false }
            let button = button(title: title, label: label, action: action, repeats: repeats)
            if case .modifier(let name) = action { modifierButtons[name] = button }
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    public func show(activeModifiers: Set<String>) {
        for (name, button) in modifierButtons { highlight(button, activeModifiers.contains(name)) }
    }

    public func show(autocorrect: Bool) {
        guard let autocorrectButton else { return }
        highlight(autocorrectButton, autocorrect)
        autocorrectButton.accessibilityValue = autocorrect ? String(localized: "On") : String(localized: "Off")
    }

    private func button(title: String? = nil, image: String? = nil, label: String, action: Action, repeats: Bool = false) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        configuration.image = image.flatMap { UIImage(systemName: $0) }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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

    private func highlight(_ button: UIButton, _ on: Bool) {
        let previous = button.configuration
        var configuration = on ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        configuration.title = previous?.title
        configuration.contentInsets = previous?.contentInsets ?? .zero
        configuration.titleTextAttributesTransformer = previous?.titleTextAttributesTransformer
        configuration.baseForegroundColor = on ? UIColor(red: 14/255, green: 22/255, blue: 38/255, alpha: 1) : .label
        button.tintColor = on ? UIColor(red: 1, green: 0.73, blue: 0.3, alpha: 1) : nil
        button.configuration = configuration
        button.accessibilityTraits = on ? [.button, .selected] : .button
    }

    private func press(_ action: Action, repeating: Bool) {
        UIDevice.current.playInputClick()
        onAction?(action)
        guard repeating else { return }
        stopRepeating()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onAction?(action) }
                }
            }
        }
    }

    private func stopRepeating() { repeatTimer?.invalidate(); repeatTimer = nil }
}
#endif
