import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's front door: the computer and what it is doing, the agents at work, the apps
/// and files the owner reaches for, and the actions they take most.
/// A long press on the background, between and around the cards, chooses the wallpaper.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewport: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 18) {
                    VStack(alignment: .leading, spacing: 26) {
                        ComputerCard()
                        AirPlayCard()
                        QuickActions()
                        WorkingAgents()
                        if model.phase == .ready, !model.appWindows.isEmpty { OpenWindows() }
                        AppRow(title: "Pinned", apps: model.pinnedApps)
                        AppRow(title: "Recent", apps: model.recentApps(limit: 8))
                        RecentFilesSection()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                model.wallpaperPickerPresented = true
                            }
                            .accessibilityAction(named: "Choose Wallpaper") { model.wallpaperPickerPresented = true }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
            .scrollIndicators(.hidden)
            .background { ShellBackground() }
            .refreshable {
                await model.refreshApps()
                await model.agents.refresh()
                try? await model.refreshComputer()
            }
            .toolbar { ComputerToolbar() }
            .onAppear { model.airPlay.startWatching() }
            .onDisappear { model.airPlay.stopWatching() }
        }
    }
}

// MARK: The computer

/// The computer at a glance, with the brand's wheels: rolling while it wakes or parks, lit
/// while it runs, unlit while it is parked. Its lifecycle lives in the toolbar.
struct ComputerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                CabooseWordmark(motion: busy ? .rolling : .still, lit: lit)
                    .frame(height: 30)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                StatePill(text: stateText, color: stateColor)
            }
            // The wordmark already says Caboose; a computer renamed in its settings shows its name.
            if let name, name.caseInsensitiveCompare("Caboose") != .orderedSame {
                Text(name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
            }
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if model.phase == .ready {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Label(model.connectionSummary, systemImage: model.isRemote ? "network" : "wifi")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Brand.amber.opacity(lit && !busy ? 0.10 : 0.03)), in: .rect(cornerRadius: 28))
        .animation(.smooth, value: model.phase)
    }

    private var name: String? { model.computerStatus?.settings.name ?? model.computer?.name }

    private var busy: Bool {
        model.parking || [.waking, .connecting, .restarting].contains(model.phase)
    }

    private var lit: Bool {
        switch model.phase {
        case .parked, .failed: false
        default: !model.parking
        }
    }

    private var stateText: String {
        if model.parking { return "Parking" }
        switch model.phase {
        case .ready: return "Running"
        case .waking: return "Waking"
        case .connecting: return "Connecting"
        case .restarting: return "Restarting"
        case .parked: return "Parked"
        case .failed: return "Out of Reach"
        case .displayElsewhere: return "On Another Device"
        case .needsSetup: return ""
        }
    }

    private var stateColor: Color {
        if model.parking { return Brand.amber }
        switch model.phase {
        case .ready: return .green
        case .waking, .connecting, .restarting: return Brand.amber
        case .failed: return .orange
        default: return .secondary
        }
    }

    /// The machine's specs while it is up, or why it is not.
    private var detail: String? {
        switch model.phase {
        case .ready, .displayElsewhere:
            guard let computer = model.computer else { return nil }
            let line = "\(computer.image) · \(computer.vcpus) cores · \(computer.memoryMb / 1024) GB"
            return model.isRemote ? line + " · Remote" : line
        case .failed(let message): return HostMessage.clipped(message, maxLines: 2, maxCharacters: 160)
        default: return nil
        }
    }
}

struct StatePill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: AirPlay

/// One tap to play on the AirPlay device used last; the picker beside it chooses another.
/// See `AirPlayCenter` for what iOS lets an app do here.
struct AirPlayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let airPlay = model.airPlay
        let onTV = model.externalDisplayActive
        let playing = airPlay.current != nil || onTV
        HStack(spacing: 14) {
            Button { airPlay.connect() } label: {
                HStack(spacing: 14) {
                    Image(systemName: onTV ? "tv" : "airplay.audio")
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: airPlay.connecting)
                        .foregroundStyle(playing ? Brand.amber : .white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        if let status { Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(airPlay.connecting || onTV || airPlay.current != nil)
            // The system's own picker: another device, or back to the phone.
            AirPlayRoutePicker()
                .frame(width: 36, height: 36)
                .accessibilityLabel("AirPlay devices")
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var title: String {
        let airPlay = model.airPlay
        if model.externalDisplayActive { return "Desktop on TV" }
        if let current = airPlay.current { return current.name }
        if let last = airPlay.last { return last.name }
        return "AirPlay"
    }

    private var status: String? {
        let airPlay = model.airPlay
        if model.externalDisplayActive { return "Screen Mirroring" }
        if airPlay.current != nil { return "Playing" }
        if airPlay.connecting { return "Connecting" }
        if let notice = airPlay.notice { return notice }
        return airPlay.last != nil ? "AirPlay" : nil
    }
}

// MARK: Quick actions

struct QuickActions: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if model.agents.available {
                tile("Ask an Agent", "sparkles") {
                    model.selectedTab = .agents
                    model.askFocusRequested = true
                }
            }
            // The native terminal only. The computer's own terminal apps stay in Apps and the dock.
            if TerminalSlot.isFilled {
                tile("Terminal", "apple.terminal") { model.selectedTab = .terminal }
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.amber)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .contentShape(.rect(cornerRadius: 20))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Agents

/// Agents working now or waiting on the owner. Approvals can be answered right here.
struct WorkingAgents: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        let active = agents.tasks.filter { $0.isRunning || $0.pendingApproval != nil }
        let local = agents.localRuns.filter { $0.status == .working }
        if !active.isEmpty || !local.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Agents at Work") { model.selectedTab = .agents }
                ForEach(local) { run in
                    AgentRow(title: run.prompt, detail: run.steps.last ?? "Working…", agent: "On iPhone", waiting: false)
                }
                ForEach(active.sorted { ($0.pendingApproval != nil ? 0 : 1) < ($1.pendingApproval != nil ? 0 : 1) }.prefix(4)) { task in
                    VStack(alignment: .leading, spacing: 10) {
                        AgentRow(title: task.prompt,
                                 detail: task.pendingApproval.map { "Wants to use \($0.tool)" } ?? task.summary ?? agents.output[task.id]?.last?.text ?? (task.status == "paused" ? "Paused" : "Working…"),
                                 agent: agents.name(of: task), waiting: task.pendingApproval != nil)
                        if let approval = task.pendingApproval {
                            ApprovalRow(task: task, approval: approval)
                        }
                    }
                    .padding(14)
                    .glassEffect(.regular.tint(task.pendingApproval != nil ? Color.yellow.opacity(0.10) : .clear), in: .rect(cornerRadius: 20))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedTab = .agents }
                }
            }
        }
    }
}

private struct AgentRow: View {
    let title: String
    let detail: String
    let agent: String
    let waiting: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if waiting {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).font(.title3)
                } else {
                    CabooseWheel(motion: .rolling)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Text(agent).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Windows, apps and files

struct OpenWindows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Open")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(model.appWindows) { window in
                        Button { model.show(windowID: window.id) } label: {
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
            .scrollClipDisabled()
        }
    }
}

/// A row of app icons: the pinned apps, or the recently opened ones. Hidden when empty.
struct AppRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let apps: [HostClient.App]

    var body: some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title) { model.selectedTab = .apps }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(apps) { app in
                            AppButton(app: app).frame(width: 76)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }
}

/// An app icon that opens the app, with Pin and Unpin in its menu.
struct AppButton: View {
    @Environment(AppModel.self) private var model
    let app: HostClient.App

    var body: some View {
        Button { model.open(app) } label: {
            AppTile(app: app, icon: model.appIcons[app.id], launching: model.launching == app)
        }
        .buttonStyle(.plain)
        .contextMenu {
            let pinned = model.shortcuts.isPinned(app.id)
            Button(pinned ? "Unpin from Home" : "Pin to Home", systemImage: pinned ? "pin.slash" : "pin") { model.togglePin(app) }
        }
    }
}

/// The newest files in the computer's home. A tap opens one with its app.
struct RecentFilesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentFiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recent Files")
                VStack(spacing: 0) {
                    ForEach(Array(model.recentFiles.prefix(6).enumerated()), id: \.element.path) { index, file in
                        if index > 0 { Divider().padding(.leading, 58) }
                        Button { Task { await model.openFile(file.path) } } label: { FileRow(file: file) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        }
    }
}

private struct FileRow: View {
    let file: RecentFile

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: name))
                .font(.title3)
                .foregroundStyle(Brand.amber)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(folder.isEmpty ? "Home" : folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Date(timeIntervalSince1970: file.mtime / 1000), format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    static func symbol(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct SectionHeader: View {
    let title: String
    var more: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let more {
                Button("See All", action: more).font(.subheadline.weight(.semibold))
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
                    CabooseWheel(motion: .rolling).frame(width: 26, height: 26)
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
