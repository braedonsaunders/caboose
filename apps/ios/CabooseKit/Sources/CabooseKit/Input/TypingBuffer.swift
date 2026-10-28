import Foundation

/// What the iOS text system believes is in a remote text field, so autocorrect, swipe
/// typing, dictation and marked-text input (Chinese, Japanese, Korean) can edit it.
///
/// The remote app's real text is unknown, so the buffer only holds what was typed since
/// the last reset, and the remote caret is assumed to sit at the end of it. Every edit
/// iOS makes — inserting, replacing a misspelt word, recomposing marked text — becomes
/// the backspaces and keystrokes that turn the old buffer into the new one. Moving the
/// local caret sends nothing; the next edit retypes from where the texts diverge.
///
/// Ranges are UTF-16, like `NSRange` and `UITextInput`. Backspaces count characters
/// (grapheme clusters), which is what a Linux text field deletes per BackSpace.
public struct TypingBuffer: Equatable, Sendable {
    public enum Edit: Equatable, Sendable {
        case backspace(Int)
        case type(String)
    }

    /// Longest buffer kept; older text is forgotten (it stays in the remote app).
    public static let limit = 400

    public private(set) var text = ""
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var marked: NSRange?
    /// Off: marked text is typed live and retyped as it changes (an app without text input).
    /// On (an app with Caboose Display's text input, which has a preedit): marked text stays
    /// local, edits leave it out, and it reaches the remote app as one `.type` when committed.
    public var marksAsPreedit = false

    public init(marksAsPreedit: Bool = false) {
        self.marksAsPreedit = marksAsPreedit
    }

    var length: Int { (text as NSString).length }

    /// The composition in progress, when marked text is a preedit.
    public var preedit: String? {
        guard marksAsPreedit, let marked else { return nil }
        return (text as NSString).substring(with: marked)
    }

    /// What the remote app has: everything, or everything but a preedit.
    private var remote: String {
        guard marksAsPreedit, let marked else { return text }
        return (text as NSString).replacingCharacters(in: marked, with: "")
    }

    /// Forgets everything, e.g. after Return, a tap elsewhere or a non-text key.
    public mutating func reset() {
        text = ""
        selection = NSRange(location: 0, length: 0)
        marked = nil
    }

    public mutating func select(_ range: NSRange) {
        selection = clamp(range)
    }

    /// Replaces a range with text and leaves the caret after it.
    public mutating func replace(_ range: NSRange, with string: String) -> [Edit] {
        let range = clamp(range)
        let before = remote
        marked = nil
        let edits = apply(range, string, before)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
        return finish(edits, committing: string)
    }

    /// Typing: replaces marked text if there is any, otherwise the selection.
    public mutating func insert(_ string: String) -> [Edit] {
        replace(marked ?? selection, with: string)
    }

    /// The delete key. With nothing to delete locally it still deletes remotely, since
    /// the remote field has text from before the buffer began.
    public mutating func deleteBackward() -> [Edit] {
        if selection.length > 0 || marked != nil { return replace(marked ?? selection, with: "") }
        guard selection.location > 0 else {
            // The character before the buffer: delete back past it and retype the buffer.
            return text.isEmpty ? [.backspace(1)] : [.backspace(text.count + 1), .type(text)]
        }
        let previous = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
        return replace(previous, with: "")
    }

    /// Marked text is composition in progress. Typed live (unless it is a preedit), so the
    /// remote app shows it, and recomposing it retypes only what changed.
    public mutating func setMarked(_ string: String, selectedRange: NSRange) -> [Edit] {
        let range = clamp(marked ?? selection)
        let before = remote
        text = (text as NSString).replacingCharacters(in: range, with: string)
        let count = (string as NSString).length
        marked = count > 0 ? NSRange(location: range.location, length: count) : nil
        let caret = min(max(0, selectedRange.location), count)
        selection = NSRange(location: range.location + caret, length: min(max(0, selectedRange.length), count - caret))
        return Self.diff(from: before, to: remote)
    }

    /// Commits marked text as it stands: nothing to send when it was typed live, the
    /// composed text when it was a preedit.
    @discardableResult
    public mutating func unmark() -> [Edit] {
        guard let marked else { return [] }
        let before = remote
        selection = NSRange(location: NSMaxRange(marked), length: 0)
        self.marked = nil
        return Self.diff(from: before, to: remote)
    }

    // MARK: Internals

    private mutating func apply(_ range: NSRange, _ string: String, _ before: String) -> [Edit] {
        text = (text as NSString).replacingCharacters(in: range, with: string)
        return Self.diff(from: before, to: remote)
    }

    /// Return ends the line in the remote app, so nothing before it may be edited again;
    /// a long buffer forgets its oldest text.
    private mutating func finish(_ edits: [Edit], committing string: String) -> [Edit] {
        if string.contains(where: \.isNewline) { reset() }
        trim()
        return edits
    }

    private mutating func trim() {
        guard length > Self.limit, marked == nil else { return }
        var drop = length - Self.limit
        drop = NSMaxRange((text as NSString).rangeOfComposedCharacterSequence(at: drop - 1))
        text = (text as NSString).substring(from: drop)
        selection = NSRange(location: max(0, selection.location - drop), length: selection.length)
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    /// Backspaces to where the texts diverge, then the new text from there.
    public static func diff(from old: String, to new: String) -> [Edit] {
        var oldIndex = old.startIndex, newIndex = new.startIndex
        while oldIndex < old.endIndex, newIndex < new.endIndex, old[oldIndex] == new[newIndex] {
            oldIndex = old.index(after: oldIndex)
            newIndex = new.index(after: newIndex)
        }
        var edits: [Edit] = []
        let deletions = old[oldIndex...].count
        if deletions > 0 { edits.append(.backspace(deletions)) }
        if newIndex < new.endIndex { edits.append(.type(String(new[newIndex...]))) }
        return edits
    }
}
