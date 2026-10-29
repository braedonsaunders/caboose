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
    private var autocorrect = false
    private let showsAutocorrect: Bool
    private let groupButton = UIButton(type: .system)
    private var selectedGroup = 0
    private var visibleKeyCount = 4
    private var repeatTimer: Timer?
    private weak var assistant: UITextInputAssistantItem?
    private var nativeModifiers: [String: UIBarButtonItem] = [:]
    private let keys = UIStackView()
    private var activeModifiers: Set<String> = []
    public var enableInputClicksWhenVisible: Bool { true }

    public init(showsAutocorrect: Bool = true) {
        self.showsAutocorrect = showsAutocorrect
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        backgroundColor = .systemGray5
        isOpaque = true
        // UIInputView's keyboard style supplies the system keyboard surface.
        // The controls themselves are plain, without independent glass backgrounds.
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        groupButton.configuration = keyConfiguration(image: "slider.horizontal.3")
        groupButton.accessibilityLabel = String(localized: "Keyboard controls")
        groupButton.showsMenuAsPrimaryAction = true
        groupButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(groupButton)
        keys.axis = .horizontal
        keys.distribution = .fillEqually
        keys.spacing = 2
        row.addArrangedSubview(keys)
        let hide = button(image: "keyboard.chevron.compact.down", label: String(localized: "Hide Keyboard"), action: .dismissKeyboard)
        hide.widthAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(hide)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        showGroup(0)
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 48) }

    /// iPad supplies a native shortcut row. A wide iPhone (including an opened foldable)
    /// still needs the attached shared header; width alone does not imply that row exists.
    public func accessory(for view: UIView) -> UIView? {
        let item = view.inputAssistantItem
        let nativeRow = view.traitCollection.userInterfaceIdiom == .pad
        if nativeRow {
            if assistant !== item || item.trailingBarButtonGroups.isEmpty {
                assistant = item
                installAssistant(item)
            }
            return nil
        }
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        assistant = nil
        return self
    }

    private func installAssistant(_ item: UITextInputAssistantItem) {
        item.allowsHidingShortcuts = false
        let menu = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), menu: groupButton.menu)
        menu.accessibilityLabel = String(localized: "Keyboard controls")
        nativeModifiers.removeAll()
        var leading = [menu]
        for (title, label, action) in items(for: selectedGroup).prefix(4) {
            let key = UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in
                self?.press(action, repeating: false)
            })
            key.accessibilityLabel = label
            if case .modifier(let name) = action { nativeModifiers[name] = key }
            leading.append(key)
        }
        let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in
            self?.press(.dismissKeyboard, repeating: false)
        })
        hide.accessibilityLabel = String(localized: "Hide Keyboard")
        let representative = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), menu: groupButton.menu)
        representative.accessibilityLabel = String(localized: "Keyboard controls")
        item.leadingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: leading, representativeItem: representative)]
        item.trailingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: [hide], representativeItem: nil)]
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Six 44-point keys plus fixed menu/Hide controls fit from 378 points.
        // Compact keyboards use four keys; the menu retains every omitted action.
        let count = bounds.width >= 378 ? 6 : 4
        if count != visibleKeyCount {
            visibleKeyCount = count
            showGroup(selectedGroup)
        }
    }

    private var groupTitles: [String] {
        [String(localized: "Keys"), String(localized: "Move"), String(localized: "Symbols")]
    }

    private func items(for group: Int) -> [(String, String, Action)] {
        switch group {
        case 1:
            return [("←", "Left", .key("Left")), ("↑", "Up", .key("Up")),
                    ("↓", "Down", .key("Down")), ("→", "Right", .key("Right")),
                    ("Home", "Home", .key("Home")), ("End", "End", .key("End"))]
        case 2:
            return [("/", "Slash", .text("/")), ("\\", "Backslash", .text("\\")), ("|", "Pipe", .text("|")),
                    ("~", "Tilde", .text("~")), ("_", "Underscore", .text("_")), ("$", "Dollar", .text("$"))]
        default:
            return [("esc", "Escape", .key("Escape")), ("tab", "Tab", .key("Tab")),
                    ("ctrl", "Control", .modifier("control")), ("alt", "Option", .modifier("mod1")),
                    ("←", "Left", .key("Left")), ("→", "Right", .key("Right"))]
        }
    }

    private func relatedActions(for title: String, group: Int) -> [(String, Action)] {
        if group == 1 && (title == "Home" || title == "End") {
            return [(title == "Home" ? String(localized: "Page Up") : String(localized: "Page Down"),
                     .key(title == "Home" ? "Page_Up" : "Page_Down"))]
        }
        guard group == 2 else { return [] }
        let alternatives: [String: [String]] = ["/": [":"], "\\": ["`"], "|": ["&"], "~": ["^"], "_": ["-"], "$": ["*", "%", "#"]]
        return (alternatives[title] ?? []).map { ($0, .text($0)) }
    }

    private func menuAction(title: String, action: Action) -> UIAction {
        let selected: Bool
        if case .modifier(let name) = action { selected = activeModifiers.contains(name) }
        else { selected = false }
        return UIAction(title: title, state: selected ? .on : .off) { [weak self] _ in
            self?.press(action, repeating: false)
        }
    }

    private func updateMenu() {
        let groups = groupTitles.enumerated().map { index, title in
            UIAction(title: title, state: selectedGroup == index ? .on : .off) { [weak self] _ in
                self?.showGroup(index)
            }
        }
        // All actions remain accessible at every width, including long-press alternatives.
        let actionGroups = groupTitles.enumerated().map { index, title in
            UIMenu(title: title, children: items(for: index).flatMap { keyTitle, label, action -> [UIMenuElement] in
                [menuAction(title: label, action: action)] + relatedActions(for: keyTitle, group: index).map {
                    menuAction(title: $0.0, action: $0.1)
                }
            })
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: groups)]
        children.append(contentsOf: actionGroups)
        if showsAutocorrect {
            children.append(UIAction(title: String(localized: "Autocorrect"), image: UIImage(systemName: "textformat"),
                                     state: autocorrect ? .on : .off) { [weak self] _ in
                self?.press(.autocorrect, repeating: false)
            })
        }
        groupButton.menu = UIMenu(children: children)
        if let assistant {
            installAssistant(assistant)
            for (name, item) in nativeModifiers { item.tintColor = activeModifiers.contains(name) ? .systemOrange : .label }
        }
        let modifiers = [("control", "Control"), ("mod1", "Option")]
            .filter { activeModifiers.contains($0.0) }.map { $0.1 }
        groupButton.accessibilityValue = ([groupTitles[selectedGroup]] + modifiers).joined(separator: ", ")
        var configuration = groupButton.configuration
        configuration?.baseForegroundColor = activeModifiers.isEmpty ? .label : .systemBlue
        groupButton.configuration = configuration
    }

    private func showGroup(_ group: Int) {
        stopRepeating()
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        modifierButtons.removeAll()
        selectedGroup = group
        for (title, label, action) in items(for: group).prefix(visibleKeyCount) {
            let repeats: Bool
            if case .key(let name) = action { repeats = ["Left", "Up", "Down", "Right"].contains(name) }
            else { repeats = false }
            let key = button(title: title, label: label, action: action, repeats: repeats)
            if case .modifier(let name) = action { modifierButtons[name] = key }
            let related = relatedActions(for: title, group: group)
            if !related.isEmpty {
                key.menu = UIMenu(children: related.map { menuAction(title: $0.0, action: $0.1) })
                key.accessibilityHint = group == 1
                    ? String(localized: "Touch and hold for page navigation")
                    : String(localized: "Touch and hold for related symbols")
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
        updateMenu()
    }

    public func show(autocorrect: Bool) {
        self.autocorrect = autocorrect
        updateMenu()
    }

    private func keyConfiguration(title: String? = nil, image: String? = nil) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = image.flatMap { UIImage(systemName: $0) }
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        return configuration
    }

    private func button(title: String? = nil, image: String? = nil, label: String, action: Action, repeats: Bool = false) -> UIButton {
        let button: UIButton
        if repeats {
            let repeatingButton = RepeatingKeyButton(type: .system)
            repeatingButton.activate = { [weak self] in self?.press(action, repeating: false) }
            button = repeatingButton
        } else {
            button = UIButton(type: .system)
        }
        button.configuration = keyConfiguration(title: title, image: image)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        var configuration = button.configuration ?? keyConfiguration()
        configuration.baseForegroundColor = on ? .systemBlue : .label
        configuration.background.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.14) : .clear
        configuration.background.cornerRadius = 5
        button.configuration = configuration
        button.accessibilityTraits = on ? [.button, .selected] : .button
    }

    private func press(_ action: Action, repeating: Bool) {
        stopRepeating()
        UIDevice.current.playInputClick()
        onAction?(action)
        guard repeating else { return }
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

/// VoiceOver activation emits one arrow, without starting a touch-held repeat timer.
@MainActor
private final class RepeatingKeyButton: UIButton {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        activate?()
        return true
    }
}
#endif
