import Foundation

/// One X key press: the keysym name the server resolves, its value, and the modifiers
/// a US layout needs to produce it.
public struct KeyStroke: Equatable, Sendable {
    public var name: String
    public var keyval: Int
    public var string: String
    public var modifiers: [String]

    public init(name: String, keyval: Int, string: String = "", modifiers: [String] = []) {
        self.name = name
        self.keyval = keyval
        self.string = string
        self.modifiers = modifiers
    }
}

public enum Keysyms {
    /// Special keys by the name iOS and hardware keyboards give them.
    public static let special: [String: KeyStroke] = [
        "Return": KeyStroke(name: "Return", keyval: 0xFF0D, string: "\r"),
        "BackSpace": KeyStroke(name: "BackSpace", keyval: 0xFF08),
        "Tab": KeyStroke(name: "Tab", keyval: 0xFF09, string: "\t"),
        "Escape": KeyStroke(name: "Escape", keyval: 0xFF1B),
        "Delete": KeyStroke(name: "Delete", keyval: 0xFFFF),
        "Left": KeyStroke(name: "Left", keyval: 0xFF51),
        "Up": KeyStroke(name: "Up", keyval: 0xFF52),
        "Right": KeyStroke(name: "Right", keyval: 0xFF53),
        "Down": KeyStroke(name: "Down", keyval: 0xFF54),
        "Home": KeyStroke(name: "Home", keyval: 0xFF50),
        "End": KeyStroke(name: "End", keyval: 0xFF57),
        "Page_Up": KeyStroke(name: "Page_Up", keyval: 0xFF55),
        "Page_Down": KeyStroke(name: "Page_Down", keyval: 0xFF56),
        "Shift_L": KeyStroke(name: "Shift_L", keyval: 0xFFE1),
        "Control_L": KeyStroke(name: "Control_L", keyval: 0xFFE3),
        "Alt_L": KeyStroke(name: "Alt_L", keyval: 0xFFE9),
        "Super_L": KeyStroke(name: "Super_L", keyval: 0xFFEB),
    ] .merging((1 ... 12).map { ("F\($0)", KeyStroke(name: "F\($0)", keyval: 0xFFBD + $0)) }) { a, _ in a }

    private static let punctuation: [Character: (String, Bool)] = [
        " ": ("space", false), "!": ("exclam", true), "\"": ("quotedbl", true), "#": ("numbersign", true),
        "$": ("dollar", true), "%": ("percent", true), "&": ("ampersand", true), "'": ("apostrophe", false),
        "(": ("parenleft", true), ")": ("parenright", true), "*": ("asterisk", true), "+": ("plus", true),
        ",": ("comma", false), "-": ("minus", false), ".": ("period", false), "/": ("slash", false),
        ":": ("colon", true), ";": ("semicolon", false), "<": ("less", true), "=": ("equal", false),
        ">": ("greater", true), "?": ("question", true), "@": ("at", true), "[": ("bracketleft", false),
        "\\": ("backslash", false), "]": ("bracketright", false), "^": ("asciicircum", true),
        "_": ("underscore", true), "`": ("grave", false), "{": ("braceleft", true), "|": ("bar", true),
        "}": ("braceright", true), "~": ("asciitilde", true),
    ]

    /// The keystrokes that type one character. A character of several scalars (a ZWJ emoji,
    /// a flag, a skin tone, a decomposed accent) is typed scalar by scalar; the app composes it.
    public static func strokes(for character: Character) -> [KeyStroke] {
        if let stroke = stroke(for: character) { return [stroke] }
        guard character.unicodeScalars.count > 1 else { return [] }
        return character.unicodeScalars.compactMap { stroke(for: Character($0)) }
    }

    /// The keystroke for one typed character, or nil for one with no keysym.
    public static func stroke(for character: Character) -> KeyStroke? {
        if character == "\n" || character == "\r" { return special["Return"] }
        if character == "\t" { return special["Tab"] }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let value = Int(scalar.value)
        let text = String(character)
        if let (name, shifted) = punctuation[character] {
            return KeyStroke(name: name, keyval: value, string: text, modifiers: shifted ? ["shift"] : [])
        }
        switch scalar.value {
        case 0x61 ... 0x7A, 0x30 ... 0x39:
            return KeyStroke(name: text, keyval: value, string: text)
        case 0x41 ... 0x5A:
            return KeyStroke(name: text, keyval: value, string: text, modifiers: ["shift"])
        case 0xA0 ... 0xFF:
            return KeyStroke(name: String(format: "U%04X", value), keyval: value, string: text)
        case 0x100 ... 0x10FFFF:
            // X maps any Unicode code point to keysym 0x01000000 + code point.
            return KeyStroke(name: String(format: "U%04X", value), keyval: 0x0100_0000 + value, string: text)
        default:
            return nil
        }
    }
}
