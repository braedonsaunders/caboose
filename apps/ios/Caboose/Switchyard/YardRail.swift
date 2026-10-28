import CabooseKit
import SwiftUI

/// The rail along the bottom: the track in miniature, one car per column.
///
/// At rest it is a small glass capsule of dots, the focused column's drawn long, so it hides
/// next to nothing. Touched, it opens into cars with each app's icon: slide along it to move
/// along the track, tap a car to go to that column, swipe up for Overview, or open an app
/// with the plus.
struct YardRail: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel
    @State private var open = false
    @State private var scrubbing = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        let columns = yard.layout.columns
        let visible = Set(yard.layout.visibleColumns(at: yard.scroll, in: yard.metrics))
        let focusedColumn = yard.layout.focusedColumnIndex.map { columns[$0].id }
        HStack(spacing: open ? 6 : 5) {
            if open {
                railButton("Overview", "square.grid.2x2") { withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true } }
            }
            ForEach(columns) { column in
                if open {
                    car(column, focused: column.id == focusedColumn, visible: visible.contains(column.id))
                } else {
                    Capsule()
                        .fill(column.id == focusedColumn ? Brand.amber : .white.opacity(visible.contains(column.id) ? 0.9 : 0.4))
                        .frame(width: column.id == focusedColumn ? 14 : 5, height: 5)
                }
            }
            if open {
                railButton("Open App", "plus") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = true } }
            }
        }
        .padding(.horizontal, open ? 8 : 9)
        .padding(.vertical, open ? 6 : 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Capsule().inset(by: -10))
        .gesture(scrub(columns: columns.count))
        .onTapGesture { expand() }
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.3, extraBounce: 0.1), value: open)
        .animation(.smooth(duration: 0.3), value: focusedColumn)
        .accessibilityElement(children: open ? .contain : .ignore)
        .accessibilityLabel("Columns")
        .accessibilityValue("\(columns.count) columns")
        .accessibilityAction(named: "Overview") { yard.overviewOpen = true }
    }

    private func car(_ column: YardLayout.Column, focused: Bool, visible: Bool) -> some View {
        Button {
            if let first = column.windows.first { yard.jump(to: first) }
            closeSoon()
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
                    .frame(width: column.windows.count > 1 ? 12 : 20, height: column.windows.count > 1 ? 12 : 20)
                }
            }
            .frame(width: 18 + 22 * min(1, yard.metrics.effectiveFraction(column.width)), height: 26)
            .background(.white.opacity(visible ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Brand.amber : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(column.windows.compactMap { model.session?.windows[$0]?.title }.joined(separator: ", "))
    }

    private func railButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            closeSoon(after: 0.2)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    /// Sliding along the rail slides the screen along the track, with the whole track mapped
    /// onto the rail's length; a swipe up opens Overview.
    private func scrub(columns: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !scrubbing {
                    scrubbing = true
                    expand()
                }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let track = yard.layout.trackWidth(in: yard.metrics)
                let rail = max(80, CGFloat(columns) * 44)
                yard.scrub(by: value.translation.width * max(1, track / rail))
            }
            .onEnded { value in
                scrubbing = false
                if value.translation.height < -36, abs(value.translation.height) > abs(value.translation.width) {
                    withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
                    yard.endScrub(velocity: 0)
                } else {
                    let track = yard.layout.trackWidth(in: yard.metrics)
                    let rail = max(80, CGFloat(columns) * 44)
                    yard.endScrub(velocity: value.velocity.width * max(1, track / rail))
                }
                closeSoon()
            }
    }

    private func expand() {
        open = true
        closeSoon(after: 3)
    }

    private func closeSoon(after delay: Double = 1.6) {
        closeTask?.cancel()
        closeTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !scrubbing else { return }
            open = false
        }
    }
}
