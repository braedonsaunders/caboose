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
    static let backgroundOpacity: CGFloat = 0.5
    static let selection = amber.withAlphaComponent(0.34)

    /// Black, red, green, yellow, blue, magenta, cyan, white; then the bright eight.
    static let palette: [UInt32] = [
        0x1B2438, 0xFF6B6B, 0x7FD18B, 0xF5A623, 0x5B9DFF, 0xC792EA, 0x5ED3D1, 0xC8D1DE,
        0x5D6B89, 0xFF8A80, 0xA5E3A0, 0xFFC861, 0x82B6FF, 0xDDB3FF, 0x8BE9E6, 0xF5F7FA,
    ]

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

    /// Renders the Ghostty configuration file for Caboose Night at `fontSize`.
    static func ghosttyConfig(fontSize: CGFloat) -> String {
        let sizeString = Double(fontSize).formatted(
            FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0 ... 2))
                .grouping(.never)
        )
        var lines: [String] = [
            "font-family = SF Mono",
            "font-size = \(sizeString)",
            "window-padding-x = 0",
            "window-padding-y = 0",
            "background = #0E1626",
            "background-opacity = 0",
            "foreground = #E6EBF2",
            "cursor-style = block",
            "cursor-style-blink = true",
            "cursor-color = #F5A623",
            "cursor-text = #0E1626",
            "selection-background = #F5A623",
            "selection-foreground = #0E1626",
            "scrollback-limit = 10000000",
            "macos-option-as-alt = true",
            "clipboard-read = deny",
            "clipboard-write = allow",
            "copy-on-select = false",
        ]
        for (index, rgb) in palette.enumerated() {
            lines.append(String(format: "palette = %d=#%06X", index, rgb & 0xFFFFFF))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
