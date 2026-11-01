import CabooseKit
import SwiftUI
import UIKit

/// The computer's running apps with their live CPU, memory, disk and GPU use, and Quit,
/// Force Quit and Kill All Processes for each (docs/architecture.md, Running apps). It reads
/// the listing every two seconds while it is on screen and the app is active.
struct TaskManagerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Busiest first, as Activity Monitor opens; a sort control changed little with a handful of apps.
    private let sort: TaskManager.Sort = .cpu
    @State private var creatingService = false

    var body: some View {
        let center = model.runningApps
        NavigationStack {
            Group {
                if !model.runningAppsAvailable {
                    ContentUnavailableView("Task Manager Unavailable", systemImage: "gauge.with.dots.needle.33percent",
                                           description: Text("This computer does not list its running apps."))
                } else if let listing = center.listing {
                    list(listing, error: center.listingError)
                } else if let error = center.listingError {
                    ContentUnavailableView {
                        Label("Couldn’t Read Running Apps", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { try? await center.refresh(model: model) } }.buttonStyle(.glass)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Task Manager")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in RunningAppDetail(id: id, sort: sort) }
            .navigationDestination(for: ServiceLink.self) { link in ServiceDetail(name: link.name, sort: sort) }
            .navigationDestination(for: ServiceLogLink.self) { link in ServiceLogView(name: link.name) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .task(id: scenePhase == .active && model.runningAppsAvailable) {
            guard scenePhase == .active, model.runningAppsAvailable else { return }
            await center.poll(model: model)
        }
        .modifier(RunningAppsPrompts(active: true))
    }

    private func list(_ listing: RunningAppsListing, error: String?) -> some View {
        let apps = TaskManager.apps(in: listing, sortedBy: sort)
        return List {
            Section {
                MachineSummary(listing: listing)
            } footer: {
                if let error { Label("Not updating: \(error)", systemImage: "exclamationmark.triangle").font(.footnote) }
            }
            Section("Apps") {
                if apps.isEmpty {
                    Text("No apps are running.").foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    NavigationLink(value: app.id) {
                        RunningAppRow(app: app, measured: listing.measured)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        RunningAppActions(app: app, style: .swipe)
                    }
                    .contextMenu {
                        RunningAppActions(app: app, style: .menu)
                    }
                }
            }
            if listing.listsServices {
                ServicesSection(listing: listing, sort: sort, creating: $creatingService)
            }
            if let session = TaskManager.session(in: listing) {
                Section {
                    NavigationLink(value: session.id) {
                        RunningAppRow(app: session, measured: listing.measured)
                    }
                } header: {
                    Text("System")
                } footer: {
                    Text("Caboose’s own processes, and any no app or service claims. They keep the computer working and cannot be ended.")
                }
            }
        }
        .animation(.default, value: apps.map(\.id))
        .sheet(isPresented: $creatingService) { NewServiceForm().environment(model) }
    }
}

/// The whole computer: everything listed against its CPUs and memory.
private struct MachineSummary: View {
    let listing: RunningAppsListing

    var body: some View {
        let totals = TaskManager.totals(listing)
        HStack(alignment: .top, spacing: 20) {
            meter("CPU", value: listing.measured ? TaskManager.percent(totals.cpuShare * 100) : "Measuring…",
                  share: listing.measured ? totals.cpuShare : 0,
                  detail: "of \(totals.cpus) \(totals.cpus == 1 ? "core" : "cores")")
            meter("Memory", value: TaskManager.bytes(totals.memoryBytes), share: totals.memoryShare,
                  detail: "of \(TaskManager.bytes(totals.machineMemoryBytes))")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func meter(_ title: String, value: String, share: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            ProgressView(value: share).tint(share > 0.85 ? .red : Brand.amber)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An app in the list: its icon, name, how it is present, and its live use.
private struct RunningAppRow: View {
    @Environment(AppModel.self) private var model
    let app: RunningApp
    let measured: Bool

    var body: some View {
        HStack(spacing: 12) {
            RunningAppIcon(app: app, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name.isEmpty ? app.id : app.name).font(.body.weight(.medium)).lineLimit(1)
                    PresenceBadge(app: app)
                }
                Text(usage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if !app.isSession { PortChips(ports: app.ports) }
            }
            Spacer(minLength: 0)
            if model.runningApps.busy.contains(app.id) { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }

    private var usage: String {
        var parts: [String] = []
        if measured { parts.append("CPU \(TaskManager.percent(app.cpuPercent))") }
        parts.append(TaskManager.bytes(app.memoryBytes))
        if measured {
            parts.append("Disk \(TaskManager.rate(app.io.readBytesPerSecond + app.io.writeBytesPerSecond))")
            if let gpu = app.gpu { parts.append("GPU \(TaskManager.rate(gpu.toPhoneBytesPerSecond + gpu.fromPhoneBytesPerSecond))") }
        }
        return parts.joined(separator: " · ")
    }
}

/// Background for an app with no windows, Terminal for a phone terminal session.
private struct PresenceBadge: View {
    let app: RunningApp

    var body: some View {
        switch app.isSession ? nil : app.presence {
        case .background: badge("Background")
        case .terminal: badge("Terminal")
        case .agent: badge("Agent")
        case .windows, nil: if app.gpuPlacement == .cpuUntilRelaunch { badge("On CPU") } else { EmptyView() }
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: .capsule)
    }
}

/// The app's icon from the computer's app list (by desktop entry, else by one of its
/// windows), or a symbol for what it is.
struct RunningAppIcon: View {
    @Environment(AppModel.self) private var model
    let app: RunningApp
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var image: UIImage? {
        if let id = app.desktopId, let entry = model.apps.first(where: { TaskManager.sameDesktopID($0.id, id) }),
           let icon = model.appIcons[entry.id] { return icon }
        return app.windows.lazy.compactMap { model.window($0) }.first.flatMap { model.icon(for: $0) }
    }

    private var symbol: String {
        if app.isSession { return "gearshape.2" }
        switch app.origin {
        case .game: return "gamecontroller"
        case .terminal: return "apple.terminal"
        case .agent: return "sparkles"
        default: return "app.dashed"
        }
    }
}

/// Quit, Force Quit and Kill All Processes, as swipe actions, a context menu or buttons.
private struct RunningAppActions: View {
    enum Style { case swipe, menu, buttons }

    @Environment(AppModel.self) private var model
    let app: RunningApp
    let style: Style

    var body: some View {
        let center = model.runningApps
        let busy = center.busy.contains(app.id)
        if app.canEnd {
            if style == .swipe {
                Button("Force Quit", systemImage: "xmark.octagon") { confirm(.forceQuit) }.tint(.red)
                if app.canQuit {
                    Button("Quit", systemImage: "xmark.circle") { Task { await center.quit(app, model: model) } }.tint(.orange)
                }
            } else {
                if app.canQuit {
                    Button("Quit", systemImage: "xmark.circle") { Task { await center.quit(app, model: model) } }
                        .disabled(busy)
                }
                if app.canRelaunchOnPhoneGPU {
                    Button("Relaunch on Phone GPU", systemImage: "arrow.clockwise.circle") {
                        Task { await center.relaunch(app, model: model) }
                    }
                    .disabled(busy)
                }
                Button("Force Quit…", systemImage: "xmark.octagon") { confirm(.forceQuit) }
                    .disabled(busy)
                Button("Kill All Processes…", systemImage: "bolt.horizontal.circle", role: .destructive) { confirm(.kill) }
                    .disabled(busy)
            }
        }
    }

    private func confirm(_ kind: RunningAppsCenter.Confirmation.Kind) {
        model.runningApps.confirmation = .init(kind: kind, name: app.name, ids: [app.id])
    }
}

/// One app: its use in full and its processes, busiest first.
private struct RunningAppDetail: View {
    @Environment(AppModel.self) private var model
    let id: String
    let sort: TaskManager.Sort

    var body: some View {
        let listing = model.runningApps.listing
        if let listing, let app = listing.apps.first(where: { $0.id == id }) {
            detail(app, measured: listing.measured)
        } else {
            ContentUnavailableView("Ended", systemImage: "checkmark.circle",
                                   description: Text("This app is no longer running."))
        }
    }

    private func detail(_ app: RunningApp, measured: Bool) -> some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RunningAppIcon(app: app, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name.isEmpty ? app.id : app.name).font(.title3.weight(.semibold))
                            PresenceBadge(app: app)
                        }
                        Text(subtitle(app)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if app.isSession {
                    Text("Caboose’s own processes, and any no app or service claims. They cannot be ended.")
                } else if app.isBackground {
                    Text("\(app.name) has no windows. It may be in the system tray; Force Quit ends it.")
                }
            }
            Section("Usage") {
                if measured {
                    LabeledContent("CPU", value: TaskManager.percent(app.cpuPercent))
                }
                LabeledContent("Memory", value: TaskManager.bytes(app.memoryBytes))
                if measured {
                    LabeledContent("Disk Read", value: TaskManager.rate(app.io.readBytesPerSecond))
                    LabeledContent("Disk Write", value: TaskManager.rate(app.io.writeBytesPerSecond))
                }
                if let gpu = app.gpu {
                    LabeledContent("GPU Streams", value: "\(gpu.streams)")
                    LabeledContent("GPU Surfaces", value: "\(gpu.surfaces)")
                    if measured {
                        LabeledContent("GPU to Phone", value: TaskManager.rate(gpu.toPhoneBytesPerSecond))
                        LabeledContent("GPU from Phone", value: TaskManager.rate(gpu.fromPhoneBytesPerSecond))
                    }
                }
                LabeledContent("Windows", value: "\(app.windows.count)")
            }
            .monospacedDigit()
            if !app.ports.isEmpty {
                Section("Listening") {
                    ForEach(TaskManager.portLabels(app.ports), id: \.self) { Text($0).monospacedDigit() }
                }
            }
            if app.canEnd {
                Section {
                    RunningAppActions(app: app, style: .buttons)
                }
            }
            ProcessesSection(processes: app.processes, count: app.processCount, sort: sort)
        }
        .navigationTitle(app.name.isEmpty ? app.id : app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func subtitle(_ app: RunningApp) -> String {
        var parts = ["\(app.processCount) \(app.processCount == 1 ? "process" : "processes")"]
        if app.startedAt > 0 {
            let started = Date(timeIntervalSince1970: app.startedAt / 1000)
            parts.append("started \(started.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

struct ProcessRow: View {
    let process: RunningApp.Process
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.name.isEmpty ? "PID \(process.pid)" : process.name).lineLimit(1)
                    Text("PID \(process.pid) · \(state)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(TaskManager.percent(process.cpuPercent))
                    Text(TaskManager.bytes(process.memoryBytes)).font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            if expanded {
                Text(process.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(process.command.isEmpty ? "" : "Shows its command.")
    }

    private var state: String {
        switch process.state {
        case .running: "Running"
        case .sleeping: "Sleeping"
        case .waiting: "Waiting"
        case .stopped: "Stopped"
        case .zombie: "Zombie"
        case .idle: "Idle"
        case .other: "Other"
        }
    }
}

/// A scope's processes, busiest first by default; tap one for its command, hold it to copy.
struct ProcessesSection: View {
    let processes: [RunningApp.Process]
    let count: Int
    let sort: TaskManager.Sort
    @State private var expanded: Set<Int> = []

    var body: some View {
        Section {
            ForEach(TaskManager.sorted(processes, by: sort)) { process in
                ProcessRow(process: process, expanded: expanded.contains(process.pid))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !process.command.isEmpty else { return }
                        withAnimation(.snappy) {
                            if expanded.contains(process.pid) { expanded.remove(process.pid) } else { expanded.insert(process.pid) }
                        }
                    }
                    .contextMenu {
                        if !process.command.isEmpty {
                            Section(process.command) {
                                Button("Copy Command", systemImage: "doc.on.doc") { UIPasteboard.general.string = process.command }
                            }
                        }
                        Button("Copy PID", systemImage: "number") { UIPasteboard.general.string = String(process.pid) }
                    }
            }
        } header: {
            Text("Processes")
        } footer: {
            if count > processes.count {
                Text("The busiest \(processes.count) of \(count) processes.")
            }
        }
    }
}

/// Asks before Force Quit and Kill, offers Force Quit for an app still running after Quit,
/// and shows what the host refused. Only one presenter is active at a time.
struct RunningAppsPrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    func body(content: Content) -> some View {
        let center = model.runningApps
        content
            .confirmationDialog(confirmationTitle, isPresented: Binding(
                get: { active && center.confirmation != nil },
                set: { if !$0 { center.confirmation = nil } }), titleVisibility: .visible, presenting: center.confirmation) { request in
                Button(Self.button(request.kind), role: .destructive) {
                    Task { await center.end(request.kind, ids: request.ids, name: request.name, model: model) }
                }
            } message: { request in
                switch request.kind {
                case .forceQuit:
                    Text("\(request.name) is asked to end, and killed if it has not ended after 5 seconds. Unsaved changes are lost.")
                case .kill:
                    Text("Every process of \(request.name) is killed at once. Unsaved changes are lost.")
                case .deleteService:
                    Text("\(request.name) is stopped and its definition removed. Its files are kept.")
                }
            }
            .alert(center.stillRunning.map { "\($0.name) Is Still Running" } ?? "", isPresented: Binding(
                get: { active && center.confirmation == nil && center.stillRunning != nil },
                set: { if !$0 { center.stillRunning = nil } }), presenting: center.stillRunning) { app in
                Button("Force Quit", role: .destructive) {
                    Task { await center.end(.forceQuit, ids: [app.id], name: app.name, model: model) }
                }
                Button("Wait", role: .cancel) {}
            } message: { app in
                Text("\(app.name) has not quit. Force Quit ends it; unsaved changes are lost.")
            }
            .alert(center.failure?.title ?? "", isPresented: Binding(
                get: { active && center.confirmation == nil && center.stillRunning == nil && center.failure != nil },
                set: { if !$0 { center.failure = nil } }), presenting: center.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    private var confirmationTitle: String {
        guard let request = model.runningApps.confirmation else { return "" }
        switch request.kind {
        case .forceQuit: return "Force Quit \(request.name)?"
        case .kill: return "Kill All Processes of \(request.name)?"
        case .deleteService: return "Delete the \(request.name) Service?"
        }
    }

    private static func button(_ kind: RunningAppsCenter.Confirmation.Kind) -> String {
        switch kind {
        case .forceQuit: "Force Quit"
        case .kill: "Kill All Processes"
        case .deleteService: "Delete Service"
        }
    }
}

/// The Task Manager sheet and its prompts, from the shell or from an app card over it.
struct TaskManagerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { active && model.taskManagerPresented },
                set: { if !$0 { model.taskManagerPresented = false } })) {
                TaskManagerScreen().environment(model)
            }
            .modifier(RunningAppsPrompts(active: active && !model.taskManagerPresented))
    }
}

/// Keeps the last listing current for the dock as windows come and go, so an app that
/// closes its last window but keeps running (to a tray) stays reachable. Draws nothing.
struct RunningAppsRefresher: View {
    @Environment(AppModel.self) private var model

    private struct Key: Equatable {
        var windows: Set<Int>
        var available: Bool
        var tab: ShellTab
    }

    var body: some View {
        let key = Key(windows: Set(model.appWindows.map(\.id)), available: model.runningAppsAvailable, tab: model.selectedTab)
        Color.clear
            .task(id: key) {
                guard key.available, !model.taskManagerPresented else { return }
                // A closed window's process may take a moment to exit or to reach its scope.
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                try? await model.runningApps.refresh(model: model)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
