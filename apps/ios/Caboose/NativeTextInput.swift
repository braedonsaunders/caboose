import CabooseKit
import SwiftUI
import UIKit

/// App-owned text stays in UIKit's editor: selection, marked text, dictation, paste,
/// undo and accessibility all use the native text system. Only the accessory is Caboose's.
struct NativeTextInput: UIViewRepresentable {
    let title: String
    @Binding var text: String
    var focus: Binding<Bool>?
    var lines: ClosedRange<Int> = 1...1
    var secure = false
    var keyboard: UIKeyboardType = .default
    var capitalization: UITextAutocapitalizationType = .sentences
    var correction = true
    var contentType: UITextContentType?
    var monospaced = false
    var submit: (() -> Void)?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, text: Binding<String>, focus: Binding<Bool>? = nil,
         lines: ClosedRange<Int> = 1...1, secure: Bool = false,
         keyboard: UIKeyboardType = .default, capitalization: UITextAutocapitalizationType = .sentences,
         correction: Bool = true, contentType: UITextContentType? = nil,
         monospaced: Bool = false, submit: (() -> Void)? = nil) {
        self.title = title; _text = text; self.focus = focus; self.lines = lines
        self.secure = secure; self.keyboard = keyboard; self.capitalization = capitalization
        self.correction = correction; self.contentType = contentType
        self.monospaced = monospaced; self.submit = submit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NativeEditor {
        let view = NativeEditor()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: NativeEditor, context: Context) {
        context.coordinator.parent = self
        // Never replace marked text or reset selection on a streaming/model update.
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            view.text = text
            let start = min(selection.location, view.text.utf16.count)
            view.selectedRange = NSRange(location: start, length: min(selection.length, view.text.utf16.count - start))
        }
        view.placeholder.text = title
        view.placeholder.isHidden = !view.text.isEmpty
        view.accessibilityLabel = title
        let font = UIFont.preferredFont(forTextStyle: .body)
        view.font = monospaced ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
        view.adjustsFontForContentSizeCategory = true
        view.placeholder.font = view.font
        if view.isSecureTextEntry != secure { view.isSecureTextEntry = secure }
        view.keyboardType = keyboard
        view.autocapitalizationType = capitalization
        if context.coordinator.configuredCorrection != correction {
            context.coordinator.configuredCorrection = correction
            view.autocorrectionType = correction && !secure ? .default : .no
        }
        view.keyBar.show(autocorrect: view.autocorrectionType != .no)
        view.textContentType = contentType
        view.returnKeyType = submit == nil ? (lines.upperBound == 1 ? .done : .default) : .send
        view.isEditable = enabled
        let intent = enabled && (focus?.wrappedValue ?? false)
        // A native tap/Hide owns focus until the caller changes its request. Ordinary
        // SwiftUI updates never re-issue becomeFirstResponder after native dismissal.
        if (focus != nil || !enabled), context.coordinator.focusIntent != intent {
            context.coordinator.focusIntent = intent
            view.wantsFocus = intent
            if intent { view.requestFocus() }
            else if view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeEditor, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let clamped = min(max(height, line * CGFloat(lines.lowerBound)), line * CGFloat(lines.upperBound))
        uiView.isScrollEnabled = height > clamped + 1
        return CGSize(width: width, height: ceil(clamped))
    }

    static func dismantleUIView(_ view: NativeEditor, coordinator: Coordinator) {
        view.wantsFocus = false
        view.delegate = nil
        view.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextInput
        var focusIntent = false
        var configuredCorrection: Bool?
        init(_ parent: NativeTextInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? NativeEditor)?.placeholder.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            focusIntent = true
            if parent.focus?.wrappedValue == false { parent.focus?.wrappedValue = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            (textView as? NativeEditor)?.wantsFocus = false
            focusIntent = false
            if parent.focus?.wrappedValue == true { parent.focus?.wrappedValue = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // A candidate's Return belongs to the IME, not Send.
            if text == "\n", textView.markedTextRange == nil {
                if let submit = parent.submit { submit(); return false }
                if parent.lines.upperBound == 1 { textView.resignFirstResponder(); return false }
            }
            return true
        }
    }
}

/// The same KeyBar instance type used by desktop input and Terminal. Native fields
/// interpret navigation as text positions; terminal escape sequences never enter drafts.
final class NativeEditor: UITextView {
    let keyBar = KeyBar()
    let placeholder = UILabel()
    var wantsFocus = false
    private var modifiers: Set<String> = []

    init() {
        super.init(frame: .zero, textContainer: nil)
        inputAccessoryView = keyBar
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        keyBar.onAction = { [weak self] action in self?.perform(action) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func didMoveToWindow() { super.didMoveToWindow(); requestFocus() }
    func requestFocus() { if wantsFocus, window != nil, isEditable { becomeFirstResponder() } }

    private func perform(_ action: KeyBar.Action) {
        switch action {
        case .dismissKeyboard:
            wantsFocus = false
            modifiers = []
            keyBar.show(activeModifiers: modifiers)
            resignFirstResponder()
        case .autocorrect:
            guard !isSecureTextEntry else { return }
            autocorrectionType = autocorrectionType == .no ? .default : .no
            keyBar.show(autocorrect: autocorrectionType != .no)
            reloadInputViews()
        case .modifier(let name):
            if !modifiers.insert(name).inserted { modifiers.remove(name) }
            keyBar.show(activeModifiers: modifiers)
        case .text(let text):
            insertText(text)
        case .key(let name):
            guard let selection = selectedTextRange else { return }
            if name == "Escape" { unmarkText(); return }
            if name == "Tab" { insertText("\t"); return }
            let backward = ["Left", "Up", "Home", "Page_Up"].contains(name)
            let origin = backward ? selection.start : selection.end
            let storage: UITextStorageDirection = backward ? .backward : .forward
            let direction = UITextDirection(rawValue: storage.rawValue)
            let destination: UITextPosition?
            if name == "Home" || name == "End" {
                destination = modifiers.contains("control") ? (backward ? beginningOfDocument : endOfDocument)
                    : tokenizer.position(from: origin, toBoundary: .line, inDirection: direction)
            } else if name == "Page_Up" || name == "Page_Down" {
                destination = backward ? beginningOfDocument : endOfDocument
            } else if modifiers.contains("mod1") || modifiers.contains("control") {
                destination = tokenizer.position(from: origin, toBoundary: .word, inDirection: direction)
            } else {
                let layout: UITextLayoutDirection = name == "Left" ? .left : name == "Right" ? .right : name == "Up" ? .up : .down
                destination = position(from: origin, in: layout, offset: 1)
            }
            if let destination { selectedTextRange = textRange(from: destination, to: destination) }
            scrollRangeToVisible(selectedRange)
        }
    }
}
