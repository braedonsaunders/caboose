import SwiftTerm
import UIKit

/// Caboose Night: the brand's navy field with amber for the cursor and selection, and a
/// sixteen-colour palette tuned to read on it. 256-colour and truecolor output is drawn as
/// sent; the palette's cube and greys derive from these sixteen.
enum TerminalTheme {
    /// The navy of the app icon's field (`apps/web/src/brand/brand.ts`, ICON_NAVY_BOTTOM).
    static let background = UIColor(hex: 0x0E1626)
    /// Cream steel, a touch cooler than the icon's for long reading.
    static let foreground = UIColor(hex: 0xE6EBF2)
    static let amber = UIColor(hex: 0xF5A623)
    /// How much of the wallpaper behind the tab shows through the terminal's own background.
    static let backgroundOpacity: CGFloat = 0.82
    static let selection = amber.withAlphaComponent(0.34)

    /// Black, red, green, yellow, blue, magenta, cyan, white; then the bright eight.
    static let palette: [UInt32] = [
        0x1B2438, 0xFF6B6B, 0x7FD18B, 0xF5A623, 0x5B9DFF, 0xC792EA, 0x5ED3D1, 0xC8D1DE,
        0x5D6B89, 0xFF8A80, 0xA5E3A0, 0xFFC861, 0x82B6FF, 0xDDB3FF, 0x8BE9E6, 0xF5F7FA,
    ]

    static var ansi: [SwiftTerm.Color] {
        palette.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
    }

    /// Text sizes, in points, that pinch to zoom moves between.
    static let fontSizes: ClosedRange<CGFloat> = 8 ... 28
    static var defaultFontSize: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12 }

    /// SF Mono, the system's monospaced face, with its bold, italic and bold italic.
    static func fonts(size: CGFloat) -> (normal: UIFont, bold: UIFont, italic: UIFont, boldItalic: UIFont) {
        let normal = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        func italic(_ font: UIFont) -> UIFont {
            font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic))
                .map { UIFont(descriptor: $0, size: size) } ?? font
        }
        return (normal, bold, italic(normal), italic(bold))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
