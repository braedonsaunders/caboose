import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The refresh rates a window is shown at, from what its application says it shows
/// (`wp_content_type_v1`, docs/display.md "Window hints"). The window's display link asks for
/// this range; the application is paced by the ticks it gets, so a video does not hold the
/// screen at 120 Hz and a game is not held below 60.
public enum FrameRatePolicy {
    public struct Range: Equatable, Sendable {
        public var minimum: Float
        public var maximum: Float
        public var preferred: Float
    }

    /// A window that says nothing about itself keeps the full range.
    public static func range(for content: WindowContentType) -> Range {
        switch content {
        case .none: Range(minimum: 30, maximum: 120, preferred: 120)
        case .game: Range(minimum: 60, maximum: 120, preferred: 120)
        // 24, 25, 30 and 60 fps sources all divide into 24...60.
        case .video: Range(minimum: 24, maximum: 60, preferred: 60)
        case .photo: Range(minimum: 10, maximum: 30, preferred: 30)
        }
    }
}

/// Keeps the screen awake while any window that inhibits idling is shown. A window reports
/// itself whenever its state may have changed; the screen sleeps again when the last one stops.
@MainActor
public final class IdleInhibition {
    public static let shared = IdleInhibition { active in
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = active
        #endif
    }

    private var holders = Set<ObjectIdentifier>()
    private let apply: (Bool) -> Void
    private(set) var active = false

    public init(apply: @escaping (Bool) -> Void) {
        self.apply = apply
    }

    /// `holder` inhibits idling (it shows a window that asks for it) or no longer does.
    public func set(_ holder: AnyObject, inhibiting: Bool) {
        let id = ObjectIdentifier(holder)
        if inhibiting { holders.insert(id) } else { holders.remove(id) }
        let now = !holders.isEmpty
        guard now != active else { return }
        active = now
        apply(now)
    }
}
