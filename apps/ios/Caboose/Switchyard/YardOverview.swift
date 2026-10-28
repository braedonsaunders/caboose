import CabooseKit
import SwiftUI

/// Overview: the whole track at once, shrunk to fit, over the frosted desktop. Tap a window
/// to go to it, swipe one up to close it, or open another app at the end.
struct YardOverview: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel

    var body: some View {
        let metrics = yard.metrics
        let frames = yard.layout.frames(in: metrics)
        let columnFrames = yard.layout.columnFrames(in: metrics)
        let track = yard.layout.trackWidth(in: metrics)
        let scale = min(0.5, max(0.22, (metrics.size.width - 48) / max(1, track)))
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .onTapGesture { close() }
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(yard.layout.columns) { column in
                            let columnFrame = columnFrames[column.id] ?? .zero
                            VStack(spacing: 8) {
                                ForEach(column.windows, id: \.self) { id in
                                    if let window = model.session?.windows[id], let frame = frames[id] {
                                        OverviewCard(window: window, size: CGSize(width: frame.width * scale, height: frame.height * scale),
                                                     focused: yard.layout.focused == id, radius: metrics.cornerRadius * max(0.6, scale * 1.6)) {
                                            withAnimation(.smooth(duration: 0.38)) { yard.jump(to: id) }
                                        } close: {
                                            yard.close(id)
                                        }
                                    }
                                }
                            }
                            .frame(width: columnFrame.width * scale)
                            .id(column.id)
                        }
                        Button {
                            withAnimation(.smooth(duration: 0.3)) {
                                yard.overviewOpen = false
                                yard.launcherOpen = true
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .frame(width: max(64, 120 * scale * 2), height: max(64, metrics.columnHeight * scale))
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Open App")
                    }
                    .padding(.horizontal, 24)
                    .frame(minWidth: metrics.size.width, minHeight: metrics.size.height)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let index = yard.layout.focusedColumnIndex { reader.scrollTo(yard.layout.columns[index].id, anchor: .center) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func close() {
        withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = false }
    }
}

/// One window in Overview: its live picture with its icon and title under it. Swiped up, it
/// closes, as in the app switcher.
private struct OverviewCard: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let size: CGSize
    let focused: Bool
    let radius: CGFloat
    let open: () -> Void
    let close: () -> Void
    @State private var lift: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            RemoteWindowPreview(window: window)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(focused ? AnyShapeStyle(YardStyle.ring) : AnyShapeStyle(.white.opacity(0.18)), lineWidth: focused ? 1.5 : 0.75)
                }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            HStack(spacing: 5) {
                if let icon = model.icon(for: window) { Image(uiImage: icon).resizable().frame(width: 14, height: 14) }
                Text(window.title.isEmpty ? "Window" : window.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: max(80, size.width))
            .foregroundStyle(.white)
        }
        .offset(y: lift)
        .opacity(1 - Double(min(1, -lift / 240)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in lift = min(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height < -90 || value.velocity.height < -700 {
                        withAnimation(.smooth(duration: 0.25)) { lift = -600 }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        close()
                    } else {
                        withAnimation(.smooth(duration: 0.3, extraBounce: 0.15)) { lift = 0 }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Close Window", close)
    }
}

/// The computer's apps, to open one in the yard: on the empty desktop, or over it from the
/// dock, Overview or ⌘⌥A.
struct YardLauncher: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel
    let inline: Bool

    var body: some View {
        let apps = model.partitionedApps.main
        ZStack {
            if !inline {
                Rectangle().fill(.ultraThinMaterial)
                    .onTapGesture { close() }
            }
            VStack(spacing: 18) {
                if inline {
                    Text("Open an app")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 14)], spacing: 18) {
                        ForEach(apps) { app in
                            Button {
                                close()
                                model.open(app)
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if let icon = model.appIcons[app.id] {
                                            Image(uiImage: icon).resizable().scaledToFit()
                                        } else {
                                            Image(systemName: "app.dashed").font(.largeTitle)
                                        }
                                    }
                                    .frame(width: 52, height: 52)
                                    Text(app.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: 560, maxHeight: inline ? 420 : 520)
                .fixedSize(horizontal: false, vertical: apps.count < 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }

    private func close() {
        guard !inline else { return }
        withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = false }
    }
}
