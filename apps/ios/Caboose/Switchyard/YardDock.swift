import CabooseKit
import SwiftUI

/// The Desktop tab's dock, under the tiles: the everyday apps on the left, then the track in
/// miniature, one car per column, and Overview and All Apps.
///
/// A tap on an app goes to its window, or opens it. Slide along the cars
/// to move along the track, tap one to go to that column. A swipe up on the dock opens
/// Overview. Holding Overview opens Quick Switch: slide up to a window and let go to go to
/// it, or let go anywhere else to stay.
struct YardDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    let yard: YardModel
    let width: CGFloat

    static let height: CGFloat = 58
    private let icon: CGFloat = 38
    private let car: CGFloat = 30

    var body: some View {
        let columns = yard.layout.columns
        let visible = Set(yard.layout.visibleColumns(at: yard.scroll, in: yard.metrics))
        let focusedColumn = yard.layout.focusedColumnIndex.map { columns[$0].id }
        // As many apps as fit beside the cars and the two buttons.
        let fixed = CGFloat(columns.count) * (car + 4) + 2 * 34 + 48 + (portraitDesktop ? 54 : 0)
        let apps = Array(model.dockApps.prefix(max(2, Int((width - 32 - fixed) / (icon + 10)))))
        HStack(spacing: 10) {
            ForEach(apps) { app in
                // A tap goes to the app; holding it offers Open, Pin and Close. A menu with a
                // primary action shows on the hold itself, so neither the dock's swipe nor the
                // system's bottom edge can take the press from it.
                Menu { DockAppActions(app: app) } label: {
                    VStack(spacing: 3) {
                        Group {
                            if let image = model.appIcons[app.id] {
                                Image(uiImage: image).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").font(.title2)
                            }
                        }
                        .frame(width: icon, height: icon)
                        Circle()
                            .fill(.white.opacity(isRunning(app) ? 0.85 : 0))
                            .frame(width: 4, height: 4)
                    }
                    .contentShape(Rectangle())
                } primaryAction: {
                    model.openOnDesktop(app)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel(app.name)
                .accessibilityHint("Hold for Open, Pin and Close.")
            }
            if !columns.isEmpty {
                Divider().frame(height: 34).overlay(.white.opacity(0.3))
                HStack(spacing: 4) {
                    ForEach(columns) { column in
                        Car(column: column, yard: yard, focused: column.id == focusedColumn, visible: visible.contains(column.id), size: car)
                    }
                }
                .simultaneousGesture(scrub(columns: columns.count))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Columns")
            }
            Divider().frame(height: 34).overlay(.white.opacity(0.3))
            OverviewControl(yard: yard, enabled: !columns.isEmpty)
            button("All Apps", "square.grid.3x3.fill") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = true } }
            if portraitDesktop { DesktopPanelButton() }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard value.translation.height < -30, abs(value.translation.height) > abs(value.translation.width), !columns.isEmpty else { return }
                // A finger that held Overview and slid up was choosing a window, not asking for Overview.
                let switcher = model.quickSwitch
                guard switcher.mode != .hold, Date().timeIntervalSince(switcher.holdEnded) > 0.4 else { return }
                withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
            }
        )
        .animation(.smooth(duration: 0.3), value: focusedColumn)
        .animation(.smooth(duration: 0.3), value: columns.map(\.id))
    }

    private func isRunning(_ app: HostClient.App) -> Bool {
        model.appWindows.contains { model.matches($0, app) }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    /// Sliding along the cars slides the screen along the track, the whole track mapped onto
    /// the cars' length.
    private func scrub(columns: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                yard.scrub(by: value.translation.width * ratio(columns))
            }
            .onEnded { value in yard.endScrub(velocity: value.velocity.width * ratio(columns)) }
    }

    private func ratio(_ columns: Int) -> CGFloat {
        let track = yard.layout.trackWidth(in: yard.metrics)
        return max(1, track / max(car, CGFloat(columns) * (car + 4)))
    }
}

/// Overview on the dock. A tap opens Overview. Held, it opens Quick Switch with nothing
/// selected: sliding up selects the window level with the finger, and letting go goes to it;
/// letting go off the strip, or the gesture being cancelled, stays. VoiceOver offers Switch
/// Windows, which opens the strip to choose from, with Stay Here.
private struct OverviewControl: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel
    let enabled: Bool
    @GestureState private var held = false

    var body: some View {
        let switcher = model.quickSwitch
        Image(systemName: "square.grid.2x2")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(.white.opacity(switcher.owner == .yard && switcher.mode == .hold ? 0.22 : 0), in: Circle())
            .contentShape(Rectangle())
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($held) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !(switcher.owner == .yard && switcher.mode == .hold) {
                            switcher.hold(recent: recent, desktop: yard.switchTarget())
                        }
                        if let drag { switcher.track(drag.location) }
                    }
                    .onEnded { _ in switcher.release() }
                    .exclusively(before: TapGesture().onEnded { openOverview() }),
                including: enabled ? .all : .none
            )
            // A hold the system took away (a call, a system gesture) stays where it was.
            .onChange(of: held) { _, held in
                if !held, switcher.owner == .yard, switcher.mode == .hold { switcher.cancel() }
            }
            .accessibilityElement()
            .accessibilityLabel("Overview")
            .accessibilityHint("Hold and slide up to switch windows.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openOverview() }
            .accessibilityAction(named: "Switch Windows") {
                switcher.present(recent: recent, desktop: yard.switchTarget())
            }
            .disabled(!enabled)
    }

    private var recent: [Int] { model.recentWindowIDs.filter { yard.layout.contains($0) } }

    private func openOverview() {
        guard enabled else { return }
        withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
    }
}

/// One column on the dock: its apps' icons, lit while it is on screen, ringed while it has
/// the keyboard. Tapped, the screen goes to it.
private struct Car: View {
    @Environment(AppModel.self) private var model
    let column: YardLayout.Column
    let yard: YardModel
    let focused: Bool
    let visible: Bool
    let size: CGFloat

    var body: some View {
        Menu {
            ForEach(column.windows, id: \.self) { id in
                if let window = model.session?.windows[id] {
                    Section(window.title.isEmpty ? model.appName(for: window) : window.title) {
                        Button("Open", systemImage: "arrow.up.forward.app") { yard.jump(to: id) }
                        if let app = model.apps.first(where: { model.matches(window, $0) }) {
                            let pinned = model.pinnedApps.contains { $0.id == app.id }
                            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                                model.togglePin(app)
                            }
                        }
                        Button("Close", systemImage: "xmark", role: .destructive) {
                            model.session?.close(window)
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                ForEach(column.windows.prefix(3), id: \.self) { id in
                    Group {
                        if let window = model.session?.windows[id], let icon = model.icon(for: window) {
                            Image(uiImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .frame(width: column.windows.count > 1 ? 13 : 20, height: column.windows.count > 1 ? 13 : 20)
                }
            }
            .frame(width: size, height: 36)
            .background(.white.opacity(visible ? 0.24 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? AnyShapeStyle(YardStyle.ring) : AnyShapeStyle(.clear), lineWidth: 1.5)
            }
        } primaryAction: {
            if let first = column.windows.first { yard.jump(to: first) }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(column.windows.compactMap { model.session?.windows[$0]?.title }.joined(separator: ", "))
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityHint("Hold for window actions.")
    }
}

/// The same actions for a held dock icon in tiled and free desktops (`DockMenu`).
struct DockAppActions: View {
    @Environment(AppModel.self) private var model
    let app: HostClient.App
    /// After an action, for a menu that does not close itself.
    var done: () -> Void = {}

    var body: some View {
        let windows = model.appWindows.filter { model.matches($0, app) }
        let actions = DockMenu.actions(appName: app.name, pinned: model.pinnedApps.contains { $0.id == app.id },
                                       windows: windows.map { DockMenu.Window(id: $0.id, title: $0.title) })
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            switch action {
            case .open:
                Button(action.title, systemImage: "arrow.up.forward.app") { model.openOnDesktop(app); done() }
            case .pin, .unpin:
                Button(action.title, systemImage: action == .pin ? "pin" : "pin.slash") { model.togglePin(app); done() }
            case .close(let id, _):
                Button(action.title, systemImage: "xmark", role: .destructive) {
                    if let window = model.session?.windows[id] { model.session?.close(window) }
                    done()
                }
            }
        }
    }
}
