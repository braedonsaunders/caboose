import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// One computer-owned Desktop shared by the tiled desktop and external display.
struct DesktopFilesView: View {
    @Environment(AppModel.self) private var model
    var desktop: DesktopModel?
    @State private var importing = false
    @State private var editing: DesktopFilesCenter.Item?
    @State private var name = ""
    @State private var folder = "Desktop"
    @State private var editPresented = false
    @State private var makingFolder = false

    var body: some View {
        let center = model.desktopFiles
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        editing = nil; makingFolder = true; name = ""; editPresented = true
                    }
                    Button("Import File", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Open Desktop in Files", systemImage: "folder") { Task { await model.openFile("Desktop") } }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await center.refresh(model: model) } }
                } label: { Label("Desktop", systemImage: "folder").font(.caption.weight(.semibold)).padding(8) }
                .background(.ultraThinMaterial, in: Capsule())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop?.desktopMenuFrame = $0 }
                .popover(isPresented: Binding(get: { desktop?.desktopMenuOpen ?? false }, set: { desktop?.desktopMenuOpen = $0 })) {
                    VStack(spacing: 16) {
                        Button("Import File") { desktop?.desktopMenuOpen = false; importing = true }
                        Button("New Folder") { desktop?.desktopMenuOpen = false; editing = nil; makingFolder = true; name = ""; editPresented = true }
                        Button("Open Desktop in Files") { desktop?.desktopMenuOpen = false; Task { await model.openFile("Desktop") } }
                        Button("Refresh") { desktop?.desktopMenuOpen = false; Task { await center.refresh(model: model) } }
                    }.padding().presentationCompactAdaptation(.popover)
                }
                if center.busy { ProgressView().tint(.white) }
                Spacer()
            }
            if let error = center.error {
                HStack {
                    Text(error).font(.caption).lineLimit(3)
                    Button("Retry") { Task { await center.refresh(model: model) } }
                }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 110), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(center.items) { item in
                        Button { Task { await center.open(item, model: model) } } label: {
                            VStack(spacing: 5) {
                                Group {
                                    if let id = center.shortcutApps[item.id], let icon = model.appIcons[id] {
                                        Image(uiImage: icon).resizable().scaledToFit()
                                    } else { Image(systemName: item.symbol).font(.system(size: 34)).foregroundStyle(item.directory ? .cyan : .white) }
                                }.frame(width: 38, height: 38)
                                    .overlay(alignment: .bottomLeading) {
                                        if center.shortcutApps[item.id] != nil {
                                            Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .bold))
                                                .padding(2).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                                Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                    .shadow(color: .black, radius: 2)
                            }.frame(maxWidth: .infinity).frame(height: 82).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onDisappear { desktop?.desktopItemFrames[item.id] = nil }
                        .contextMenu { actions(item) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop?.desktopItemFrames[item.id] = $0 }
                        .popover(isPresented: Binding(get: { desktop?.desktopContextItem == item.id }, set: { if !$0 { desktop?.desktopContextItem = nil } })) {
                            VStack(alignment: .leading, spacing: 16) { actions(item) }.padding().presentationCompactAdaptation(.popover)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .foregroundStyle(.white)
        .task(id: model.credentials?.fileDomainIdentifier) {
            desktop?.openDesktopItem = { id in
                if let item = center.items.first(where: { $0.id == id }) { Task { await center.open(item, model: model) } }
            }
            await center.refresh(model: model)
        }
        .onDisappear {
            desktop?.desktopItemFrames.removeAll(); desktop?.openDesktopItem = nil; desktop?.desktopMenuFrame = .zero
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { for file in files { await center.importFile(file, model: model) } }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await center.importFile(url, model: model) }
            case .failure(let error): center.error = error.localizedDescription
            }
        }
        .alert(makingFolder ? "New Folder" : "Move or Rename", isPresented: $editPresented) {
            TextField("Name", text: $name)
            if !makingFolder { TextField("Folder in computer home", text: $folder) }
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    if makingFolder { await center.newFolder(name, model: model) }
                    else if let editing { await center.move(editing, folder: folder, name: name, model: model) }
                }
            }
        } message: {
            Text(makingFolder ? "Create a folder on the computer’s Desktop." : "Use a folder relative to your computer home, such as Documents. Existing files are never replaced.")
        }
    }

    @ViewBuilder private func actions(_ item: DesktopFilesCenter.Item) -> some View {
        Button("Open", systemImage: "arrow.up.forward.app") {
            desktop?.desktopContextItem = nil
            Task { await model.desktopFiles.open(item, model: model) }
        }
        Button("Move or Rename", systemImage: "pencil") {
            desktop?.desktopContextItem = nil
            editing = item; name = item.name; folder = "Desktop"; makingFolder = false; editPresented = true
        }
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            desktop?.desktopContextItem = nil
            Task { await model.desktopFiles.trash(item, model: model) }
        }
    }
}
