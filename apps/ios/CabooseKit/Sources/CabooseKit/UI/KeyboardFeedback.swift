#if canImport(UIKit)
import UIKit

/// Shared tactile feedback for app-owned keyboard keys and accessory actions.
/// Call at activation, including a held key's repeats, rather than from text delivery.
@MainActor public enum KeyboardFeedback {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    public static func prepare() { generator.prepare() }

    public static func press() {
        generator.impactOccurred(intensity: 0.6)
        generator.prepare()
    }
}
#endif
