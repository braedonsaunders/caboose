#if canImport(UIKit)
import UIKit

/// Shared tactile feedback for every trackpad: Laptop's trackpad, the desktop driven by
/// touch, and a window's held pointer. A click is the keyboard's light press
/// (`KeyboardFeedback`), a right-click is firmer, and a drag is felt as it starts and ends.
/// UIKit plays nothing while System Haptics is off in Settings.
@MainActor public enum TrackpadFeedback {
    private static let click = UIImpactFeedbackGenerator(style: .light)
    private static let secondary = UIImpactFeedbackGenerator(style: .rigid)
    private static let dragBegan = UIImpactFeedbackGenerator(style: .medium)
    private static let dragEnded = UIImpactFeedbackGenerator(style: .soft)

    public static func prepare() {
        click.prepare()
        secondary.prepare()
    }

    public static func play(_ feedback: TrackpadGestures.Feedback) {
        switch feedback {
        case .click: click.impactOccurred(intensity: 0.6); click.prepare()
        case .secondaryClick: secondary.impactOccurred(intensity: 0.8); secondary.prepare()
        case .dragBegan: dragBegan.impactOccurred(intensity: 0.7); dragEnded.prepare()
        case .dragEnded: dragEnded.impactOccurred(intensity: 0.5)
        }
    }

    /// Plays the feedback of a trackpad gesture's action, if it has one.
    public static func play(for action: TrackpadGestures.Action) {
        TrackpadGestures.feedback(for: action).map(play)
    }
}
#endif
