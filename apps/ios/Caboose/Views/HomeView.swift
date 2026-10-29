import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's front door, Today: the computer and what it is doing; its windows, live, or as
/// they were while it is parked; what is waiting on the owner; what the agents are doing; what
/// came in while the owner was away; and their pinned apps. Ask, beside the tabs on an iPhone
/// held upright and along the bottom elsewhere, opens anything by name or hands it to an agent.
/// A long press on the background, between and around the sections, chooses the wallpaper.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.shellTabPlacement) private var placement
    @State private var showingAirPlay = false

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                let column = max(0, min(1040, viewport.size.width) - 40)
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        TodayHeader()
                        OnScreenStrip(wide: column >= 600)
                        if column >= 720 && hasAgentWork && hasActivity {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 30) {
                                    NeedsYou()
                                    Working()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                SinceYouLeft().frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            NeedsYou()
                            Working()
                            SinceYouLeft()
                        }
                        PinnedApps()
                        RecentHomeApps()
                    }
                    .environment(\.homeColumnWidth, column)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    // Measure outside the scroll content, whose intrinsic row widths can
                    // exceed the column. Every row now receives this finite proposal.
                    .frame(width: min(1040, viewport.size.width))
                    .frame(width: viewport.size.width)
                    .frame(minHeight: viewport.size.height, alignment: .top)
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
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }
            .scrollIndicators(.hidden)
            .background { ShellBackground() }
            .refreshable {
                await model.refreshApps()
                await model.agents.refresh()
                try? await model.refreshComputer()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Beside the tabs when they are a cluster; on its own line otherwise.
                if placement != .cluster {
                    HomeAskField()
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("AirPlay", systemImage: "airplayvideo") { showingAirPlay = true }
                        .tint(airPlaying ? Brand.amber : nil)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ComputerToolbar()
            }
            .sheet(isPresented: $showingAirPlay) {
                AirPlaySheet().environment(model).presentationDetents([.medium])
            }
            .onAppear {
                model.airPlay.startWatching()
                HomeFrames.shared.load(for: model.credentials?.fileDomainIdentifier)
            }
            .onDisappear { model.airPlay.stopWatching() }
        }
    }

    private var hasAgentWork: Bool {
        model.agents.tasks.contains { $0.isRunning || $0.pendingApproval != nil }
    }

    private var hasActivity: Bool {
        !RecentFiles.visible(model.recentFiles, limit: 1).isEmpty
    }

    private var airPlaying: Bool { model.airPlay.current != nil || model.externalDisplayActive }
}

// MARK: The computer

/// Today's date, the computer's name (the wordmark while it is called Caboose), and one line
/// on how it is: running with its windows and agents, waking, parked, or out of reach, with
/// the one action that fits.
struct TodayHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            ComputerSwitcher {
                if let name {
                    Text(name)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    CabooseWordmark(motion: busy ? .rolling : (lit ? .idle : .still), lit: lit)
                        .frame(height: 32)
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.vertical, 4)
                        .accessibilityLabel("Caboose")
                }
            }
            HStack(spacing: 8) {
                indicator
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            if let action {
                Button(action.title, systemImage: action.symbol) { Task { await model.wake() } }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.amber)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth, value: model.phase)
        .animation(.smooth, value: model.parking)
    }

    /// The name the computer was given in its settings; nil while it is still "Caboose".
    private var name: String? {
        guard let name = model.computerStatus?.settings.name ?? model.computer?.name ?? model.credentials?.computerName,
              !name.isEmpty, name.caseInsensitiveCompare("Caboose") != .orderedSame else { return nil }
        return name
    }

    private var busy: Bool { model.parking || [.waking, .connecting, .restarting].contains(model.phase) }

    private var lit: Bool {
        switch model.phase {
        case .parked, .failed: false
        default: !model.parking
        }
    }

    @ViewBuilder private var indicator: some View {
        if busy {
            CabooseWheel(motion: .rolling).frame(width: 15, height: 15)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(model.phase == .ready ? 0.9 : 0), radius: 4)
                .frame(width: 15, height: 15)
        }
    }

    private var dotColor: Color {
        switch model.phase {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var status: String {
        if model.parking { return "Parking…" }
        switch model.phase {
        case .ready:
            var parts = ["Running"]
            let windows = model.appWindows.count
            if windows > 0 { parts.append(windows == 1 ? "1 window" : "\(windows) windows") }
            let working = model.agents.tasks.filter { $0.isRunning && $0.pendingApproval == nil }.count
            if working > 0 { parts.append(working == 1 ? "1 agent working" : "\(working) agents working") }
            if model.isRemote { parts.append("Remote") }
            return parts.joined(separator: " · ")
        case .waking: return "Waking…"
        case .connecting: return "Connecting…"
        case .restarting: return "Restarting…"
        case .parked: return "Parked · every app kept as it was"
        case .failed(let message): return HostMessage.clipped(message, maxLines: 2, maxCharacters: 140)
        case .displayElsewhere: return "Showing on another device"
        case .needsSetup: return ""
        }
    }

    private var action: (title: String, symbol: String)? {
        guard !model.parking else { return nil }
        switch model.phase {
        case .parked: return ("Turn On", "power")
        case .failed: return ("Try Again", "arrow.clockwise")
        case .displayElsewhere: return ("Show Here", "iphone")
        default: return nil
        }
    }
}

// MARK: Windows

/// The computer's windows in the order they were last used, live and small, each opening
/// full screen on a tap. While the computer is not running, the pictures kept when the
/// owner left (`HomeFrames`) stand in for them, dimmed; a tap on one turns the computer on,
/// and the live windows take their place once it is back (`HomeToday.strip`).
struct OnScreenStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.homeColumnWidth) private var columnWidth
    let wide: Bool
    private var frames = HomeFrames.shared

    init(wide: Bool) { self.wide = wide }

    var body: some View {
        let windows = model.phase == .ready ? model.appWindows : []
        // A lone app stays a thumbnail; the number of windows never stretches it.
        let height: CGFloat = wide ? 196 : 156
        let width = min(320, columnWidth ?? 320)
        let strip = HomeToday.strip(running: model.phase == .ready, live: windows.count, kept: frames.frames.count)
        Group {
            switch strip {
            case .live:
                VStack(alignment: .leading, spacing: 12) {
                    TodaySectionHeader(title: "On Screen", count: windows.count, link: "Desktop") { model.selectedTab = .desktop }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(windows) { window in
                                LiveWindowTile(window: window, height: height, width: width)
                            }
                        }
                    }
                    .homeColumnRow(cornerRadius: LiveWindowTile.cornerRadius, bottom: 6)
                }
                .transition(.opacity)
            case .kept:
                VStack(alignment: .leading, spacing: 12) {
                    TodaySectionHeader(title: "As You Left It", detail: frames.takenAt.map { $0.formatted(date: .omitted, time: .shortened) })
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(frames.frames) { frame in
                                KeptWindowTile(frame: frame, image: frames.images[frame.id], height: height, width: width,
                                               waking: waking) { turnOn() }
                            }
                        }
                    }
                    .homeColumnRow(cornerRadius: LiveWindowTile.cornerRadius, bottom: 6)
                }
                .transition(.opacity)
            case .none:
                EmptyView()
            }
        }
        .animation(.smooth, value: strip)
    }

    private var waking: Bool { model.phase == .waking || model.phase == .connecting }

    private func turnOn() {
        guard !waking, !model.parking else { return }
        Task { await model.wake() }
    }
}

/// One live window: its picture at the tile's size, its app's icon and name under it.
struct LiveWindowTile: View {
    static let cornerRadius: CGFloat = 18
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let height: CGFloat
    var width: CGFloat? = nil

    var body: some View {
        let size = HomeToday.previewSize(window: window.frame.size, height: height, maximumWidth: width ?? 320)
        let previewWidth = size.width
        Button { model.show(windowID: window.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteWindowPreview(window: window, width: previewWidth)
                    .frame(width: previewWidth, height: size.height, alignment: .topLeading)
                    .frame(width: size.width, height: size.height)
                    .background(Color(white: 0.08))
                    .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                TileLabel(icon: model.icon(for: window), app: model.appName(for: window), title: window.title, width: size.width)
            }
            .contentShape(.rect)
        }
        .buttonStyle(TilePress())
        .contextMenu {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { model.show(windowID: window.id) }
            Button("Close", systemImage: "xmark", role: .destructive) { model.session?.close(window) }
        }
        .accessibilityLabel("\(model.appName(for: window)), \(window.title)")
        .accessibilityHint("Opens full screen")
    }
}

/// A window as it was when the owner left: its kept picture, dimmed while the computer rests.
private struct KeptWindowTile: View {
    @Environment(AppModel.self) private var model
    let frame: HomeFrames.Frame
    let image: UIImage?
    let height: CGFloat
    var width: CGFloat? = nil
    let waking: Bool
    let resume: () -> Void

    var body: some View {
        let size = HomeToday.previewSize(window: CGSize(width: frame.width, height: frame.height), height: height, maximumWidth: width ?? 320)
        Button(action: resume) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Color(white: 0.08)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height, alignment: width == nil ? .topLeading : .center)
                            .saturation(0.35)
                            .brightness(-0.18)
                    }
                    if waking {
                        CabooseWheel(motion: .rolling).frame(width: 26, height: 26)
                            .padding(10)
                            .glassEffect(.regular, in: .circle)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: LiveWindowTile.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LiveWindowTile.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                TileLabel(icon: model.apps.first { $0.name == frame.app }.flatMap { model.appIcons[$0.id] }, app: frame.app, title: frame.title, width: size.width)
                    .opacity(0.7)
            }
            .contentShape(.rect)
        }
        .buttonStyle(TilePress())
        .accessibilityLabel("\(frame.app), \(frame.title)")
        .accessibilityHint("Turns the computer on")
    }
}

private struct TileLabel: View {
    let icon: UIImage?
    let app: String
    let title: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(uiImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: "macwindow").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app).font(.caption.weight(.semibold)).lineLimit(1)
                if !title.isEmpty && title != app {
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A tile pressed sinks a little, as a card does.
private struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: Agents

/// Approvals the agents are waiting on, answered right here.
struct NeedsYou: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.agents.awaitingApproval
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                TodaySectionHeader(title: "Needs You", count: waiting.count)
                ForEach(waiting.prefix(3)) { task in
                    if let approval = task.pendingApproval {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.agents.title(of: task))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            ApprovalRow(task: task, approval: approval)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.tint(Brand.amber.opacity(0.10)), in: .rect(cornerRadius: 24))
                        .contentShape(Rectangle())
                        .onTapGesture { openChat(task.id) }
                    }
                }
            }
        }
    }

    private func openChat(_ id: String) {
        model.agents.focusedTask = id
        model.selectedTab = .agents
    }
}

/// Agents at work now, with the last thing each said.
struct Working: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        let working = agents.tasks.filter { $0.isRunning && $0.pendingApproval == nil }
        if !working.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                TodaySectionHeader(title: "Working", link: "Agents") { model.selectedTab = .agents }
                VStack(spacing: 0) {
                    ForEach(Array(working.prefix(4).enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().padding(.leading, 54) }
                        Button {
                            agents.focusedTask = task.id
                            model.selectedTab = .agents
                        } label: {
                            TodayRow(title: agents.title(of: task),
                                     detail: agents.output[task.id]?.last?.text ?? (task.status == "paused" ? "Paused" : agents.name(of: task))) {
                                CabooseWheel(motion: task.status == "paused" ? .still : .rolling).frame(width: 20, height: 20)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
        }
    }
}

// MARK: Since you left

/// What finished and changed while the owner was away (`HomeToday.arrivals`), since the app
/// last left the screen; with nothing new, the home's newest files.
struct SinceYouLeft: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SinceYouLeft.leftKey) private var left: Double = 0
    static let leftKey = "caboose.home.leftAt"

    var body: some View {
        let since = left > 0 ? Date(timeIntervalSince1970: left) : nil
        let arrivals = since.map { HomeToday.arrivals(tasks: tasks, files: model.recentFiles, since: $0, limit: 5) } ?? []
        if !arrivals.isEmpty, let since {
            VStack(alignment: .leading, spacing: 12) {
                TodaySectionHeader(title: "Since You Left", detail: since.formatted(date: since > Calendar.current.startOfDay(for: .now) ? .omitted : .abbreviated, time: .shortened))
                rows(arrivals.map { arrival in
                    Row(id: arrival.id, title: arrival.title, detail: arrival.detail, date: arrival.date,
                        symbol: symbol(for: arrival), color: color(for: arrival)) { open(arrival) }
                })
            }
        } else {
            let files = RecentFiles.visible(model.recentFiles, limit: 5)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    TodaySectionHeader(title: "Recent Files")
                    rows(files.map { file in
                        let name = (file.path as NSString).lastPathComponent
                        let folder = (file.path as NSString).deletingLastPathComponent
                        return Row(id: file.path, title: name, detail: folder.isEmpty ? "Home" : folder,
                                   date: Date(timeIntervalSince1970: file.mtime / 1000), symbol: FileSymbol.name(for: name),
                                   color: Brand.amber) { Task { await model.openFile(file.path) } }
                    })
                }
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let date: Date
        let symbol: String
        let color: Color
        let action: () -> Void
    }

    private func rows(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 54) }
                Button(action: row.action) {
                    TodayRow(title: row.title, detail: row.detail, date: row.date) {
                        Image(systemName: row.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(row.color)
                            .frame(width: 30, height: 30)
                            .background(row.color.opacity(0.16), in: .rect(cornerRadius: 9, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var tasks: [HomeToday.AgentTask] {
        model.agents.tasks.map { task in
            HomeToday.AgentTask(id: task.id, title: model.agents.title(of: task), agent: model.agents.name(of: task),
                                status: task.status, finishedAt: Self.date(task.finishedAt), summary: task.summary)
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date(value, strategy: .iso8601)) ?? (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    private func symbol(for arrival: HomeToday.Arrival) -> String {
        switch arrival.kind {
        case .agentSucceeded: "checkmark"
        case .agentFailed: "exclamationmark.triangle.fill"
        case .file: FileSymbol.name(for: arrival.title)
        }
    }

    private func color(for arrival: HomeToday.Arrival) -> Color {
        switch arrival.kind {
        case .agentSucceeded: .green
        case .agentFailed: .orange
        case .file: Brand.amber
        }
    }

    private func open(_ arrival: HomeToday.Arrival) {
        switch arrival.kind {
        case .agentSucceeded, .agentFailed:
            model.agents.focusedTask = arrival.id
            model.selectedTab = .agents
        case .file:
            Task { await model.openFile(arrival.id) }
        }
    }
}

// MARK: Apps

/// The apps the owner pinned, one tap each. Hidden until there are some.
struct PinnedApps: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.pinnedApps
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                TodaySectionHeader(title: "Pinned", link: "All Apps") { model.selectedTab = .apps }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(apps) { app in
                            AppButton(app: app).frame(width: 76)
                        }
                    }
                }
                .homeColumnRow(cornerRadius: AppTile.cornerRadius, top: 8, bottom: 8)
            }
        }
    }
}

/// Launch history stored on this phone, excluding apps already pinned above.
private struct RecentHomeApps: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pinned = Set(model.pinnedApps.map(\.id))
        let apps = model.recentApps(limit: 12).filter { !pinned.contains($0.id) }
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                TodaySectionHeader(title: "Recent Apps", link: "All Apps") { model.selectedTab = .apps }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(apps) { app in
                        AppButton(app: app).frame(width: 76)
                    }
                }
            }
        }
    }
}

// MARK: Parts

/// A section's title, with a count, a detail such as a time, or a link to the tab that has
/// the rest.
struct TodaySectionHeader: View {
    let title: String
    var detail: String?
    var count: Int?
    var link: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.bold))
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Brand.amber, in: .capsule)
            }
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if let link, let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(link)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Brand.amber)
                .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row in one of Today's lists: an icon, a title over a detail, and when it happened.
private struct TodayRow<Icon: View>: View {
    let title: String
    let detail: String
    var date: Date?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            icon().frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .truncationMode(.middle)
            if let date {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// An SF Symbol for a file, by its type.
enum FileSymbol {
    static func name(for file: String) -> String {
        guard let type = UTType(filenameExtension: (file as NSString).pathExtension) else { return "doc" }
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

extension View {
    /// A sideways row on Home scrolls inside the content column, clipped to it like every card,
    /// so it never runs past the screen's edge or under a bar. The clip's corners match the
    /// cards' as they slide out of view; it reaches `top` and `bottom` beyond the row for what
    /// the cards draw outside their frames, such as a tile's shadow or a pressed icon's glass,
    /// and takes no more room in the column than the row itself.
    func homeColumnRow(cornerRadius: CGFloat, top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        modifier(HomeColumnRow(cornerRadius: cornerRadius, top: top, bottom: bottom))
    }
}

private struct HomeColumnRow: ViewModifier {
    @Environment(\.homeColumnWidth) private var width
    let cornerRadius: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .contentMargins(.top, top, for: .scrollContent)
            .contentMargins(.bottom, bottom, for: .scrollContent)
            .padding(.top, -top)
            .padding(.bottom, -bottom)
            .frame(width: width)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct HomeColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var homeColumnWidth: CGFloat? {
        get { self[HomeColumnWidthKey.self] }
        set { self[HomeColumnWidthKey.self] = newValue }
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
    static let cornerRadius: CGFloat = 18
    let app: HostClient.App
    let icon: UIImage?
    let launching: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.08))
                if let icon {
                    Image(uiImage: icon).resizable().scaledToFit().padding(10)
                } else {
                    Image(systemName: "app.dashed").font(.title)
                }
                if launching {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(.black.opacity(0.45))
                    CabooseWheel(motion: .rolling).frame(width: 26, height: 26)
                }
            }
            .frame(width: 68, height: 68)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.cornerRadius))
            Text(app.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
    }
}
