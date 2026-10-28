import CabooseKit
import SwiftUI

/// The Desktop tab's dock, under the tiles: the everyday apps on the left, then the track in
/// miniature, one car per column, and Overview and All Apps.
///
/// A tap on an app goes to its window, or opens it. The cars are the rail: slide along them
/// to move along the track, tap one to go to that column. A swipe up on the dock opens
/// Overview.
struct YardDock: View {
    @Environment(AppModel.self) private var model
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
        let fixed = CGFloat(columns.count) * (car + 4) + 2 * 34 + 48
        let apps = Array(model.dockApps.prefix(max(2, Int((width - 32 - fixed) / (icon + 10)))))
        HStack(spacing: 10) {
            ForEach(apps) { app in
                Button { model.open(app) } label: {
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.name)
            }
            if !columns.isEmpty {
                Divider().frame(height: 34).overlay(.white.opacity(0.3))
                HStack(spacing: 4) {
                    ForEach(columns) { column in
                        Car(column: column, yard: yard, focused: column.id == focusedColumn, visible: visible.contains(column.id), size: car)
                    }
                }
                .gesture(scrub(columns: columns.count))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Columns")
            }
            Divider().frame(height: 34).overlay(.white.opacity(0.3))
            button("Overview", "square.grid.2x2") { withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true } }
                .disabled(columns.isEmpty)
            button("All Apps", "square.grid.3x3.fill") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = true } }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard value.translation.height < -30, abs(value.translation.height) > abs(value.translation.width), !columns.isEmpty else { return }
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
        Button {
            if let first = column.windows.first { yard.jump(to: first) }
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(column.windows.compactMap { model.session?.windows[$0]?.title }.joined(separator: ", "))
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}
