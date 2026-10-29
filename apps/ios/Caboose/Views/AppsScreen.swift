import CabooseKit
import SwiftUI

/// Every app on the computer, with System Settings & Tools last. Library, in the toolbar, is
/// where apps are added, updated and removed.
struct AppsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.shellTabPlacement) private var placement
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
            .safeAreaInset(edge: .top) {
                if placement == .sidebar, model.phase == .ready {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        NativeTextInput("Search apps", text: $search, capitalization: .none)
                        if !search.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly)
                        }
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
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
            .toolbarVisibility(placement == .sidebar ? .hidden : .automatic, for: .navigationBar)
            .shellRailActions {
                Button("Library", systemImage: "books.vertical") { showLibrary = true }
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
}
