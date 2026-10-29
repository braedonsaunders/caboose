#if canImport(UIKit)
import UIKit

/// One accessory for remote apps, desktop input and native terminals. The dismissal
/// control stays fixed at the top right; grouped keys never scroll horizontally.
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
    private let keys = UIStackView()
    private var activeModifiers: Set<String> = []
    public var enableInputClicksWhenVisible: Bool { true }

    public init(showsAutocorrect: Bool = true) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 88), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let groups = UISegmentedControl(items: [String(localized: "Keys"), String(localized: "Move"), String(localized: "Symbols")])
        groups.selectedSegmentIndex = 0
        groups.accessibilityLabel = String(localized: "Keyboard controls")
        groups.addAction(UIAction { [weak self, weak groups] _ in
            self?.showGroup(groups?.selectedSegmentIndex ?? 0)
        }, for: .valueChanged)
        header.addArrangedSubview(groups)
        if showsAutocorrect {
            let toggle = button(title: "Aa", label: String(localized: "Autocorrect"), action: .autocorrect)
            autocorrectButton = toggle
            toggle.widthAnchor.constraint(equalToConstant: 44).isActive = true
            header.addArrangedSubview(toggle)
        }
        let hide = button(image: "keyboard.chevron.compact.down", label: String(localized: "Hide Keyboard"), action: .dismissKeyboard)
        hide.widthAnchor.constraint(equalToConstant: 44).isActive = true
        header.addArrangedSubview(hide)
        addSubview(header)
        keys.axis = .horizontal
        keys.distribution = .fillEqually
        keys.spacing = 5
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keys)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 88),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            keys.topAnchor.constraint(equalTo: header.bottomAnchor),
            keys.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showGroup(0)
    }

    private func showGroup(_ group: Int) {
        stopRepeating()
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        modifierButtons.removeAll()
        let items: [(String, String, Action)]
        switch group {
        case 1:
            items = [("Home", "Home", .key("Home")), ("↑", "Up", .key("Up")), ("End", "End", .key("End")),
                     ("←", "Left", .key("Left")), ("↓", "Down", .key("Down")), ("→", "Right", .key("Right"))]
        case 2:
            items = [("/", "Slash", .text("/")), ("\\", "Backslash", .text("\\")), ("|", "Pipe", .text("|")),
                     ("~", "Tilde", .text("~")), ("_", "Underscore", .text("_")), ("$", "Dollar", .text("$"))]
        default:
            items = [("esc", "Escape", .key("Escape")), ("tab", "Tab", .key("Tab")),
                     ("ctrl", "Control", .modifier("control")), ("alt", "Option", .modifier("mod1")),
                     ("←", "Left", .key("Left")), ("→", "Right", .key("Right"))]
        }
        for (title, label, action) in items {
            let repeats: Bool
            if case .key(let name) = action { repeats = ["Left", "Up", "Down", "Right"].contains(name) }
            else { repeats = false }
            let key = button(title: title, label: label, action: action, repeats: repeats)
            if case .modifier(let name) = action { modifierButtons[name] = key }
            if group == 1 && (title == "Home" || title == "End") {
                let page = title == "Home" ? "Page_Up" : "Page_Down"
                key.menu = UIMenu(children: [UIAction(title: title == "Home" ? String(localized: "Page Up") : String(localized: "Page Down")) { [weak self] _ in self?.press(.key(page), repeating: false) }])
                key.accessibilityHint = String(localized: "Touch and hold for page navigation")
            }
            if group == 2 {
                let alternatives: [String: [String]] = ["/": [":"], "\\": ["`"], "|": ["&"], "~": ["^"], "_": ["-"], "$": ["*", "%", "#"]]
                key.menu = UIMenu(children: (alternatives[title] ?? []).map { symbol in
                    UIAction(title: symbol) { [weak self] _ in self?.press(.text(symbol), repeating: false) }
                })
                key.accessibilityHint = String(localized: "Touch and hold for related symbols")
            }
            keys.addArrangedSubview(key)
        }
        show(activeModifiers: activeModifiers)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    public func show(activeModifiers: Set<String>) {
        self.activeModifiers = activeModifiers
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
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label

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
        configuration.image = previous?.image
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
