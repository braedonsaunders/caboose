import CabooseKit
import SwiftUI
import UIKit

/// Where the input controls are.
enum InputPlacement: Equatable {
    /// Below Laptop's hinge (or its manual split), across the full width of the lower panel.
    case laptop(compact: Bool)
    /// Across the phone while a display shows the desktop. Gamepad fills the whole screen.
    case display
}

/// The phone's input for the computer, the same wherever it is: Trackpad, Keyboard & Trackpad,
/// Keyboard or Gamepad. Laptop puts it below the hinge; a connected display puts it across the
/// phone.
struct InputControls: View {
    @Environment(AppModel.self) private var model
    @State private var surface = TrackpadSurface()
    /// The Trackpad page raised to Keyboard & Trackpad while a text field has focus.
    @State private var textFocus = TextFocusInput()
    /// The next change of page is the text focus's, not the owner's.
    @State private var focusMoved = false
    @State private var focusLeaving: Task<Void, Never>?
    @State private var bannerVisible = false
    @State private var bannerTask: Task<Void, Never>?
    /// Live horizontal 3/4-finger scrub offset in points while the user drags across input modes.
    @State private var swipeOffset: CGFloat = 0
    @State private var isScrubbing = false
    let placement: InputPlacement
    let isCard: Bool
    let enabled: Bool
    @Binding var input: LaptopLayout.Input
    @Binding var systemKeyboard: Bool

    private var laptop: Bool { placement != .display }
    private var compact: Bool { placement == .laptop(compact: true) }
    private var desktop: DesktopModel? { isCard ? nil : model.desktop }
    private var target: RemoteWindow? {
        guard isCard, let parent = model.window(model.presentedWindowID) else { return nil }
        return model.auxiliaryWindows(for: parent).last { !$0.isOverrideRedirect } ?? parent
    }
    /// What the panel shows. On a display, the gamepad fills the screen above the trackpad and
    /// the system keyboard types beside the trackpad alone.
    private var shown: LaptopLayout.Input {
        !laptop && (input == .gamepad || systemKeyboard) ? .trackpad : input
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let neighbor: LaptopLayout.Input? = isScrubbing && abs(swipeOffset) > 1
                ? shown.stepped(by: swipeOffset < 0 ? 1 : -1)
                : nil
            ZStack(alignment: .top) {
                ZStack {
                    if let neighbor {
                        inputPreview(for: neighbor, size: proxy.size)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: swipeOffset + (swipeOffset < 0 ? width : -width))
                            .allowsHitTesting(false)
                    }
                    VStack(spacing: 0) {
                        // Keyboard mode keeps the trackpad mounted at no height: it is the
                        // responder the keyboard types through.
                        trackpad
                            .frame(height: LaptopLayout.trackpadHeight(shown, available: proxy.size.height))
                            .clipped()
                        if shown.showsKeyboard {
                            VStack(spacing: 0) {
                                LaptopKeyHeader(surface: surface).frame(maxWidth: .infinity).frame(height: 48)
                                LaptopComboKeyboard(onText: { surface.insertText($0) },
                                                    onKey: { surface.performKeyboardAction(.key($0)) },
                                                    onNativeKeyboard: openSystemKeyboard)
                            }
                            .background(Color(uiColor: .systemGray5))
                        }
                        if shown == .gamepad {
                            // A card's target comes from the model, the desktop's front window from the
                            // desktop, so the panel sees either change as it happens.
                            GamepadPanel(target: { isCard ? target : surface.focusedWindow },
                                         enabled: enabled && !isScrubbing,
                                         switchInput: laptop ? { selectInput($0) } : nil)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: swipeOffset)
                }
                .clipped()
                if laptop && (bannerVisible || isScrubbing) {
                    inputBanner(previewing: neighbor)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background {
                if laptop {
                    LaptopInputSwipeProbe(
                        enabled: enabled,
                        onBegan: {
                            beginInteractiveSwipe()
                        },
                        onChanged: { dx in
                            updateInteractiveSwipe(dx: dx, width: width)
                        },
                        onEnded: { dx, velocityX in
                            endInteractiveSwipe(dx: dx, velocityX: velocityX, width: width)
                        }
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .background(shown.showsKeyboard ? Color(uiColor: .systemGray5) : Color(white: 0.14))
        .allowsHitTesting(enabled)
        .sheet(isPresented: $model.laptopGestureHelp) { TrackpadGestureGuide() }
        .fullScreenCover(isPresented: Binding(get: { !laptop && input == .gamepad },
                                              set: { if !$0 && input == .gamepad { input = .trackpad } })) {
            GamepadPanel(target: { surface.focusedWindow }, enabled: enabled, close: { input = .trackpad })
                .environment(model)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: input) { _, value in
            settle(value)
            if focusMoved { focusMoved = false } else { textFocus.chose(value) }
        }
        // A text field taking focus on the computer (text-input-v3, IBus) raises the keyboard
        // beside the trackpad; focus leaving it, for longer than moving to the next field
        // takes, returns to the trackpad.
        .onChange(of: model.session?.textFieldFocused ?? false) { _, focused in
            focusLeaving?.cancel()
            if focused { return followTextFocus(true) }
            focusLeaving = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, model.session?.textFieldFocused != true else { return }
                followTextFocus(false)
            }
        }
        .onAppear {
            // A click's own check covers apps that report no text input, by their cursor.
            surface.textFocusAnswered = { wanted in if !wanted, model.session?.textFieldFocused != true { followTextFocus(false) } }
        }
        .onChange(of: model.keyboardVisible) { _, visible in
            if systemKeyboard {
                if !visible { closeSystemKeyboard() }
                return
            }
            guard visible else { return }
            if laptop {
                // A text field wants the keyboard: Laptop's own answers, beside the trackpad
                // that focused the field. The system keyboard never opens by itself here.
                model.keyboardVisible = false
                followTextFocus(true)
            } else if input != .trackpad {
                // On a display the system keyboard opens over the trackpad alone; the
                // keyboards already type, and the gamepad has the screen.
                model.keyboardVisible = false
            }
        }
        .onChange(of: systemKeyboard) { _, open in
            if !open { closeSystemKeyboard() }
        }
    }

    private var trackpad: some View {
        Trackpad(desktop: desktop, target: target,
                 keyboardVisible: model.keyboardVisible && (laptop ? systemKeyboard : input == .trackpad || systemKeyboard),
                 enabled: enabled && !isScrubbing, pointerEnabled: (shown == .trackpad || shown == .combo) && !isScrubbing,
                 sharedSurface: surface, inlineControls: input.showsKeyboard && !systemKeyboard,
                 bareSystemKeyboard: laptop && systemKeyboard,
                 laptopMode: laptop,
                 onInputSwipe: nil,
                 dismissInline: { input = .trackpad })
            .background(Color(white: 0.12))
            .overlay {
                if shown == .trackpad || shown == .combo {
                    trackpadWatermark(for: shown)
                }
            }
    }

    private func trackpadWatermark(for mode: LaptopLayout.Input) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.draw").font(mode == .combo ? .body : .title2)
            Text("Trackpad").font(.subheadline.weight(.medium))
            if mode != .combo && !compact {
                Text(laptop
                     ? "Tap to click · 2 fingers to scroll · 3–4 fingers to scrub inputs"
                     : "Tap to click · two fingers to scroll or right-click")
                    .font(.caption)
            }
        }
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
        .padding(8).allowsHitTesting(false)
    }

    /// Lightweight interactive preview of the neighboring input page while scrubbing with 3 or 4 fingers.
    @ViewBuilder
    private func inputPreview(for mode: LaptopLayout.Input, size: CGSize) -> some View {
        VStack(spacing: 0) {
            let trackpadH = LaptopLayout.trackpadHeight(mode, available: size.height)
            if trackpadH > 0 {
                Color(white: 0.12)
                    .frame(height: trackpadH)
                    .overlay { trackpadWatermark(for: mode) }
            }
            if mode.showsKeyboard {
                VStack(spacing: 0) {
                    LaptopKeyHeader(surface: surface).frame(maxWidth: .infinity).frame(height: 48)
                    LaptopComboKeyboard(onText: { _ in }, onKey: { _ in }, onNativeKeyboard: {})
                }
                .background(Color(uiColor: .systemGray5))
            }
            if mode == .gamepad {
                GamepadPanel(target: { isCard ? target : surface.focusedWindow },
                             enabled: false,
                             switchInput: nil)
            }
        }
        .background(mode.showsKeyboard ? Color(uiColor: .systemGray5) : Color(white: 0.14))
    }

    private func inputBanner(previewing neighbor: LaptopLayout.Input?) -> some View {
        let progress = min(1, abs(swipeOffset) / 140)
        let highlighted = (neighbor != nil && progress >= 0.45) ? neighbor! : input
        return HStack(spacing: 6) {
            ForEach(LaptopLayout.Input.cycleOrder, id: \.self) { choice in
                let active = highlighted == choice
                Button {
                    selectInput(choice)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                        if active {
                            Text(choice.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(active ? .white : .white.opacity(0.65))
                    .padding(.horizontal, active ? 10 : 8)
                    .padding(.vertical, 6)
                    .background(active ? Color.accentColor : Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.18)) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.snappy(duration: 0.16), value: highlighted)
        .environment(\.colorScheme, .dark)
    }

    private func beginInteractiveSwipe() {
        surface.endInteraction()
        isScrubbing = true
        showBanner()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateInteractiveSwipe(dx: CGFloat, width: CGFloat) {
        if !isScrubbing { beginInteractiveSwipe() }
        // Let the user scrub smoothly back and forth ("DJ style"); if they drag a full page width,
        // advance the anchor page seamlessly so continuous scrubbing keeps working.
        var adjusted = dx * 1.35
        let stepThreshold = width * 0.82
        if adjusted <= -stepThreshold {
            input = input.stepped(by: 1)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            adjusted += stepThreshold
        } else if adjusted >= stepThreshold {
            input = input.stepped(by: -1)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            adjusted -= stepThreshold
        }
        swipeOffset = max(-width, min(width, adjusted))
    }

    private func endInteractiveSwipe(dx: CGFloat, velocityX: CGFloat, width: CGFloat) {
        let projected = swipeOffset + velocityX * 0.16
        let threshold = min(95, width * 0.22)
        if projected <= -threshold {
            let next = input.stepped(by: 1)
            // Start the new page from where its preview currently sits, then spring to 0.
            let remainder = swipeOffset + width
            input = next
            swipeOffset = remainder
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                swipeOffset = 0
                isScrubbing = false
            }
        } else if projected >= threshold {
            let next = input.stepped(by: -1)
            let remainder = swipeOffset - width
            input = next
            swipeOffset = remainder
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                swipeOffset = 0
                isScrubbing = false
            }
        } else {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                swipeOffset = 0
                isScrubbing = false
            }
        }
        showBanner()
    }

    private func selectInput(_ next: LaptopLayout.Input) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            swipeOffset = 0
            isScrubbing = false
            if input != next {
                input = next
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        showBanner()
    }

    private func showBanner() {
        bannerTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) { bannerVisible = true }
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { bannerVisible = false }
        }
    }

    private func followTextFocus(_ focused: Bool) {
        guard laptop, !systemKeyboard, let next = textFocus.focus(focused, current: input) else { return }
        focusMoved = true
        input = next
    }

    /// A new input: whatever the last one held ends, and the keyboards follow it.
    private func settle(_ value: LaptopLayout.Input) {
        surface.endInteraction()
        systemKeyboard = false
        surface.inlineKeyboardControls = value.showsKeyboard
        model.keyboardVisible = false
    }

    /// The globe key: the system keyboard, for what the phone's own keyboard does not type.
    private func openSystemKeyboard() {
        systemKeyboard = true
        surface.inlineKeyboardControls = false
        model.keyboardVisible = true
    }

    private func closeSystemKeyboard() {
        systemKeyboard = false
        surface.inlineKeyboardControls = input.showsKeyboard
        if model.keyboardVisible { model.keyboardVisible = false }
    }
}

/// Attaches a zero-delay 3- or 4-finger horizontal pan/scrub recognizer to the hosting window,
/// scoped to `InputControls`'s lower-panel bounds, so dragging 3 or 4 fingers left and right
/// interactively slides between input modes like native iOS paging ("DJ style").
private struct LaptopInputSwipeProbe: UIViewRepresentable {
    let enabled: Bool
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.enabled = enabled
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.enabled = enabled
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: UIView {
        var enabled = true { didSet { recognizer?.isEnabled = enabled } }
        var onBegan: (() -> Void)?
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?
        private var recognizer: MultiFingerInputSwipeRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let gesture = MultiFingerInputSwipeRecognizer(
                probe: self,
                onBegan: { [weak self] in self?.onBegan?() },
                onChanged: { [weak self] dx in self?.onChanged?(dx) },
                onEnded: { [weak self] dx, vx in self?.onEnded?(dx, vx) }
            )
            gesture.isEnabled = enabled
            window.addGestureRecognizer(gesture)
            recognizer = gesture
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { detach() }
            super.willMove(toWindow: newWindow)
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
        }
    }
}

/// Recognizes a compact 3- or 4-finger horizontal scrub inside `probe`'s bounds without
/// delaying 1- or 2-finger touches, and without mistaking two-handed claw-grip gameplay
/// (where left and right thumbs are on opposite halves of the screen) for a one-hand swipe.
/// Once locked in (`engaged`), it streams continuous horizontal displacement and release
/// velocity so the user can scrub back and forth before lifting.
private final class MultiFingerInputSwipeRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var probe: UIView?
    private let onBegan: () -> Void
    private let onChanged: (CGFloat) -> Void
    private let onEnded: (CGFloat, CGFloat) -> Void
    private var startPositions: [UITouch: CGPoint] = [:]
    private var activeTouches: Set<UITouch> = []
    private var maxTouches = 0
    private var engaged = false
    private var anchorX: CGFloat = 0
    private var lastX: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var velocityX: CGFloat = 0

    init(probe: UIView,
         onBegan: @escaping () -> Void,
         onChanged: @escaping (CGFloat) -> Void,
         onEnded: @escaping (CGFloat, CGFloat) -> Void) {
        self.probe = probe
        self.onBegan = onBegan
        self.onChanged = onChanged
        self.onEnded = onEnded
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let probe, probe.window != nil else { return false }
        let point = touch.location(in: probe)
        return probe.bounds.contains(point)
    }

    private func meanPoint(in probe: UIView) -> CGPoint? {
        guard !activeTouches.isEmpty else { return nil }
        let points = activeTouches.map { $0.location(in: probe) }
        let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let probe else { state = .failed; return }
        for touch in touches {
            let location = touch.location(in: probe)
            activeTouches.insert(touch)
            startPositions[touch] = location
        }
        maxTouches = max(maxTouches, activeTouches.count)
        if maxTouches > 4 {
            if engaged {
                finish(in: probe)
            } else {
                state = .failed
            }
            return
        }
        if !engaged, (activeTouches.count == 3 || activeTouches.count == 4) {
            // Rebase start positions when the 3rd/4th finger arrives so staggered touch-downs
            // measure displacement cleanly from when all fingers are on the glass.
            for touch in activeTouches {
                startPositions[touch] = touch.location(in: probe)
            }
        } else if engaged, let center = meanPoint(in: probe) {
            // Preserve current scrub delta if a 4th finger joins mid-scrub.
            let currentDX = lastX - anchorX
            anchorX = center.x - currentDX
            lastX = center.x
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let probe else { return }
        let nowTime = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        if engaged {
            guard let center = meanPoint(in: probe) else { return }
            let dt = nowTime - lastTime
            if dt > 0.001 {
                let instantVX = (center.x - lastX) / CGFloat(dt)
                velocityX = velocityX * 0.35 + instantVX * 0.65
            }
            lastX = center.x
            lastTime = nowTime
            state = .changed
            onChanged(center.x - anchorX)
            return
        }

        guard activeTouches.count == 3 || activeTouches.count == 4 else { return }
        let currentPoints = activeTouches.map { $0.location(in: probe) }
        let xs = currentPoints.map(\.x)
        guard let minX = xs.min(), let maxX = xs.max() else { return }
        // Fingers of one hand swiping together span at most ~240pt; two-handed gamepad thumbs
        // sit on opposite sides of the screen and are never a swipe.
        guard maxX - minX <= 240 else { return }

        var totalDX: CGFloat = 0
        var totalDY: CGFloat = 0
        var positiveCount = 0
        var negativeCount = 0
        for touch in activeTouches {
            guard let start = startPositions[touch] else { return }
            let now = touch.location(in: probe)
            let dx = now.x - start.x
            let dy = now.y - start.y
            totalDX += dx
            totalDY += dy
            if dx >= 10 { positiveCount += 1 }
            if dx <= -10 { negativeCount += 1 }
        }
        let count = CGFloat(activeTouches.count)
        let meanDX = totalDX / count
        let meanDY = totalDY / count
        let allMovedSameWay = positiveCount == activeTouches.count || negativeCount == activeTouches.count
        guard allMovedSameWay, abs(meanDX) >= 14, abs(meanDX) >= abs(meanDY) * 1.2 else { return }

        guard let center = meanPoint(in: probe) else { return }
        engaged = true
        anchorX = center.x
        lastX = center.x
        lastTime = nowTime
        velocityX = 0
        state = .began
        onBegan()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let probe else {
            state = .failed
            return
        }
        for touch in touches {
            activeTouches.remove(touch)
            startPositions.removeValue(forKey: touch)
        }
        if engaged {
            if activeTouches.isEmpty {
                finish(in: probe)
            } else if let center = meanPoint(in: probe) {
                // Keep tracking smoothly with remaining fingers until lift completes.
                let currentDX = lastX - anchorX
                anchorX = center.x - currentDX
                lastX = center.x
            }
        } else if activeTouches.isEmpty {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if engaged, let probe {
            finish(in: probe, cancelled: true)
        } else {
            state = .cancelled
        }
    }

    private func finish(in probe: UIView, cancelled: Bool = false) {
        let finalDX = lastX - anchorX
        let finalVX = cancelled ? 0 : velocityX
        engaged = false
        state = cancelled ? .cancelled : .ended
        onEnded(finalDX, finalVX)
    }

    override func reset() {
        super.reset()
        startPositions.removeAll()
        activeTouches.removeAll()
        maxTouches = 0
        engaged = false
        anchorX = 0
        lastX = 0
        lastTime = 0
        velocityX = 0
    }
}

/// The input choices, the same in the dock's controls panel and on a display's trackpad screen.
struct InputChoices: View {
    @Binding var input: LaptopLayout.Input
    @Binding var gestureHelp: Bool

    var body: some View {
        Picker("Input", selection: $input) {
            ForEach(LaptopLayout.Input.allCases, id: \.self) { choice in
                Label(choice.title, systemImage: choice.symbol).tag(choice)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Trackpad Gestures", systemImage: "hand.draw") { gestureHelp = true }
    }
}
