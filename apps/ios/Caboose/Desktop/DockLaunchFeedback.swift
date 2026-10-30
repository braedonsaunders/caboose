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
                .overlay(alignment: .bottomTrailing) {
                    if pending != nil {
                        ProgressView().controlSize(.mini).tint(.white)
                            .padding(2).background(.black.opacity(0.6), in: Circle())
                    }
                }
        }
        .accessibilityValue(pending == nil ? "" : "Opening")
    }
}
