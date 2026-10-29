#if canImport(UIKit)
import UIKit

/// A view the iOS text system can type into on behalf of a remote app: the software
/// keyboard with autocorrect and QuickPath, dictation, emoji, and marked-text input for
/// Chinese, Japanese and Korean. `UITextInput` edits a `TypingBuffer`, and the buffer's
/// differences reach the subclass as backspaces and text through `send(_:)`.
@MainActor
open class RemoteTextInputView: UIView, UITextInput {
    public private(set) var buffer = TypingBuffer()
    public weak var inputDelegate: UITextInputDelegate?
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    /// Where the remote caret probably is, in this view's points: the candidate bar and
    /// the dictation and IME popovers on iPad anchor to it.
    public var caretAnchor = CGPoint.zero

    /// Prose gets autocorrect, capitals and spell checking; code and terminals get none.
    public var prefersProse = false {
        didSet {
            keyBar.show(autocorrect: prefersProse)
            if prefersProse != oldValue, isFirstResponder { reloadInputViews() }
        }
    }

    private var stickyModifiers = Set<String>()
    public var hasStickyModifiers: Bool { !stickyModifiers.isEmpty }
    public private(set) var autocorrectChoice: Bool?
    private lazy var keyBar: KeyBar = {
        let bar = KeyBar()
        bar.onAction = { [weak self] action in self?.keyBarAction(action) }
        return bar
    }()

    /// Inline Laptop controls use the exact same header and action pipeline.
    public var keyboardControls: KeyBar { keyBar }
    public var inlineKeyboardControls = false {
        didSet { if inlineKeyboardControls != oldValue, isFirstResponder { reloadInputViews() } }
    }
    private let hiddenKeyboard = UIView(frame: .zero)
    open override var inputView: UIView? { inlineKeyboardControls ? hiddenKeyboard : nil }
    public func performKeyboardAction(_ action: KeyBar.Action) { keyBarAction(action) }
    open override var inputAccessoryView: UIView? {
        if inlineKeyboardControls {
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            return nil
        }
        return keyBar.accessory(for: self)
    }
    private var wideKeyboardHeader = false
    open override func layoutSubviews() {
        super.layoutSubviews()
        let wide = (window?.bounds.width ?? bounds.width) >= 600
        if wide != wideKeyboardHeader {
            wideKeyboardHeader = wide
            if isFirstResponder, !inlineKeyboardControls { reloadInputViews() }
        }
    }

    /// Sends a complete press/release to the view's current remote target.
    open func sendKey(_ stroke: KeyStroke, modifiers: [String]) {}
    /// Subclasses also clear their shared visibility state or pending focus requests.
    open func dismissKeyboard() { resignFirstResponder() }

    private func keyBarAction(_ action: KeyBar.Action) {
        switch action {
        case .modifier(let name):
            if stickyModifiers.contains(name) { stickyModifiers.remove(name) } else { stickyModifiers.insert(name) }
            keyBar.show(activeModifiers: stickyModifiers)
        case .autocorrect:
            autocorrectChoice = !prefersProse
            prefersProse.toggle()
        case .dismissKeyboard:
            dismissKeyboard()
        case .key(let name):
            guard let stroke = Keysyms.special[name] else { return }
            resetTyping()
            sendKey(stroke, modifiers: Array(stickyModifiers))
            releaseSticky()
        case .text(let text):
            if stickyModifiers == ["control"], text.lowercased() == "v" { paste(nil) }
            else { insertText(text) }
        }
    }

    /// Read the system clipboard only in response to the user's Paste action.
    open override func paste(_ sender: Any?) {
        releaseSticky()
        if let text = UIPasteboard.general.string { insertText(text) }
    }

    private func releaseSticky() {
        stickyModifiers.removeAll()
        keyBar.show(activeModifiers: stickyModifiers)
    }

    /// Delivers the keystrokes that make the remote text match the buffer.
    open func send(_ edits: [TypingBuffer.Edit]) {}

    /// Override to true when the remote side has a preedit (composition) of its own: marked
    /// text then arrives through `sendPreedit` instead of being typed, and is committed as a
    /// `.type` edit. Off: marked text is typed live and retyped as it changes.
    open var sendsMarkedTextAsPreedit: Bool { false }

    /// The composition in progress and its selection, in UTF-16 units of `text`; called after
    /// `send(_:)` whenever it changes, with "" once it is committed or cancelled.
    open func sendPreedit(_ text: String, selection: NSRange) {}

    /// When this view last sent edits or forgot its text; an app's report from before then
    /// may be stale.
    private var lastEdit: CFTimeInterval = 0

    /// The remote field reported the text before its caret. It becomes the buffer when it
    /// agrees with what was typed (the app has caught up) or nothing was typed for a moment
    /// (the app changed it, or its caret moved); a report racing fresh keystrokes waits.
    public func adoptRemoteText(beforeCaret text: String) {
        let caughtUp = !buffer.text.isEmpty && text.hasSuffix(buffer.text)
        guard caughtUp || CACurrentMediaTime() - lastEdit > 0.35 else { return }
        var next = buffer
        guard next.adopt(beforeCaret: text) else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        buffer = next
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    /// Forgets the typed text, e.g. when focus may have moved in the remote app.
    public func resetTyping() {
        lastEdit = CACurrentMediaTime()
        guard buffer != TypingBuffer() else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        buffer.reset()
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    private func perform(_ edit: (inout TypingBuffer) -> [TypingBuffer.Edit]) {
        buffer.marksAsPreedit = sendsMarkedTextAsPreedit
        let preedit = buffer.preedit
        let edits = edit(&buffer)
        if !edits.isEmpty { lastEdit = CACurrentMediaTime(); send(edits) }
        if sendsMarkedTextAsPreedit, buffer.preedit != preedit {
            let marked = buffer.marked ?? NSRange(location: 0, length: 0)
            let caret = NSRange(location: max(0, buffer.selection.location - marked.location), length: buffer.selection.length)
            sendPreedit(buffer.preedit ?? "", selection: buffer.preedit == nil ? NSRange(location: 0, length: 0) : caret)
        }
    }

    // MARK: UIKeyInput

    /// Always true: the remote field has text from before the buffer, and delete must reach it.
    public var hasText: Bool { true }
    open func insertText(_ text: String) {
        if !stickyModifiers.isEmpty {
            resetTyping()
            for character in text {
                guard let stroke = Keysyms.stroke(for: Character(character.lowercased())) else { continue }
                sendKey(stroke, modifiers: Array(stickyModifiers))
            }
            releaseSticky()
            return
        }
        if text == "\n" || text == "\r" || text == "\r\n" { unmarkText() }
        perform { $0.insert(text) }
    }
    open func deleteBackward() {
        guard !stickyModifiers.isEmpty else { perform { $0.deleteBackward() }; return }
        resetTyping()
        if let stroke = Keysyms.special["BackSpace"] { sendKey(stroke, modifiers: Array(stickyModifiers)) }
        releaseSticky()
    }

    // MARK: UITextInputTraits

    public var autocorrectionType: UITextAutocorrectionType {
        get { prefersProse ? .default : .no } set {}
    }
    public var autocapitalizationType: UITextAutocapitalizationType {
        get { prefersProse ? .sentences : .none } set {}
    }
    public var spellCheckingType: UITextSpellCheckingType {
        get { prefersProse ? .default : .no } set {}
    }
    public var inlinePredictionType: UITextInlinePredictionType {
        get { prefersProse ? .default : .no } set {}
    }
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .default
    public var keyboardAppearance: UIKeyboardAppearance = .dark
    public var returnKeyType: UIReturnKeyType = .default

    // MARK: UITextInput — text and ranges

    public func text(in range: UITextRange) -> String? {
        guard let range = range as? BufferRange else { return nil }
        let clamped = NSIntersectionRange(range.nsRange, NSRange(location: 0, length: buffer.length))
        return (buffer.text as NSString).substring(with: clamped)
    }

    public func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? BufferRange else { return }
        perform { $0.replace(range.nsRange, with: text) }
    }

    public var selectedTextRange: UITextRange? {
        get { BufferRange(buffer.selection) }
        set {
            guard let range = newValue as? BufferRange else { return }
            buffer.select(range.nsRange)
        }
    }

    public var markedTextRange: UITextRange? { buffer.marked.map(BufferRange.init) }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        perform { $0.setMarked(markedText ?? "", selectedRange: selectedRange) }
    }

    public func unmarkText() { perform { $0.unmark() } }

    public var beginningOfDocument: UITextPosition { BufferPosition(0) }
    public var endOfDocument: UITextPosition { BufferPosition(buffer.length) }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? BufferPosition, let to = toPosition as? BufferPosition else { return nil }
        return BufferRange(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset)))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? BufferPosition else { return nil }
        let target = position.offset + offset
        return (0 ... buffer.length).contains(target) ? BufferPosition(target) : nil
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? BufferPosition)?.offset ?? 0, b = (other as? BufferPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? BufferPosition)?.offset ?? 0) - ((from as? BufferPosition)?.offset ?? 0)
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        switch direction {
        case .left, .up: textRange(from: beginningOfDocument, to: position)
        default: textRange(from: position, to: endOfDocument)
        }
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: UITextInput — geometry. The remote text is not laid out here, so everything
    // collapses onto the caret anchor.

    private var caretRect: CGRect { CGRect(x: caretAnchor.x, y: caretAnchor.y - 10, width: 2, height: 20) }
    public func firstRect(for range: UITextRange) -> CGRect { caretRect }
    public func caretRect(for position: UITextPosition) -> CGRect { caretRect }
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    public func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    public func characterRange(at point: CGPoint) -> UITextRange? { nil }
}

final class BufferPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class BufferRange: UITextRange {
    let nsRange: NSRange
    init(_ range: NSRange) { nsRange = range }
    override var start: UITextPosition { BufferPosition(nsRange.location) }
    override var end: UITextPosition { BufferPosition(NSMaxRange(nsRange)) }
    override var isEmpty: Bool { nsRange.length == 0 }
}
#endif
