import CabooseKit
import SwiftUI
import UIKit

/// A service's page in the Task Manager.
struct ServiceLink: Hashable { let name: String }
/// A service's log.
struct ServiceLogLink: Hashable { let name: String }

/// The computer's services in the Task Manager: each with its state, ports and live use,
/// Start, Stop and Restart, and New Service to define one of the owner's own.
struct ServicesSection: View {
    let listing: RunningAppsListing
    let sort: TaskManager.Sort
    @Binding var creating: Bool

    var body: some View {
        let services = TaskManager.services(in: listing, sortedBy: sort)
        Section {
            ForEach(services) { service in
                NavigationLink(value: ServiceLink(name: service.name)) {
                    ServiceRow(service: service, measured: listing.measured)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    ServiceActions(service: service, style: .swipe)
                }
                .contextMenu {
                    ServiceActions(service: service, style: .menu)
                }
            }
            Button("New Service…", systemImage: "plus") { creating = true }
        } header: {
            Text("Services")
        } footer: {
            if services.isEmpty { Text("Programs that run without a window, such as a web server, started on request or with the computer.") }
        }
    }
}

private struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: RunningService
    let measured: Bool

    var body: some View {
        HStack(spacing: 12) {
            ServiceStatusDot(state: service.state)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(service.name).font(.body.weight(.medium)).lineLimit(1)
                    if service.source == .system { tag("System") }
                    if service.autostart { tag("Starts with Computer") }
                }
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if service.showsError, let error = service.error {
                    Text(error).font(.caption).foregroundStyle(service.state == .failed ? .red : .orange).lineLimit(2)
                }
                PortChips(ports: service.ports)
            }
            Spacer(minLength: 0)
            if model.runningApps.busy.contains(service.id) { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [ServiceStatusDot.title(service.state)]
        if service.isRunning {
            if measured { parts.append("CPU \(TaskManager.percent(service.cpuPercent))") }
            parts.append(TaskManager.bytes(service.memoryBytes))
            if measured {
                parts.append("Disk \(TaskManager.rate(service.io.readBytesPerSecond + service.io.writeBytesPerSecond))")
                if let gpu = service.gpu { parts.append("GPU \(TaskManager.rate(gpu.toPhoneBytesPerSecond + gpu.fromPhoneBytesPerSecond))") }
            }
        } else if !service.description.isEmpty {
            parts.append(service.description)
        }
        return parts.joined(separator: " · ")
    }

    private func tag(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: .capsule)
    }
}

/// Green running, amber changing, red failed, grey stopped.
struct ServiceStatusDot: View {
    let state: RunningService.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay { if state == .activating || state == .deactivating { Circle().stroke(color.opacity(0.4), lineWidth: 4) } }
            .accessibilityLabel(Self.title(state))
    }

    private var color: Color {
        switch state {
        case .active: .green
        case .activating, .deactivating: Brand.amber
        case .failed: .red
        case .inactive, .other: .gray
        }
    }

    static func title(_ state: RunningService.State) -> String {
        switch state {
        case .active: "Running"
        case .activating: "Starting"
        case .deactivating: "Stopping"
        case .failed: "Failed"
        case .inactive: "Stopped"
        case .other: "Unknown"
        }
    }
}

/// Listening sockets as small chips: `TCP 8080`.
struct PortChips: View {
    let ports: [RunningApp.Port]

    var body: some View {
        let labels = TaskManager.portLabels(ports)
        if !labels.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.amber.opacity(0.18), in: .capsule)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Listening on \(labels.joined(separator: ", "))")
        }
    }
}

/// Start, Stop, Restart, Start with Computer, View Log and Delete, as they apply.
private struct ServiceActions: View {
    enum Style { case swipe, menu }

    @Environment(AppModel.self) private var model
    let service: RunningService
    let style: Style

    var body: some View {
        let center = model.runningApps
        let busy = center.busy.contains(service.id)
        if style == .swipe {
            if service.canStop {
                Button("Stop", systemImage: "stop.fill") { act(.stop) }.tint(.red)
            } else if service.canStart {
                Button("Start", systemImage: "play.fill") { act(.start) }.tint(.green)
            }
            if service.canRestart {
                Button("Restart", systemImage: "arrow.clockwise") { act(.restart) }.tint(.orange)
            }
        } else {
            if service.canStart { Button("Start", systemImage: "play.fill") { act(.start) }.disabled(busy) }
            if service.canStop { Button("Stop", systemImage: "stop.fill") { act(.stop) }.disabled(busy) }
            if service.canRestart { Button("Restart", systemImage: "arrow.clockwise") { act(.restart) }.disabled(busy) }
            Toggle("Start with Computer", systemImage: "power", isOn: Binding(
                get: { service.autostart }, set: { act($0 ? .enable : .disable) }))
                .disabled(busy)
            NavigationLink(value: ServiceLogLink(name: service.name)) { Label("View Log", systemImage: "doc.plaintext") }
            if service.canDelete {
                Button("Delete…", systemImage: "trash", role: .destructive) {
                    center.confirmation = .init(kind: .deleteService, name: service.name, ids: [service.name])
                }
                .disabled(busy)
            }
        }
    }

    private func act(_ action: ServicesRoute.Action) {
        Task { await model.runningApps.service(action, service, model: model) }
    }
}

/// One service: its state, why it failed, its controls, use, ports and processes.
struct ServiceDetail: View {
    @Environment(AppModel.self) private var model
    let name: String
    let sort: TaskManager.Sort

    var body: some View {
        let listing = model.runningApps.listing
        if let listing, let service = listing.services.first(where: { $0.name == name }) {
            detail(service, measured: listing.measured)
        } else {
            ContentUnavailableView("Removed", systemImage: "trash",
                                   description: Text("This service is no longer defined."))
        }
    }

    private func detail(_ service: RunningService, measured: Bool) -> some View {
        let center = model.runningApps
        let busy = center.busy.contains(service.id)
        return List {
            Section {
                HStack(spacing: 12) {
                    ServiceStatusDot(state: service.state)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ServiceStatusDot.title(service.state)).font(.headline)
                        if service.since > 0 {
                            Text("Since \(Date(timeIntervalSince1970: service.since / 1000).formatted(.relative(presentation: .named)))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if busy { ProgressView() }
                }
                if let error = service.error, !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(service.state == .failed ? .red : .orange).textSelection(.enabled)
                }
            } header: {
                Text(service.description.isEmpty ? (service.source == .system ? "System Service" : "Your Service") : service.description)
            }
            Section {
                if service.canStart { Button("Start", systemImage: "play.fill") { act(.start, service) }.disabled(busy) }
                if service.canStop { Button("Stop", systemImage: "stop.fill") { act(.stop, service) }.disabled(busy) }
                if service.canRestart { Button("Restart", systemImage: "arrow.clockwise") { act(.restart, service) }.disabled(busy) }
                Toggle("Start with Computer", isOn: Binding(
                    get: { service.autostart }, set: { act($0 ? .enable : .disable, service) }))
                    .disabled(busy)
                NavigationLink(value: ServiceLogLink(name: service.name)) { Label("View Log", systemImage: "doc.plaintext") }
            }
            Section("About") {
                LabeledContent("Source", value: service.source == .system ? "System" : "Yours")
                LabeledContent("Restarts", value: restartPolicy(service.restart))
                if service.restarts > 0 { LabeledContent("Automatic Restarts", value: "\(service.restarts)") }
                if !service.requires.isEmpty { LabeledContent("Requires", value: service.requires.joined(separator: ", ")) }
                if let exit = service.lastExit { LabeledContent("Last Exit", value: exitText(exit)) }
            }
            if service.isRunning {
                Section("Usage") {
                    if measured { LabeledContent("CPU", value: TaskManager.percent(service.cpuPercent)) }
                    LabeledContent("Memory", value: TaskManager.bytes(service.memoryBytes))
                    if measured {
                        LabeledContent("Disk Read", value: TaskManager.rate(service.io.readBytesPerSecond))
                        LabeledContent("Disk Write", value: TaskManager.rate(service.io.writeBytesPerSecond))
                    }
                    if let gpu = service.gpu {
                        LabeledContent("GPU Streams", value: "\(gpu.streams)")
                        if measured {
                            LabeledContent("GPU to Phone", value: TaskManager.rate(gpu.toPhoneBytesPerSecond))
                            LabeledContent("GPU from Phone", value: TaskManager.rate(gpu.fromPhoneBytesPerSecond))
                        }
                    }
                }
                .monospacedDigit()
            }
            if !service.ports.isEmpty {
                Section("Listening") {
                    ForEach(TaskManager.portLabels(service.ports), id: \.self) { Text($0).monospacedDigit() }
                }
            }
            if !service.processes.isEmpty {
                ProcessesSection(processes: service.processes, count: service.processCount, sort: sort)
            }
            if service.canDelete {
                Section {
                    Button("Delete Service…", systemImage: "trash", role: .destructive) {
                        center.confirmation = .init(kind: .deleteService, name: service.name, ids: [service.name])
                    }
                    .disabled(busy)
                }
            }
        }
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func act(_ action: ServicesRoute.Action, _ service: RunningService) {
        Task { await model.runningApps.service(action, service, model: model) }
    }

    private func restartPolicy(_ restart: RunningService.Restart) -> String {
        switch restart {
        case .no: "Never"
        case .onFailure: "On Failure"
        case .always: "Always"
        case .other: "Other"
        }
    }

    private func exitText(_ exit: RunningService.Exit) -> String {
        let how = exit.signal.map { "Signal \($0)" } ?? exit.code.map { "Code \($0)" } ?? "Unknown"
        guard exit.at > 0 else { return how }
        return "\(how), \(Date(timeIntervalSince1970: exit.at / 1000).formatted(.relative(presentation: .named)))"
    }
}

/// A service's log, the latest at the bottom, read every two seconds while it is shown.
struct ServiceLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let name: String
    @State private var lines: [String]?
    @State private var error: String?
    @State private var follow = true

    static let lineCount = 500

    var body: some View {
        Group {
            if let lines {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if lines.isEmpty {
                                Text("The log is empty.").foregroundStyle(.secondary)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .textSelection(.enabled)
                        .padding(12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: lines) { _, _ in
                        if follow { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            } else if let error {
                ContentUnavailableView("Couldn’t Read the Log", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error, lines != nil {
                Label("Not updating: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).padding(8).frame(maxWidth: .infinity).background(.bar)
            }
        }
        .navigationTitle("\(name) Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(follow ? "Stop Following" : "Follow", systemImage: follow ? "arrow.down.to.line.compact" : "pause") {
                    follow.toggle()
                }
                Button("Copy Log", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = (lines ?? []).joined(separator: "\n")
                }
                .disabled((lines ?? []).isEmpty)
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                guard let host = model.host else { return }
                do {
                    let fresh = try await host.serviceLog(name: name, lines: Self.lineCount)
                    if fresh != lines { lines = fresh }
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: RunningAppsCenter.pollInterval)
            }
        }
    }
}

/// Defines one of the owner's services: a command run as the owner, kept in their home.
struct NewServiceForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Variable: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    @State private var name = ""
    @State private var command = ""
    @State private var summary = ""
    @State private var directory = ""
    @State private var variables: [Variable] = []
    @State private var restart: RunningService.Restart = .onFailure
    @State private var autostart = true
    @State private var startNow = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description (optional)", text: $summary)
                } footer: {
                    Text("Letters, digits, “_”, “.”, “@” and “-”, up to 64.")
                }
                Section {
                    TextField("python3 -m http.server 8080", text: $command, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Working Directory (optional)", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Command")
                } footer: {
                    Text("Split into words as a shell would, with quotes and backslashes; nothing is expanded. It runs as you.")
                }
                Section("Environment") {
                    ForEach($variables) { $variable in
                        HStack {
                            TextField("NAME", text: $variable.name)
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Text("=").foregroundStyle(.secondary)
                            TextField("value", text: $variable.value)
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    .onDelete { variables.remove(atOffsets: $0) }
                    Button("Add Variable", systemImage: "plus") { variables.append(Variable()) }
                }
                Section {
                    Picker("Restart", selection: $restart) {
                        ForEach([RunningService.Restart.no, .onFailure, .always]) { Text($0.title).tag($0) }
                    }
                    Toggle("Start with Computer", isOn: $autostart)
                    Toggle("Start Now", isOn: $startNow)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Create") { Task { await create() } }
                            .disabled(name.isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let definition: ServiceDefinition
        do {
            definition = try ServiceDefinition.make(name: trimmed, commandLine: command, description: summary,
                                                    workingDirectory: directory,
                                                    environment: variables.map { ($0.name, $0.value) },
                                                    restart: restart, autostart: autostart)
        } catch {
            self.error = error.localizedDescription
            return
        }
        if model.runningApps.listing?.services.contains(where: { $0.name == trimmed }) == true {
            self.error = "A service named “\(trimmed)” already exists."
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await model.runningApps.createService(name: trimmed, definition, start: startNow, model: model)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
