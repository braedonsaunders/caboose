import CabooseKit
import SwiftUI

/// Switchyard: the Desktop tab on the device's own screen, with the computer's windows tiled
/// in columns along a track.
///
/// The windows keep every touch on them. The yard's own gestures live where the apps have
/// nothing: the gaps between tiles resize them, the grabber at the top of a tile carries it,
/// the screen's side edges and the dock's column cars move along the track, and ⌘⌥ with the
/// arrows, R, F, W, O, A and Return does all of it from a keyboard. The dock is always there.
struct SwitchyardView: View {
    static let space = "switchyard"

    @Environment(AppModel.self) private var model
    let yard: YardModel
    @State private var askingAbout: RemoteWindow?

    var body: some View {
        GeometryReader { proxy in
            // The dock keeps the bottom, just clear of the home indicator; tiles have the rest.
            let bottom = max(6, proxy.safeAreaInsets.bottom - 10)
            let area = CGSize(width: proxy.size.width, height: max(0, proxy.size.height - YardDock.height - 6 - bottom))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    tracks(size: area)
                    YardDock(yard: yard, width: proxy.size.width - 16)
                        .padding(.top, 6)
                        .padding(.bottom, bottom)
                        .frame(maxWidth: .infinity)
                }
                if yard.overviewOpen {
                    YardOverview(yard: yard)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity.combined(with: .scale(scale: 1.06)))
                        .zIndex(5)
                }
                if yard.launcherOpen {
                    YardLauncher(yard: yard, inline: false)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                        .zIndex(6)
                }
                YardKeyCommands(yard: yard)
            }
        }
        .sheet(item: $askingAbout) { window in
            AskAboutWindowSheet(window: window).environment(model)
        }
    }

    /// The tiles on their track, in the space above the dock.
    private func tracks(size: CGSize) -> some View {
        let windows = model.session?.windows ?? [:]
        let tiles = yard.tiles
        let live = yard.liveWindows
        let keyTarget = yard.keyTarget(in: windows)
        return ZStack(alignment: .topLeading) {
            if let carry = yard.carry, let preview = carry.preview {
                RoundedRectangle(cornerRadius: yard.metrics.cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .strokeBorder(Brand.amber.opacity(0.9), lineWidth: 1.5)
                    .frame(width: preview.width, height: preview.height)
                    .offset(x: preview.minX, y: preview.minY)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            ForEach(yard.layout.windows.filter { live.contains($0) && $0 != yard.fullscreenWindow }, id: \.self) { id in
                if let window = windows[id], let rect = tiles[id] {
                    let carried = yard.carry?.window == id
                    YardTile(window: window, yard: yard, rect: rect, focused: yard.layout.focused == id,
                             keyboard: model.keyboardVisible && keyTarget == id, onAsk: { askingAbout = $0 })
                        .scaleEffect(carried ? (yard.carry?.rect.width ?? rect.width) / max(1, rect.width) : 1, anchor: .top)
                        // Scaled about its top centre, so the centre follows the finger.
                        .offset(x: carried ? yard.carry!.rect.midX - rect.width / 2 : rect.minX,
                                y: carried ? yard.carry!.rect.minY : rect.minY)
                        .shadow(color: .black.opacity(carried ? 0.45 : 0), radius: 24, y: 14)
                        .zIndex(carried ? 2 : 0)
                        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                                removal: .scale(scale: 0.86).combined(with: .opacity)))
                }
            }
            handles
            if let id = yard.fullscreenWindow, let window = windows[id] {
                YardSurface(window: window, pixelsPerPoint: yard.pixelsPerPoint, stretch: false,
                            keyboard: model.keyboardVisible && keyTarget == id) {}
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .top) { leaveFullscreenHandle(id) }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(3)
            }
            popups(windows, keyTarget: keyTarget)
            edges
            if yard.layout.isEmpty {
                YardLauncher(yard: yard, inline: true)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .clipped()
        .onAppear { yard.resize(to: size) }
        .onChange(of: size) { _, size in yard.resize(to: size) }
        // An app going full screen, or leaving it, is laid out again at once.
        .onChange(of: yard.fullscreenWindow) { _, _ in yard.apply() }
        .animation(.smooth(duration: 0.35), value: yard.fullscreenWindow)
    }

    /// A small tab at the top of a full-screen window takes it back into its tile.
    private func leaveFullscreenHandle(_ id: Int) -> some View {
        Capsule()
            .fill(.white.opacity(0.5))
            .frame(width: 36, height: 4)
            .padding(.top, 5)
            .frame(width: 96, height: 22, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { yard.leaveFullscreen(id) }
            .accessibilityLabel("Exit Full Screen")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Gaps

    /// The gaps between tiles, each a grip a finger can find: wider than the gap it sits in,
    /// lit while it is dragged.
    private var handles: some View {
        ForEach(yard.layout.handles(in: yard.metrics), id: \.kind) { handle in
            let rect = handle.rect.offsetBy(dx: -yard.scroll, dy: 0)
            let vertical = if case .width = handle.kind { true } else { false }
            let active = yard.activeHandle == handle.kind
            let grip: CGFloat = 22
            ZStack {
                Capsule()
                    .fill(active ? Brand.amber : .white.opacity(0.0001))
                    .frame(width: vertical ? 4 : min(60, rect.width * 0.3), height: vertical ? min(60, rect.height * 0.3) : 4)
                    .shadow(color: Brand.amber.opacity(active ? 0.8 : 0), radius: 8)
                if active, case .width(let column) = handle.kind, let label = yard.widthLabel(column: column) {
                    Text(label)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: vertical ? grip : rect.width, height: vertical ? rect.height : grip)
            .contentShape(Rectangle())
            .offset(x: vertical ? rect.midX - grip / 2 : rect.minX, y: vertical ? rect.minY : rect.midY - grip / 2)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                    .onChanged { value in yard.dragHandle(handle.kind, translation: value.translation) }
                    .onEnded { value in yard.endHandle(velocity: value.velocity) }
            )
            .hoverEffect(.highlight)
            .accessibilityLabel(vertical ? "Column width" : "Split")
            .zIndex(1)
        }
    }

    /// Swipes in from the side edges move along the track, a column at a time.
    private var edges: some View {
        HStack(spacing: 0) {
            edge(leading: true)
            Spacer(minLength: 0)
            edge(leading: false)
        }
        .frame(width: yard.metrics.size.width, height: yard.metrics.size.height)
        .zIndex(1)
    }

    private func edge(leading: Bool) -> some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
                    .onChanged { value in yard.scrub(by: -value.translation.width) }
                    .onEnded { value in yard.endScrub(velocity: -value.velocity.width) }
            )
    }

    // MARK: Popups

    /// Menus, tooltips and dialogs float above the tiles where the computer put them: a tile's
    /// Linux position is where it is on screen, so they line up with their window.
    @ViewBuilder
    private func popups(_ windows: [Int: RemoteWindow], keyTarget: Int?) -> some View {
        let scale = yard.pixelsPerPoint
        let size = yard.metrics.size
        ForEach(windows.values.filter(\.isAuxiliary).sorted { $0.id < $1.id }) { popup in
            let width = popup.frame.width / scale, height = popup.frame.height / scale
            let x = min(max(0, popup.frame.minX / scale), max(0, size.width - width))
            let y = min(max(0, popup.frame.minY / scale), max(0, size.height - height))
            YardSurface(window: popup, pixelsPerPoint: scale, stretch: false,
                        keyboard: model.keyboardVisible && keyTarget == popup.id) {}
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: popup.isOverrideRedirect ? 6 : yard.metrics.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: popup.isOverrideRedirect ? 8 : 20, y: popup.isOverrideRedirect ? 3 : 10)
                .offset(x: x, y: y)
                .zIndex(3)
        }
    }
}

/// ⌘⌥ (Ctrl+Alt to Linux, the chord Linux desktops keep for the window manager) moves the
/// yard; plain ⌘ stays the apps' Ctrl. They show in the ⌘-hold overlay on iPad.
private struct YardKeyCommands: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel

    var body: some View {
        Group {
            key("Focus Left", .leftArrow) { yard.moveFocus(.left) }
            key("Focus Right", .rightArrow) { yard.moveFocus(.right) }
            key("Focus Up", .upArrow) { yard.moveFocus(.up) }
            key("Focus Down", .downArrow) { yard.moveFocus(.down) }
            key("Move Left", .leftArrow, shift: true) { yard.moveFocused(.left) }
            key("Move Right", .rightArrow, shift: true) { yard.moveFocused(.right) }
            key("Move Up", .upArrow, shift: true) { yard.moveFocused(.up) }
            key("Move Down", .downArrow, shift: true) { yard.moveFocused(.down) }
            key("Cycle Width", "r") { yard.cycleWidth() }
            key("Full Width", "f") { yard.toggleFullWidth() }
            key("Close Window", "w") { if let id = yard.layout.focused { yard.close(id) } }
            key("Overview", "o") { withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen.toggle() } }
            key("Open App", "a") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen.toggle() } }
            key("New Terminal", .return) { model.openTerminalApp() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func key(_ title: String, _ key: KeyEquivalent, shift: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: shift ? [.command, .option, .shift] : [.command, .option])
    }
}
