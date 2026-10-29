import CabooseKit
import SwiftUI

/// Save and Choose Folder for a Linux application: the computer's home, browsed natively.
/// The Caboose File Provider shows the same files in the Files app.
struct BridgeFileSheet: View {
    let request: BridgeRequest
    let host: HostClient
    let finish: (BridgeAnswer) -> Void

    @State private var stack: [ComputerPath] = []
    @State private var name = ""
    @State private var selection: TextSelection?
    @State private var filter: Int?
    @State private var listings: [ComputerPath: [HostClient.FolderItem]] = [:]
    @State private var replacing = false
    @State private var naming = false
    @State private var newFolder = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var saving: Bool { request.type == .save }
    private var folder: ComputerPath { stack.last ?? .home }
    private var title: String {
        if !request.title.isEmpty { return request.title }
        return saving ? "Save" : "Choose Folder"
    }
    private var acceptLabel: String {
        let label = request.acceptLabel.replacingOccurrences(of: "_", with: "")
        return label.isEmpty ? (saving ? "Save" : "Choose") : label
    }
    private var chosenName: String { SaveName.applying(filter.map { request.filters[$0] }, to: name) }
    private var canAccept: Bool { !saving || SaveName.valid(chosenName) }

    var body: some View {
        NavigationStack(path: $stack) {
            screen(.home)
                .navigationDestination(for: ComputerPath.self) { path in screen(path) }
        }
        .safeAreaInset(edge: .bottom) { if saving { saveBar } }
        .onAppear(perform: start)
        .confirmationDialog("“\(chosenName)” already exists in \(folder.name).", isPresented: $replacing, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { accept(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replacing it overwrites its current contents.")
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newFolder)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
        .alert("Couldn’t Continue", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    /// Each folder's screen: its name as the title, what the application asked as the subtitle.
    private func screen(_ path: ComputerPath) -> some View {
        FolderList(path: path, saving: saving, host: host, listings: $listings, pick: pickFile)
            .navigationTitle(path.components.isEmpty ? "Home" : path.name)
            .navigationSubtitle([request.appName, title].compactMap { $0 }.joined(separator: " · "))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }

    private var location: String {
        let names = folder.ancestry.dropFirst().map(\.name)
        return names.isEmpty ? "Home" : names.joined(separator: " › ")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { finish(.cancel) }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(acceptLabel) { accept(confirmed: false) }
                .buttonStyle(.glassProminent)
                .disabled(!canAccept)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { newFolder = ""; naming = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { finish(.computer) } label: { Label("Use Computer Dialog", systemImage: "desktopcomputer") }
            } label: { Label("More", systemImage: "ellipsis") }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                TextField("Name", text: $name, selection: $selection)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { accept(confirmed: false) }
                if request.filters.count > 1 {
                    Picker("Format", selection: $filter) {
                        ForEach(request.filters.indices, id: \.self) { index in
                            Text(request.filters[index].name).tag(Optional(index))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: filter) { _, _ in name = chosenName }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            Text("Saves in \(location)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func start() {
        stack = Array(request.startFolder.ancestry.dropFirst())
        filter = request.currentFilter ?? (request.filters.isEmpty ? nil : 0)
        guard saving else { return }
        name = request.currentName.isEmpty ? "Untitled" : request.currentName
        name = chosenName
        selection = TextSelection(range: SaveName.baseRange(of: name))
        nameFocused = true
    }

    private func pickFile(_ item: HostClient.FolderItem) {
        guard saving else { return }
        name = item.name
        selection = TextSelection(range: SaveName.baseRange(of: name))
        nameFocused = true
    }

    private func accept(confirmed: Bool) {
        guard canAccept else { return }
        if !saving { finish(.chose([folder], filter: nil)); return }
        let file = chosenName
        guard let path = folder.appending(file) else { error = "“\(file)” can’t be used as a file name."; return }
        let existing = listings[folder]?.first { $0.name == file }
        if existing?.isFolder == true { error = "A folder named “\(file)” is already here."; return }
        if existing != nil && !confirmed { replacing = true; return }
        finish(.chose([path], filter: filter))
    }

    private func createFolder() async {
        let folderName = newFolder.trimmingCharacters(in: .whitespaces)
        newFolder = ""
        guard let path = folder.appending(folderName) else { error = "“\(folderName)” can’t be used as a folder name."; return }
        do {
            try await host.openDocumentMkdir(path.relative)
            listings[folder] = try await host.folder(folder)
            stack.append(path)
        } catch { self.error = error.localizedDescription }
    }
}

/// One folder of the computer's home: its folders to open, and in Save its files, to
/// take a name from.
private struct FolderList: View {
    let path: ComputerPath
    let saving: Bool
    let host: HostClient
    @Binding var listings: [ComputerPath: [HostClient.FolderItem]]
    let pick: (HostClient.FolderItem) -> Void
    @State private var failure: String?

    var body: some View {
        Group {
            if let items = listings[path] {
                let shown = items.filter { saving || $0.isFolder }.filter { !$0.name.hasPrefix(".") }
                if shown.isEmpty {
                    ContentUnavailableView(saving ? "Empty Folder" : "No Folders", systemImage: "folder",
                                           description: Text(saving ? "Save here, or create a folder." : "Choose this folder, or create one."))
                } else {
                    List(shown, id: \.name) { item in
                        if item.isFolder, let child = path.appending(item.name) {
                            NavigationLink(value: child) { row(item) }
                        } else {
                            Button { pick(item) } label: { row(item) }.tint(.primary)
                        }
                    }
                    .listStyle(.plain)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn’t Open Folder", systemImage: "exclamationmark.triangle")
                } description: { Text(failure) } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: HostClient.FolderItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(Date(timeIntervalSince1970: item.mtime / 1000), format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: item.isFolder ? "folder.fill" : "doc").foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
        }
        .foregroundStyle(item.isFolder || saving ? .primary : .secondary)
    }

    private func load() async {
        do {
            failure = nil
            listings[path] = try await host.folder(path)
        } catch { failure = error.localizedDescription }
    }
}
