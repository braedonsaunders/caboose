/// One-shot accessory modifiers for native editors. Commands name native editing
/// operations, never terminal bytes. Unsupported chords are consumed without insertion.
public struct NativeKeyModifiers: Equatable {
    public enum TextAction: Equatable {
        case insert(String), selectAll, copy, cut, paste, undo, redo, unsupported
    }
    public private(set) var active: Set<String> = []
    public init() {}
    public mutating func toggle(_ modifier: String) {
        if !active.insert(modifier).inserted { active.remove(modifier) }
    }
    @discardableResult public mutating func consume() -> Set<String> {
        defer { active.removeAll() }
        return active
    }
    public mutating func text(_ text: String, composing: Bool, secure: Bool) -> TextAction {
        let modifiers = consume()
        // Marked text is always owned by the IME, even with an accessory modifier lit.
        guard !composing, !modifiers.isEmpty else { return .insert(text) }
        guard modifiers == ["control"] else { return .unsupported }
        switch text.lowercased() {
        case "a": return .selectAll
        case "c": return secure ? .unsupported : .copy
        case "x": return secure ? .unsupported : .cut
        case "v": return .paste
        case "z": return .undo
        case "y": return .redo
        default: return .unsupported
        }
    }
}
