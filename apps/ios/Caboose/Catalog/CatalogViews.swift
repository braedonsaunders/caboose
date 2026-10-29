import SwiftUI

private func symbol(_ category: String) -> String {
    switch category {
    case "Create": "paintpalette"
    case "Video & Audio": "waveform"
    case "Make": "cube.transparent"
    case "Office": "doc.text"
    case "Admin": "network"
    default: "square.grid.2x2"
    }
}

struct ShelfTile: View {
    let app: CatalogApp
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08))
                    if let icon = app.icon { Image(uiImage: icon).resizable().scaledToFit().padding(8).opacity(app.installedVersion == nil ? 0.58 : 1) }
                    else { Image(systemName: symbol(app.category)).font(.title).foregroundStyle(.secondary) }
                    if app.busy {
                        RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.45))
                        if let value = app.progress?.downloadFraction {
                            Circle().stroke(.white.opacity(0.25), lineWidth: 4).frame(width: 32, height: 32)
                            Circle().trim(from: 0, to: value).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 32, height: 32)
                        } else { ProgressView().tint(.white) }
                    }
                }
                .frame(width: 68, height: 68)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                Text(app.name).font(.caption).lineLimit(1)
                Text(app.busy ? (app.progress?.label ?? "Preparing") : app.needsRecovery ? "Needs attention" : app.installedVersion != nil ? "Open" : (app.size.map { "Get · \($0)" } ?? "Get")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }.buttonStyle(.plain).disabled(app.busy)
    }
}

struct CatalogLibrary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var remove: CatalogApp?
    @State private var search = ""
    @State private var category = "All"

    var body: some View {
        NavigationStack {
            List {
                let updates = model.catalog.apps.filter(\.updateAvailable)
                if !updates.isEmpty {
                    Section("Updates Available") { ForEach(updates) { row($0) } }
                }
                Section("Debian applications") {
                    if model.catalog.storeLoading { ProgressView() }
                    if let error = model.catalog.storeError { Text(error).foregroundStyle(.secondary) }
                    let categories = Set(model.catalog.storeApps.flatMap { $0.categories ?? [] }).sorted()
                    if !categories.isEmpty {
                        Picker("Category", selection: $category) {
                            Text("All").tag("All")
                            ForEach(categories, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    ForEach(model.catalog.storeApps.filter { category == "All" || ($0.categories ?? []).contains(category) }) { row($0) }
                    if !model.catalog.storeLoading && model.catalog.storeApps.isEmpty && model.catalog.storeError == nil { Text("No applications found.").foregroundStyle(.secondary) }
                }
                Section { Text("Curated collections").font(.headline) }
                ForEach(model.catalog.packs) { pack in
                    let entries = model.catalog.apps.filter { $0.packs.contains(pack.id) }
                    Section {
                        ForEach(entries) { row($0) }
                    } header: {
                        HStack {
                            Text(pack.name)
                            Spacer()
                            if entries.contains(where: { $0.installedVersion == nil }) {
                                Button("Get Pack") { Task { await model.catalog.perform(pack.id, action: "install", pack: true) } }
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search Debian applications")
            .task(id: search) {
                category = "All"
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await model.catalog.discover(search)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await model.catalog.refresh() }
            .confirmationDialog("Remove \(remove?.name ?? "app")?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let app = remove { Task { await model.catalog.perform(app.id, action: "remove") } }; remove = nil }
            } message: { Text("The app will be removed from this computer.") }
        }
    }

    private func row(_ app: CatalogApp) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image = model.appIcons[app.desktopId] ?? app.icon { Image(uiImage: image).resizable().scaledToFit().padding(4) }
                else { Image(systemName: symbol(app.category)).foregroundStyle(.secondary) }
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.medium))
                Text(app.summary).font(.caption).foregroundStyle(.secondary)
                if let license = app.license, !license.isEmpty { Text(license).font(.caption2).foregroundStyle(.secondary) }
                if app.busy, let progress = app.progress {
                    Text(progress.label).font(.caption2).foregroundStyle(.secondary)
                    if let detail = progress.downloadDetail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
                else if let error = app.progress?.message ?? app.lastError, app.needsRecovery, !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                else if app.interrupted && !app.busy { Text("Installation interrupted; try again.").font(.caption2).foregroundStyle(.orange) }
                else if let size = app.size, app.installedVersion == nil { Text(size).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if app.busy { ProgressView() }
            else if app.needsRecovery {
                Button("Retry") { Task { await model.catalog.perform(app.id, action: app.progress?.operation ?? "install") } }.buttonStyle(.bordered)
            }
            else if app.installedVersion == nil {
                Button("Get") { Task { await model.catalog.perform(app.id, action: "install") } }.buttonStyle(.bordered)
            } else {
                Menu {
                    if let installed = model.apps.first(where: { $0.id == app.desktopId }) {
                        Button("Open", systemImage: "arrow.up.right") { dismiss(); model.open(installed) }
                    }
                    if app.updateAvailable { Button("Update", systemImage: "arrow.down.circle") { Task { await model.catalog.perform(app.id, action: "update") } } }
                    if app.canRollback { Button("Roll Back", systemImage: "arrow.uturn.backward") { Task { await model.catalog.perform(app.id, action: "rollback") } } }
                    Button("Remove", systemImage: "trash", role: .destructive) { remove = app }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
        }
    }
}
