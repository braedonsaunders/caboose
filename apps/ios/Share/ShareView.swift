import SwiftUI
import UniformTypeIdentifiers

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var promptFocused: Bool
    @State private var selected: ShareModel.CatalogEntry?
    @State private var warnCopy = false

    var body: some View {
        NavigationStack {
            Group {
                if model.credentials == nil {
                    ContentUnavailableView("Not Connected", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                           description: Text("Open Caboose and connect to your computer first."))
                } else if model.phase == .loading {
                    ProgressView()
                } else if model.items.isEmpty, case .failed(let message) = model.phase {
                    ContentUnavailableView("Could Not Open", systemImage: "exclamationmark.triangle", description: Text(message))
                } else if model.items.isEmpty {
                    ContentUnavailableView("Nothing to Send", systemImage: "tray",
                                           description: Text("Caboose can take pages, text, photos and files."))
                } else {
                    form
                }
            }
            .navigationTitle("Caboose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
            }
        }
        .sheet(isPresented: $model.selectingApp) {
            NavigationStack {
                List {
                    Section("Apps for these documents") {
                        ForEach(model.compatibleApps) { app in appRow(app) }
                        if model.compatibleApps.isEmpty { Text("No catalog app lists all these document types.").foregroundStyle(.secondary) }
                    }
                    Section("Other installed apps") {
                        ForEach(model.catalog.filter { app in app.installedVersion != nil && !model.compatibleApps.contains(where: { $0.id == app.id }) }) { app in appRow(app) }
                    }
                }.navigationTitle("Open on Computer")
                    .toolbar { Button("Cancel") { model.selectingApp = false } }
            }
        }
        .alert("Open a copy?", isPresented: $warnCopy) {
            Button("Open Copy") { if let selected { model.openOnComputer(selected) } }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: { Text("The sharing app provided a temporary copy. Changes on your computer cannot be written back to the original.") }
    }

    private func appRow(_ app: ShareModel.CatalogEntry) -> some View {
        Button {
            selected = app
            model.selectingApp = false
            if model.canWriteBack { model.openOnComputer(app) } else { warnCopy = true }
        } label: {
            HStack { Text(app.name); Spacer(); Text(app.installedVersion == nil ? "Get" : "Open").foregroundStyle(.secondary) }
        }
    }

    private var busy: Bool {
        if case .sending = model.phase { true } else { false }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(model.items) { item in row(item) }
            }

            Section {
                if !model.pages.isEmpty {
                    Button("Open on Computer", systemImage: "safari", action: model.openPage)
                }
                if !model.files.isEmpty || !model.texts.isEmpty {
                    Button("Save to Downloads", systemImage: "square.and.arrow.down") { model.save(open: false) }
                    Button("Save and Open", systemImage: "arrow.up.forward.app") { model.save(open: true) }
                    if !model.files.isEmpty { Button("Open on Computer…", systemImage: "desktopcomputer") { model.selectingApp = true; Task { await model.refreshCatalog(wake: true) } } }
                }
            }
            .disabled(busy)

            Section {
                TextField("Ask an agent to do something with this…", text: $model.prompt, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .focused($promptFocused)
                Picker("Agent", selection: $model.agent) {
                    Text("Default Agent").tag("")
                    ForEach(model.agents) { Text($0.name).tag($0.id) }
                }
                Button("Ask Agent", systemImage: "sparkle", action: model.askAgent)
                    .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Agent")
            } footer: {
                if model.files.count > ShareModel.maxAttachments {
                    Text("An agent takes the first \(ShareModel.maxAttachments) files.")
                }
            }
            .disabled(busy)

            switch model.phase {
            case .sending(let message):
                Section {
                    Label { Text(message) } icon: { ProgressView() }
                    if let id = model.installing, let value = model.catalog.first(where: { $0.id == id })?.progress?.value { ProgressView(value: value) }
                }
            case .done(let message):
                Section { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            case .failed(let message):
                Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func row(_ item: SharedItem) -> some View {
        switch item {
        case .page(let url):
            Label {
                VStack(alignment: .leading) {
                    Text(url.host() ?? url.absoluteString).font(.subheadline.weight(.semibold))
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: { Image(systemName: "globe") }
        case .text(let text):
            Label { Text(text).lineLimit(3).font(.subheadline) } icon: { Image(systemName: "text.alignleft") }
        case .file(let name, let type, let url, _, _):
            Label {
                VStack(alignment: .leading) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: type.conforms(to: .image) ? "photo" : type.conforms(to: .movie) ? "film" : "doc")
            }
        }
    }
}
