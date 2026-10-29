import SwiftUI
import UIKit

/// A compact, focus-free keyboard for the lower two thirds of the laptop control panel.
struct LaptopComboKeyboard: View {
    var onText: (String) -> Void
    var onKey: (String) -> Void
    var onNativeKeyboard: () -> Void

    @State private var page: Page = .letters
    @State private var shift = false
    @State private var capsLock = false
    @State private var lastShiftTap: TimeInterval = 0

    private enum Page { case letters, numbers, symbols }
    private let gap: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let unit = max(1, (geometry.size.width - 16 - gap * 9) / 10)
            VStack(spacing: gap) {
                characterRow(firstRow)
                characterRow(secondRow)
                    .padding(.horizontal, page == .letters ? (unit + gap) / 2 : 0)
                HStack(spacing: gap) {
                    shiftKey.frame(width: unit * 1.4)
                    ForEach(thirdRow, id: \.self) { character in
                        characterKey(character)
                    }
                    ComboDeleteKey { onKey("BackSpace") }
                        .frame(width: unit * 1.4)
                }
                HStack(spacing: gap) {
                    key(page == .letters ? "123" : "ABC", label: page == .letters ? "Numbers and punctuation" : "Letters") {
                        page = page == .letters ? .numbers : .letters
                    }
                    .frame(width: unit * 1.4)
                    Button(action: onNativeKeyboard) {
                        Image(systemName: "globe")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Open full keyboard")
                    .accessibilityHint("Use emoji, dictation, or another language")
                    .frame(width: unit * 1.1)
                    key("space", label: "Space") { type(" ") }
                    characterKey(".").frame(width: unit)
                    Button { onKey("Return") } label: {
                        Image(systemName: "return")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .accessibilityLabel("Return")
                    .frame(width: unit * 1.7)
                }
            }
            .buttonStyle(ComboKeyStyle())
            .font(.system(size: min(22, max(16, unit * 0.58)), weight: .regular))
            .padding(8)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(uiColor: .systemGray5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compact keyboard")
    }

    private var firstRow: [String] {
        switch page {
        case .letters: return Array("qwertyuiop").map(String.init)
        case .numbers: return Array("1234567890").map(String.init)
        case .symbols: return Array("[]{}#%^*+=").map(String.init)
        }
    }

    private var secondRow: [String] {
        switch page {
        case .letters: return Array("asdfghjkl").map(String.init)
        case .numbers: return ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        case .symbols: return ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
        }
    }

    private var thirdRow: [String] {
        page == .letters ? Array("zxcvbnm").map(String.init) : [".", ",", "?", "!", "'", "`", "="]
    }

    @ViewBuilder private var shiftKey: some View {
        if page == .letters {
            Button(action: toggleShift) {
                Image(systemName: capsLock ? "capslock.fill" : (shift ? "shift.fill" : "shift"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(ComboKeyStyle(selected: shift || capsLock))
            .accessibilityLabel("Shift")
            .accessibilityValue(capsLock ? "Caps Lock on" : (shift ? "On" : "Off"))
            .accessibilityHint("Capitalizes the next letter. Use the Toggle Caps Lock action to lock capitals.")
            .accessibilityAction(named: "Toggle Caps Lock") {
                capsLock.toggle()
                shift = false
                lastShiftTap = 0
            }
        } else {
            key(page == .numbers ? "#+=" : "123", label: page == .numbers ? "More symbols" : "Numbers") {
                page = page == .numbers ? .symbols : .numbers
            }
        }
    }

    private func characterRow(_ characters: [String]) -> some View {
        HStack(spacing: gap) {
            ForEach(characters, id: \.self) { character in characterKey(character) }
        }
    }

    private func characterKey(_ character: String) -> some View {
        let value = page == .letters && (shift || capsLock) ? character.uppercased() : character
        return key(value, label: value) { type(value) }
    }

    private func key(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(label)
    }

    private func type(_ value: String) {
        onText(value)
        shift = false
        lastShiftTap = 0
    }

    private func toggleShift() {
        let now = ProcessInfo.processInfo.systemUptime
        if capsLock {
            capsLock = false
            shift = false
            lastShiftTap = 0
        } else if shift && now - lastShiftTap < 0.4 {
            capsLock = true
            shift = false
            lastShiftTap = 0
        } else {
            shift.toggle()
            lastShiftTap = now
        }
    }
}

private struct ComboKeyStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.black : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.white : Color(uiColor: configuration.isPressed ? .systemGray2 : .systemGray3))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// UIKit owns the touch lifecycle so a cancelled touch cannot leave deletion repeating.
private struct ComboDeleteKey: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> ComboDeleteButton { ComboDeleteButton(action: action) }
    func updateUIView(_ uiView: ComboDeleteButton, context: Context) { uiView.action = action }
    static func dismantleUIView(_ uiView: ComboDeleteButton, coordinator: ()) { uiView.stopRepeating() }
}

private final class ComboDeleteButton: UIButton {
    var action: () -> Void
    private var repeatTimer: Timer?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setImage(UIImage(systemName: "delete.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)), for: .normal)
        tintColor = .label
        backgroundColor = .systemGray3
        layer.cornerRadius = 7
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        accessibilityLabel = "Delete"
        accessibilityHint = "Touch and hold to delete repeatedly"
        addTarget(self, action: #selector(startRepeating), for: .touchDown)
        addTarget(self, action: #selector(stopRepeating), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        NotificationCenter.default.addObserver(self, selector: #selector(stopRepeating), name: UIApplication.willResignActiveNotification, object: nil)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemGray2 : .systemGray3 }
    }

    override func accessibilityActivate() -> Bool {
        action()
        return true
    }

    @objc private func startRepeating() {
        stopRepeating()
        action()
        let timer = Timer(timeInterval: 0.42, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.action()
                let repeating = Timer(timeInterval: 0.075, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.action() }
                }
                self.repeatTimer = repeating
                RunLoop.main.add(repeating, forMode: .common)
            }
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    deinit {
        repeatTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
