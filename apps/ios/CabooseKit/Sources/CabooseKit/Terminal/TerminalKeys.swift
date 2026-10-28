import Foundation

/// The bytes an xterm-compatible terminal sends for the keys the phone keyboard lacks, with
/// the sticky Ctrl and Alt of the key row applied.
public enum TerminalKeys {
    public enum Key: Equatable, Sendable {
        case escape, tab, up, down, left, right, home, end, pageUp, pageDown
        /// Text typed with a modifier held: `c` with Ctrl is ETX.
        case text(String)
    }

    /// Bytes for `key`, or nil when an unmodified cursor key should be left to the terminal,
    /// which knows whether the application asked for application cursor keys.
    public static func bytes(for key: Key, control: Bool, alt: Bool) -> [UInt8]? {
        let escape: [UInt8] = [0x1b]
        // xterm's modifier parameter: 1 + Shift (1) + Alt (2) + Ctrl (4).
        let modifier = 1 + (alt ? 2 : 0) + (control ? 4 : 0)
        func cursor(_ final: Character) -> [UInt8]? {
            modifier == 1 ? nil : Array("\u{1b}[1;\(modifier)\(final)".utf8)
        }
        func tilde(_ number: Int) -> [UInt8] {
            modifier == 1 ? Array("\u{1b}[\(number)~".utf8) : Array("\u{1b}[\(number);\(modifier)~".utf8)
        }
        switch key {
        case .escape: return alt ? escape + escape : escape
        case .tab: return alt ? escape + [0x09] : [0x09]
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .text(let text):
            var bytes: [UInt8] = []
            for scalar in text.unicodeScalars {
                let encoded = Array(String(scalar).utf8)
                let controlled = control ? controlByte(scalar).map { [$0] } ?? encoded : encoded
                bytes += alt ? escape + controlled : controlled
            }
            return bytes
        }
    }

    /// The C0 control a character makes with Ctrl: letters and `@[\]^_` map to 0–31,
    /// space to NUL and `?` to DEL, as on a VT100.
    public static func controlByte(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x61...0x7a: return UInt8(scalar.value - 0x60)
        case 0x40...0x5f: return UInt8(scalar.value - 0x40)
        case 0x20: return 0
        case 0x3f: return 0x7f
        case 0x32: return 0          // Ctrl-2 is NUL
        case 0x33...0x37: return UInt8(scalar.value - 0x33 + 0x1b)   // Ctrl-3…7 are ESC…US
        case 0x38: return 0x7f       // Ctrl-8 is DEL
        default: return nil
        }
    }
}
