import CabooseKit
import Foundation
import Observation

@MainActor @Observable
final class DesktopFilesCenter {
    struct Item: Identifiable {
        let name: String
        let directory: Bool
        let etag: String?
        var id: String { "Desktop/" + name }
        var symbol: String { DesktopItemPolicy.symbol(name: name, directory: directory) }
    }
    private(set) var items: [Item] = []
    private(set) var shortcutApps: [String: String] = [:]
    private(set) var busy = false
    var error: String?
    private var generation = 0
    private var refreshRevision = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private struct CachedShortcut { let etag: String; let appID: String? }
    private var shortcutCache: [String: CachedShortcut] = [:]

    func reset() {
        generation += 1; refreshRevision += 1
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
        items = []; shortcutApps = [:]; shortcutCache = [:]; busy = false; error = nil
    }

    func refresh(model: AppModel) async {
        if let refreshTask { refreshAgain = true; await refreshTask.value; return }
        let epoch = generation
        let task = Task {
            repeat {
                refreshAgain = false
                await load(model: model)
            } while refreshAgain && !Task.isCancelled && epoch == generation
        }
        refreshTask = task
        await task.value
        if epoch == generation { refreshTask = nil }
    }

    private func load(model: AppModel) async {
        guard let credentials = model.credentials else { return }
        let epoch = generation
        refreshRevision += 1
        let revision = refreshRevision
        do {
            let client = HostShortcutFiles(credentials: credentials)
            let entries: [ShortcutFileEntry]
            do { entries = try await client.list("Desktop") }
            catch HostClient.Failure.server(let status, _) where status == 404 {
                try await client.mkdir("Desktop", allowExisting: true)
                entries = try await client.list("Desktop")
            }
            var shortcuts: [String: String] = [:]
            var cache: [String: CachedShortcut] = [:]
            for entry in entries where (entry.name as NSString).pathExtension.lowercased() == "desktop" && entry.kind != "directory" && DesktopItemPolicy.path(name: entry.name) != nil {
                let path = "Desktop/" + entry.name
                if let cached = shortcutCache[path], cached.etag == entry.etag {
                    cache[path] = cached
                    shortcuts[path] = cached.appID
                } else if let data = try? await client.desktopShortcutData(path, etag: entry.etag) {
                    let id = DesktopAppShortcut.appID(from: data)
                    shortcuts[path] = id
                    if let etag = entry.etag { cache[path] = CachedShortcut(etag: etag, appID: id) }
                }
                guard !Task.isCancelled, generation == epoch, revision == refreshRevision, model.credentials == credentials else { return }
            }
            guard !Task.isCancelled, generation == epoch, revision == refreshRevision, model.credentials == credentials else { return }
            shortcutCache = cache
            shortcutApps = shortcuts
            items = entries.filter { !$0.name.hasPrefix(".") && DesktopItemPolicy.path(name: $0.name) != nil }
                .map { Item(name: $0.name, directory: $0.kind == "directory", etag: $0.etag) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            guard generation == epoch, revision == refreshRevision, model.credentials == credentials else { return }
            self.error = error.localizedDescription
        }
    }

    private func perform(model: AppModel, action: (HostShortcutFiles) async throws -> Void) async {
        guard !busy else { error = "Another Desktop change is still in progress."; return }
        guard let credentials = model.credentials else { error = "Connect to your computer first."; return }
        let epoch = generation
        busy = true; error = nil
        defer { if epoch == generation { busy = false } }
        do {
            try await action(HostShortcutFiles(credentials: credentials))
            guard epoch == generation, model.credentials == credentials else { return }
            await refresh(model: model)
        } catch {
            guard epoch == generation, model.credentials == credentials else { return }
            self.error = error.localizedDescription
        }
    }

    func move(_ item: Item, folder: String, name: String, model: AppModel) async {
        guard let destination = ShortcutPath.destination(folder: folder, filename: name), let etag = item.etag else {
            error = "Choose a valid folder and name, then refresh Desktop before trying again."; return
        }
        guard destination != item.id else { return }
        await perform(model: model) { try await $0.move(item.id, to: destination, etag: etag) }
    }
    func trash(_ item: Item, model: AppModel) async {
        guard let etag = item.etag else { error = "Refresh Desktop before moving this item to Trash."; return }
        await perform(model: model) { try await $0.trash(item.id, etag: etag) }
    }
    func newFolder(_ name: String, model: AppModel) async {
        guard let path = DesktopItemPolicy.path(name: name) else { error = "Enter a valid folder name."; return }
        await perform(model: model) { try await $0.mkdir(path) }
    }
    func importFile(_ url: URL, model: AppModel) async {
        guard let path = DesktopItemPolicy.path(name: url.lastPathComponent) else { return }
        await perform(model: model) { client in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await client.mkdir("Desktop", allowExisting: true)
            try await client.upload(path, from: url)
        }
    }
    func addShortcut(_ app: HostClient.App, model: AppModel) async {
        await perform(model: model) { _ in
            guard let host = model.host else { throw HostClient.Failure.unauthorized }
            try await host.createDesktopShortcut(app.id)
        }
    }
    func open(_ item: Item, model: AppModel) async {
        guard !item.directory, (item.name as NSString).pathExtension.lowercased() == "desktop" else { await model.openFile(item.id); return }
        guard let credentials = model.credentials else { return }
        do {
            let data = try await HostShortcutFiles(credentials: credentials).desktopShortcutData(item.id)
            guard model.credentials == credentials else { return }
            guard let appID = DesktopAppShortcut.appID(from: data), let app = model.apps.first(where: { $0.id == appID }) else {
                error = "This shortcut is unsupported or its application is unavailable. Add a shortcut from an installed app’s dock menu."; return
            }
            model.openOnDesktop(app)
        } catch { if model.credentials == credentials { self.error = error.localizedDescription } }
    }
}
