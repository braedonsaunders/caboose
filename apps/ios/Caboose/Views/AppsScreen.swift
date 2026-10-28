import CabooseKit
import SwiftUI

/// Every app on the computer, and the catalog's apps to add: the Shelf, and Library for packs,
/// updates and removal.
struct AppsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showSystem = false
    @State private var showLibrary = false
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 18)]

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .ready {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            installed
                            if search.isEmpty { shelf }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await model.refreshApps(); await model.catalog.refresh() }
                    .searchable(text: $search, prompt: "Search apps")
                } else {
                    ComputerStateView()
                }
            }
            .background { ShellBackground() }
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Library", systemImage: "books.vertical") { showLibrary = true }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ComputerToolbar()
            }
            .sheet(isPresented: $showLibrary) { CatalogLibrary().environment(model) }
        }
    }

    private func matching(_ apps: [HostClient.App]) -> [HostClient.App] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private var installed: some View {
        if model.apps.isEmpty {
            HStack(spacing: 12) {
                CabooseWheel(motion: .rolling).frame(width: 22, height: 22)
                Text("Finding your apps…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        } else {
            let (main, system) = model.partitionedApps
            let shownMain = matching(main), shownSystem = matching(system)
            if shownMain.isEmpty && shownSystem.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(shownMain) { AppButton(app: $0) }
            }
            if !shownSystem.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { showSystem || !search.isEmpty }, set: { showSystem = $0 })) {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(shownSystem) { AppButton(app: $0) }
                    }
                    .padding(.top, 14)
                } label: {
                    Label("System Settings & Tools", systemImage: "gearshape.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
    }

    /// Optional apps from the computer's catalog: just installed first, then the ones to get.
    @ViewBuilder private var shelf: some View {
        let recent = model.catalog.apps.filter { model.catalog.recentInstalls.contains($0.id) }
        let available = recent + model.catalog.apps.filter { $0.installedVersion == nil && !model.catalog.recentInstalls.contains($0.id) }
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Shelf") { showLibrary = true }
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(available) { app in
                        ShelfTile(app: app) {
                            if app.installedVersion != nil, let installed = model.apps.first(where: { $0.id == app.desktopId }) { model.open(installed) }
                            else if app.installedVersion == nil { Task { await model.catalog.perform(app.id, action: "install") } }
                        }
                    }
                }
            }
        }
    }
}
