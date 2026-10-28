import CabooseKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class OpenDocumentCenter {
    struct Pending: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let type: String?
        let copyOnly: Bool
    }
    struct Conflict: Identifiable {
        let record: OpenDocumentRecord
        let localHash: String
        let remoteETag: String
        var id: String { record.id }
    }
    var pending: Pending?
    var conflicts: [Conflict] = []
    var error: String?
    var busy = false
    var installing: String?
    private var queue: [Pending] = []
    private var syncing = false
    private var syncAgain = false
    private var syncTask: Task<Void, Never>?

    func reset() {
        syncTask?.cancel(); syncTask = nil
        syncing = false; syncAgain = false
        pending = nil; queue = []; conflicts = []; error = nil
    }

    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let inbox = documents?.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        let inInbox = inbox.map { url.standardizedFileURL.path.hasPrefix($0 + "/") } ?? false
        let item = Pending(url: url, name: url.lastPathComponent, type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier, copyOnly: inInbox)
        if pending == nil { pending = item } else { queue.append(item) }
    }
    func dismiss() { pending = queue.isEmpty ? nil : queue.removeFirst() }

    func matching(_ app: CatalogApp, pending: Pending) -> Bool {
        DocumentTypeMatching.matches(filename: pending.name, typeIdentifier: pending.type,
                                     extensions: app.fileTypes.extensions, typeIdentifiers: app.fileTypes.utTypes)
    }

    func installAndOpen(_ app: CatalogApp, model: AppModel) async {
        guard !busy, let pending else { return }
        busy = true; installing = app.id; error = nil
        defer { busy = false; installing = nil }
        await model.catalog.perform(app.id, action: "install")
        if let message = model.catalog.error { error = message; return }
        for _ in 0..<1800 {
            if Task.isCancelled { return }
            await model.catalog.refresh()
            if let state = model.catalog.apps.first(where: { $0.id == app.id }) {
                if state.installedVersion != nil { await open(pending, app: state, model: model); return }
                if state.progress?.phase == "failed" || (!state.busy && state.lastError != nil) {
                    error = state.progress?.message ?? state.lastError ?? "Installation failed."
                    return
                }
            }
            if let message = model.catalog.error { error = message; return }
            try? await Task.sleep(for: .seconds(1))
        }
        error = "Installation is still running. Return to the app to check its progress."
    }

    func choose(_ app: CatalogApp, model: AppModel) async {
        guard !busy, let pending else { return }
        if app.installedVersion == nil { await installAndOpen(app, model: model); return }
        busy = true; error = nil
        defer { busy = false }
        await open(pending, app: app, model: model)
    }

    private func open(_ item: Pending, app: CatalogApp, model: AppModel) async {
        guard let host = model.host, let credentials = model.credentials else { error = "Connect to your computer first."; return }
        do {
            let path: String
            if let direct = try await OpenDocumentStore.directPath(item.url, domain: credentials.fileDomainIdentifier) {
                path = direct
            } else if !item.copyOnly, let existing = try OpenDocumentStore.records(domain: credentials.fileDomainIdentifier).first(where: { record in
                (try? resolveURL(record).standardizedFileURL) == item.url.standardizedFileURL
            }) {
                try await reconcile(existing, host: host)
                if conflicts.contains(where: { $0.id == existing.id }) { dismiss(); return }
                path = existing.path
            } else {
                let accessing = item.url.startAccessingSecurityScopedResource()
                defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }
                let bookmark = try item.copyOnly ? nil : item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let (snapshot, hash) = try CoordinatedDocument.snapshot(item.url)
                defer { try? FileManager.default.removeItem(at: snapshot) }
                let id = UUID().uuidString
                let folder = "Caboose Documents/" + id
                let clean = (item.name as NSString).lastPathComponent
                guard !clean.isEmpty, clean != ".", clean != ".." else { throw HostClient.Failure.unreachable("The document has no usable name.") }
                path = folder + "/" + clean
                try await host.openDocumentMkdir("Caboose Documents", allowExisting: true)
                try await host.openDocumentMkdir(folder)
                let remote = try await host.openDocumentUpload(snapshot, path: path)
                if let bookmark {
                    try OpenDocumentStore.save(OpenDocumentRecord(id: id, domain: credentials.fileDomainIdentifier, name: clean,
                                                                  path: path, bookmark: bookmark, localHash: hash, remoteETag: remote.etag))
                }
            }
            try await host.openDocumentLaunch(path, desktopID: app.desktopId)
            model.showLaunchedDocument(app)
            dismiss()
            requestSync(model: model)
        } catch { self.error = error.localizedDescription }
    }

    /// Control events can arrive in bursts; reconcile again if a change arrives mid-transfer.
    func requestSync(model: AppModel) {
        if syncing { syncAgain = true; return }
        syncing = true
        syncTask = Task {
            repeat {
                syncAgain = false
                await sync(model: model)
            } while syncAgain && !Task.isCancelled
            if !Task.isCancelled { syncing = false; syncTask = nil }
        }
    }

    private func sync(model: AppModel) async {
        guard let host = model.host, let credentials = model.credentials else { return }
        do {
            let records = try OpenDocumentStore.records(domain: credentials.fileDomainIdentifier)
            for record in records where !conflicts.contains(where: { $0.id == record.id }) {
                guard !Task.isCancelled, model.credentials?.fileDomainIdentifier == credentials.fileDomainIdentifier else { return }
                do { try await reconcile(record, host: host) }
                catch { if !Task.isCancelled { self.error = "Could not sync \(record.name): \(error.localizedDescription)" } }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func resolveURL(_ record: OpenDocumentRecord) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: record.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { throw HostClient.Failure.unreachable("The original document needs to be opened again.") }
        return url
    }

    private func reconcile(_ input: OpenDocumentRecord, host: HostClient) async throws {
        var record = input
        let url = try resolveURL(record)
        let (snapshot, local) = try CoordinatedDocument.snapshot(url)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let remote = try await host.openDocumentStat(record.path)
        try Task.checkCancellation()
        switch OpenDocumentSync.decide(local: local, baselineLocal: record.localHash, remote: remote.etag, baselineRemote: record.remoteETag) {
        case .unchanged: return
        case .uploadLocal:
            let saved = try await host.openDocumentUpload(snapshot, path: record.path, match: remote.etag)
            record.localHash = local; record.remoteETag = saved.etag
        case .downloadRemote:
            let downloaded = try await host.openDocumentDownload(record.path, match: remote.etag)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard try await host.openDocumentStat(record.path).etag == remote.etag else { throw HostClient.Failure.unreachable("The computer copy changed during download.") }
            try Task.checkCancellation()
            record.localHash = try CoordinatedDocument.replace(url, with: downloaded, expectedHash: local)
            record.remoteETag = remote.etag
        case .conflict:
            conflicts.append(Conflict(record: record, localHash: local, remoteETag: remote.etag))
            return
        }
        try OpenDocumentStore.save(record)
    }

    func resolve(_ conflict: Conflict, keepComputer: Bool, model: AppModel) async {
        guard !busy, let host = model.host else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var record = conflict.record
            let url = try resolveURL(record)
            if keepComputer {
                let downloaded = try await host.openDocumentDownload(record.path, match: conflict.remoteETag)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                guard try await host.openDocumentStat(record.path).etag == conflict.remoteETag else { throw HostClient.Failure.unreachable("The computer copy changed again; review the conflict again.") }
                record.localHash = try CoordinatedDocument.replace(url, with: downloaded, expectedHash: conflict.localHash)
                record.remoteETag = conflict.remoteETag
            } else {
                let (snapshot, local) = try CoordinatedDocument.snapshot(url)
                defer { try? FileManager.default.removeItem(at: snapshot) }
                guard local == conflict.localHash else { throw HostClient.Failure.unreachable("The original changed again; review the conflict again.") }
                let saved = try await host.openDocumentUpload(snapshot, path: record.path, match: conflict.remoteETag)
                record.localHash = local; record.remoteETag = saved.etag
            }
            try OpenDocumentStore.save(record)
            conflicts.removeAll { $0.id == record.id }
            requestSync(model: model)
        } catch {
            conflicts.removeAll { $0.id == conflict.id }
            self.error = error.localizedDescription
            requestSync(model: model)
        }
    }
}
