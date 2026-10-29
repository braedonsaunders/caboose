import CabooseKit
import SwiftUI

private func symbol(_ category: String) -> String {
    switch category {
    case "Create": "paintpalette"
    case "Video & Audio": "waveform"
    case "Make": "cube.transparent"
    case "Productivity": "doc.text"
    case "Development": "chevron.left.forwardslash.chevron.right"
    case "Games": "gamecontroller"
    case "Internet": "globe"
    case "Learn": "graduationcap"
    case "Science": "atom"
    case "System": "gearshape.2"
    case "Utilities": "wrench.and.screwdriver"
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

/// Every app the computer can add. Its front page is shelves of icons: Popular, then each
/// category, Caboose's own apps among them. A search lists every match; See All lists a
/// shelf's whole category. Each app installs on its own.
struct CatalogLibrary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var remove: CatalogApp?
    @State private var search = ""

    private var query: LibraryQuery { LibraryQuery(text: search) }

    var body: some View {
        let catalog = model.catalog
        NavigationStack {
            Group {
                if query.text.isEmpty { storefront } else { LibraryList(query: query, close: { dismiss() }, remove: { remove = $0 }) }
            }
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { category in
                LibraryList(query: LibraryQuery(category: category), close: { dismiss() }, remove: { remove = $0 })
                    .navigationTitle(category.isEmpty ? "All Apps" : category)
            }
            .searchable(text: $search, prompt: "Search apps")
            .task {
                catalog.prepare(model.host)
                if catalog.storefront.isEmpty { await catalog.loadStorefront() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .confirmationDialog("Remove \(remove?.name ?? "app")?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let app = remove { Task { await catalog.perform(app.id, action: "remove") } }; remove = nil }
        } message: { Text("The app will be removed from this computer.") }
        // The sheet covers the tabs, whose alert cannot show over it.
        .alert("Library", isPresented: Binding(get: { catalog.error != nil }, set: { if !$0 { catalog.error = nil } })) {
            Button("OK", role: .cancel) { catalog.error = nil }
        } message: { Text(catalog.error ?? "") }
    }

    private var storefront: some View {
        let catalog = model.catalog
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                let updates = catalog.apps.filter(\.updateAvailable)
                if !updates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updates").font(.title3.weight(.semibold)).padding(.horizontal, 20)
                        Text("Apps update on their own. Update Now gets a new version right away.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                        ForEach(updates) { app in LibraryRow(app: app, close: { dismiss() }, remove: { remove = $0 }).padding(.horizontal, 20).padding(.vertical, 6) }
                    }
                }
                ForEach(catalog.storefront) { group in
                    StorefrontShelf(group: group, close: { dismiss() })
                }
                if let error = catalog.storefrontError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await catalog.loadStorefront() } }
                    }.padding(.horizontal, 20)
                } else if catalog.storefront.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let notice = catalog.libraryNotice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20) }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await catalog.refresh(); await catalog.loadStorefront() }
    }
}

/// One shelf of the front page: its title, See All, and a row of app tiles.
private struct StorefrontShelf: View {
    let group: StorefrontGroup
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(.title3.weight(.semibold))
                Spacer()
                NavigationLink("See All", value: group.category)
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(group.apps) { StoreTile(app: $0, close: close) }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// An app on a shelf: its icon, name and what it is, and Get, its progress, or Open.
private struct StoreTile: View {
    @Environment(AppModel.self) private var model
    let app: CatalogApp
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.quaternary)
                if let image = model.appIcons[app.desktopId] ?? app.icon { Image(uiImage: image).resizable().scaledToFit().padding(8) }
                else { Image(systemName: symbol(app.category)).font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: 88, height: 88)
            Text(app.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(app.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            action.padding(.top, 2)
        }
        .frame(width: 112, alignment: .leading)
    }

    @ViewBuilder private var action: some View {
        if app.busy {
            if let value = app.progress?.downloadFraction { ProgressView(value: value).frame(width: 64) } else { ProgressView().controlSize(.small) }
        } else if app.needsRecovery {
            Button("Retry") { Task { await model.catalog.perform(app.id, action: app.progress?.operation ?? "install") } }.buttonStyle(.bordered).controlSize(.small)
        } else if let installed = app.installedVersion.flatMap({ _ in model.apps.first(where: { $0.id == app.desktopId }) }) {
            Button("Open") { close(); model.open(installed) }.buttonStyle(.bordered).controlSize(.small)
        } else if app.installedVersion != nil {
            Text("Installed").font(.caption).foregroundStyle(.secondary)
        } else if let reason = app.unavailable {
            // Says why when tapped: the reason is the computer's, not the app's.
            Button("Unavailable") { model.catalog.error = reason }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        } else {
            Button("Get") { Task { await model.catalog.perform(app.id, action: "install") } }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

/// A search's matches, or a whole category, as rows, a page at a time.
private struct LibraryList: View {
    @Environment(AppModel.self) private var model
    let query: LibraryQuery
    let close: () -> Void
    let remove: (CatalogApp) -> Void

    var body: some View {
        let catalog = model.catalog
        List {
            Section {
                ForEach(catalog.library) { app in
                    LibraryRow(app: app, close: close, remove: remove)
                        .onAppear { if app.id == catalog.library.last?.id { Task { await catalog.loadMore() } } }
                }
                if let error = catalog.libraryError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await catalog.retryLibrary() } }
                    }
                } else if catalog.libraryLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if catalog.libraryLoaded && catalog.library.isEmpty {
                    Text("No apps found.").foregroundStyle(.secondary)
                }
            } footer: {
                if let notice = catalog.libraryNotice { Text(notice) }
            }
        }
        .task(id: query) {
            if !query.text.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await catalog.discover(query)
        }
        .refreshable { await catalog.refresh(); await catalog.discover(query) }
    }
}

/// An app in the Library, curated or from Flathub alike: who makes it, its license, and Get,
/// progress, Retry, or Open, Update Now and Remove.
private struct LibraryRow: View {
    @Environment(AppModel.self) private var model
    let app: CatalogApp
    let close: () -> Void
    let remove: (CatalogApp) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image = model.appIcons[app.desktopId] ?? app.icon { Image(uiImage: image).resizable().scaledToFit().padding(4) }
                else { Image(systemName: symbol(app.category)).foregroundStyle(.secondary) }
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.medium))
                Text(app.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                credits
                if app.busy, let progress = app.progress {
                    Text(progress.label).font(.caption2).foregroundStyle(.secondary)
                    if let detail = progress.downloadDetail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
                else if let error = app.progress?.message ?? app.lastError, app.needsRecovery, !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                else if app.interrupted && !app.busy { Text("Installation interrupted; try again.").font(.caption2).foregroundStyle(.orange) }
                else if let reason = app.unavailable, app.installedVersion == nil { Text(reason).font(.caption2).foregroundStyle(.secondary) }
                else if let size = app.size, app.installedVersion == nil { Text(size).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if app.busy { ProgressView() }
            else if app.needsRecovery {
                Button("Retry") { Task { await model.catalog.perform(app.id, action: app.progress?.operation ?? "install") } }.buttonStyle(.bordered)
            }
            else if app.installedVersion == nil {
                Button("Get") { Task { await model.catalog.perform(app.id, action: "install") } }.buttonStyle(.bordered).disabled(app.unavailable != nil)
            } else {
                Menu {
                    if let installed = model.apps.first(where: { $0.id == app.desktopId }) {
                        Button("Open", systemImage: "arrow.up.right") { close(); model.open(installed) }
                    }
                    if app.updateAvailable { Button("Update Now", systemImage: "arrow.down.circle") { Task { await model.catalog.perform(app.id, action: "update") } } }
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(app) }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
        }
    }

    /// The publisher, with Flathub's verified seal, and the license.
    @ViewBuilder private var credits: some View {
        let developer = app.developer.flatMap { $0.isEmpty ? nil : $0 }
        let license = app.license.flatMap { $0.isEmpty ? nil : $0 }
        if developer != nil || license != nil {
            HStack(spacing: 4) {
                if let developer {
                    Text(developer).lineLimit(1)
                    if app.verified == true {
                        Image(systemName: "checkmark.seal.fill").imageScale(.small).foregroundStyle(.tint).accessibilityLabel("Verified")
                    }
                }
                if let license { Text(developer == nil ? license : "· \(license)").lineLimit(1) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
