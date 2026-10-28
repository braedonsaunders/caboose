import CabooseKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                AgentSection()
                if !model.appWindows.isEmpty { openWindows }
                appsGrid
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refreshApps(); await model.agents.refresh() }
        .safeAreaInset(edge: .bottom) {
            if model.agents.available {
                AskBar().padding(.horizontal, 16).padding(.bottom, 6)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.presentedAgentWindowID != nil },
            set: { if !$0 { model.presentedAgentWindowID = nil } })) {
            AgentWindowScreen().environment(model)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Caboose")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                if let latency = model.session?.latencyMs {
                    Label("\(Int(latency)) ms to your computer", systemImage: "speedometer")
                }
                Button("Park Computer Now", systemImage: "moon.zzz") {
                    Task { try? await model.host?.park(); model.sceneEnteredBackground() }
                }
                Button("Change Computer", systemImage: "arrow.left.arrow.right", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "train.side.rear.car")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private var statusLine: String {
        guard let computer = model.computer else { return "Awake" }
        return "\(computer.image) · \(computer.vcpus) cores · \(computer.memoryMb / 1024) GB"
    }

    private var openWindows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open").font(.headline).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(model.appWindows) { window in
                        Button { model.presentedWindowID = window.id } label: {
                            WindowCard(window: window, icon: model.icon(for: window))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Close", systemImage: "xmark", role: .destructive) { model.session?.close(window) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var appsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apps").font(.headline).foregroundStyle(.secondary)
            if model.apps.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding your apps…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.apps) { app in
                        Button { model.open(app) } label: { AppTile(app: app, icon: model.appIcons[app.id], launching: model.launching == app) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct AppTile: View {
    let app: HostClient.App
    let icon: UIImage?
    let launching: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.08))
                if let icon {
                    Image(uiImage: icon).resizable().scaledToFit().padding(10)
                } else {
                    Image(systemName: "app.dashed").font(.title)
                }
                if launching {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.45))
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 68, height: 68)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            Text(app.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
    }
}

/// A live, non-interactive preview of an open window.
struct WindowCard: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let icon: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteWindowPreview(window: window)
                .frame(width: 150, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
            HStack(spacing: 6) {
                if let icon { Image(uiImage: icon).resizable().frame(width: 16, height: 16) }
                Text(window.title.isEmpty ? "Window" : window.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
    }
}
