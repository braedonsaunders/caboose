import SwiftUI

/// The shared launch state survives dock re-layout and is cleared by real window matching.
struct DockLaunchFeedback: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let maximumLift: CGFloat = 6
    let appID: String

    func body(content: Content) -> some View {
        let pending = model.dockLaunches.pending[appID]
        TimelineView(.animation(minimumInterval: 1 / 30, paused: pending == nil || reduceMotion)) { tick in
            let elapsed = pending.map { max(0, tick.date.timeIntervalSince($0.started)) } ?? 0
            let lift = pending == nil || reduceMotion ? 0 : CGFloat(abs(sin(elapsed * .pi / 0.65))) * Self.maximumLift
            content.offset(y: -lift)
                .overlay {
                    if pending != nil { LaunchWheel() }
                }
        }
        .accessibilityValue(pending == nil ? "" : "Opening")
    }
}

/// An app opening, on its icon wherever it was opened from: the Caboose wheel turning over
/// the dimmed icon, as on the Apps page, sized to the icon it covers.
struct LaunchWheel: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            CabooseWheel(motion: .rolling)
                .frame(width: side * 0.4, height: side * 0.4)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(.black.opacity(0.45), in: ConcentricRectangle(cornerRadius: side * 0.26))
        }
        .allowsHitTesting(false)
    }
}
