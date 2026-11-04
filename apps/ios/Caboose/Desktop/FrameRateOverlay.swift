import CabooseKit
import SwiftUI

/// The frame-rate overlay: shown, when turned on, in the corner of the screen with the rate the
/// topmost computer window that draws on this device's GPU presents at (any app).
enum FrameRateOverlaySetting {
    static let key = "display.showsFrameRate"
}

struct FrameRateOverlay: View {
    @Environment(AppModel.self) private var model
    @AppStorage(FrameRateOverlaySetting.key) private var shows = false

    var body: some View {
        if shows {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if let front = PresentedFrameRate.shared.frontmost(model.desktop.stacking.reversed()) {
                    Text("\(Int(front.rate.rounded())) fps")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(6)
                        .accessibilityLabel("\(Int(front.rate.rounded())) frames per second")
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The overlay's switch, for the display settings.
struct FrameRateOverlayToggle: View {
    @AppStorage(FrameRateOverlaySetting.key) private var shows = false
    var body: some View {
        Toggle(isOn: $shows) {
            Label("Show Frame Rate", systemImage: "speedometer")
        }
    }
}
