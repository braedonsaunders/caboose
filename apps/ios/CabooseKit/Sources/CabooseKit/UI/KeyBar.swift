#if canImport(UIKit)
import UIKit

/// The row above the iOS keyboard: the keys a terminal or code editor needs that the
/// phone keyboard does not have. Ctrl and Alt are sticky — tap, then the next key gets them.
@MainActor
final class KeyBar: UIInputView {
    enum Action {
        case key(String)
        case text(String)
        case modifier(String)
        /// Turns autocorrect, capitals and predictions on or off for this window.
        case autocorrect
    }

    var onAction: ((Action) -> Void)?
    private var modifierButtons: [String: UIButton] = [:]
    private var autocorrectButton: UIButton?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
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
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
        let items: [(String, Action)] = [
            ("Aa", .autocorrect), ("esc", .key("Escape")), ("tab", .key("Tab")), ("ctrl", .modifier("control")), ("alt", .modifier("mod1")),
            ("←", .key("Left")), ("↑", .key("Up")), ("↓", .key("Down")), ("→", .key("Right")),
            ("|", .text("|")), ("~", .text("~")), ("/", .text("/")), ("-", .text("-")), ("_", .text("_")),
            ("`", .text("`")), ("\\", .text("\\")), ("home", .key("Home")), ("end", .key("End")),
            ("pgup", .key("Page_Up")), ("pgdn", .key("Page_Down")),
        ]
        for (title, action) in items {
            var configuration = UIButton.Configuration.glass()
            configuration.title = title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
                var attributes = $0
                attributes.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.onAction?(action)
            })
            if case .modifier(let name) = action { modifierButtons[name] = button }
            if case .autocorrect = action {
                autocorrectButton = button
                button.accessibilityLabel = String(localized: "Autocorrect")
            }
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(activeModifiers: Set<String>) {
        for (name, button) in modifierButtons { highlight(button, activeModifiers.contains(name)) }
    }

    func show(autocorrect: Bool) {
        guard let autocorrectButton else { return }
        highlight(autocorrectButton, autocorrect)
        autocorrectButton.accessibilityValue = autocorrect ? String(localized: "On") : String(localized: "Off")
    }

    private func highlight(_ button: UIButton, _ on: Bool) {
        button.configuration = {
            var configuration = on ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
            configuration.title = button.configuration?.title
            configuration.contentInsets = button.configuration?.contentInsets ?? .zero
            configuration.titleTextAttributesTransformer = button.configuration?.titleTextAttributesTransformer
            return configuration
        }()
    }
}
#endif
