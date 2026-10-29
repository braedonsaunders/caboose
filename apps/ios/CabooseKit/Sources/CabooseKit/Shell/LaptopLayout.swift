import CoreGraphics
import Foundation

/// Layout policy for a computer above a horizontal fold and controls below it.
/// A vertical book fold never activates Laptop automatically. Manual mode also works
/// on a flat display; measured keyboard overlap always takes precedence over the split.
public enum LaptopLayout {
    public enum Input: String, CaseIterable, Sendable {
        case keyboard, trackpad, combo
        public var title: String {
            switch self { case .keyboard: "Keyboard"; case .trackpad: "Trackpad"; case .combo: "Keyboard & Trackpad" }
        }
        public var symbol: String {
            switch self { case .keyboard: "keyboard"; case .trackpad: "hand.draw"; case .combo: "rectangle.split.2x1" }
        }
    }
    public enum Mode: String, CaseIterable, Sendable { case automatic, tablet, laptop }
    public struct Frames: Equatable, Sendable {
        public let screen: CGRect
        public let controls: CGRect
    }

    public static func isActive(mode: Mode, size: CGSize, division: CGRect?, partiallyOpen: Bool) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width >= 300, size.height >= 460 else { return false }
        switch mode {
        case .tablet: return false
        case .laptop: return true
        case .automatic:
            guard partiallyOpen, let division, division.width > division.height,
                  division.width >= size.width * 0.5 else { return false }
            return division.minY >= 140 && size.height - division.maxY >= 140
        }
    }

    /// Combo reserves the upper third for pointing and the lower two thirds for keys,
    /// including their shared shortcut header. Neither panel invokes the system keyboard.
    public static func comboTrackpadHeight(_ availableHeight: CGFloat) -> CGFloat {
        availableHeight.isFinite ? max(0, availableHeight) / 3 : 0
    }

    public static func frames(size: CGSize, division: CGRect?, keyboard: CGFloat) -> Frames {
        let width = max(0, size.width), height = max(0, size.height)
        let visible = max(0, height - max(0, keyboard))
        let fold = division.flatMap { $0.width > $0.height && $0.minY > 0 && $0.maxY < height ? $0 : nil }
        let boundary = fold?.minY ?? height * 0.5
        // Native keyboard + its shared accessory can be taller than the lower half.
        // Keep the upper app above it, rather than clipping rows behind the keyboard.
        let screenHeight = max(0, min(boundary, visible))
        let controlsY = fold?.maxY ?? (height * 0.5)
        return Frames(screen: CGRect(x: 0, y: 0, width: width, height: screenHeight),
                      controls: CGRect(x: 0, y: controlsY, width: width, height: max(0, visible - controlsY)))
    }
}
