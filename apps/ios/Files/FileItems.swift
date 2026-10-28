import Foundation
import CabooseKit
import FileProvider
import UniformTypeIdentifiers

/// Persistent provider identifiers survive renames; paths are only transport addresses.
final class ItemIndex {
    private static let registryLock = NSLock()
    private static var registry: [String: ItemIndex] = [:]
    static func forDomain(_ domain: NSFileProviderDomain) -> ItemIndex {
        registryLock.lock(); defer { registryLock.unlock() }
        let id = domain.identifier.rawValue
        if let existing = registry[id] { return existing }
        let created = ItemIndex(id: id); registry[id] = created; return created
    }
    private let lock = NSLock()
    private let key: String
    private let defaults = UserDefaults(suiteName: "group.com.braedonsaunders.caboose") ?? .standard
    private var paths: [String: String]
    private var identities: [String: String]
    private var tombstones: [String: String]
    private init(id: String) {
        key = "file-provider-index-v1-" + id
        paths = defaults.dictionary(forKey: key) as? [String: String] ?? UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        identities = defaults.dictionary(forKey: key + "-identities") as? [String: String] ?? UserDefaults.standard.dictionary(forKey: key + "-identities") as? [String: String] ?? [:]
        tombstones = defaults.dictionary(forKey: key + "-deleted") as? [String: String] ?? UserDefaults.standard.dictionary(forKey: key + "-deleted") as? [String: String] ?? [:]
        save()
    }
    private func save() {
        defaults.set(paths, forKey: key)
        defaults.set(identities, forKey: key + "-identities")
        defaults.set(tombstones, forKey: key + "-deleted")
    }
    func identifier(_ path: String) -> NSFileProviderItemIdentifier {
        if path.isEmpty { return .rootContainer }
        lock.lock(); defer { lock.unlock() }
        if let id = paths[path] { return NSFileProviderItemIdentifier(id) }
        let id = UUID().uuidString; paths[path] = id; tombstones.removeValue(forKey: path); save()
        return NSFileProviderItemIdentifier(id)
    }
    func path(_ id: NSFileProviderItemIdentifier) throws -> String {
        if id == .rootContainer { return "" }
        lock.lock(); defer { lock.unlock() }
        guard let path = paths.first(where: { $0.value == id.rawValue })?.key else { throw NSFileProviderError(.noSuchItem) }
        return path
    }
    func note(_ path: String, identity: String) {
        guard !path.isEmpty else { return }
        let id = identifier(path).rawValue
        lock.lock(); defer { lock.unlock() }
        identities[id] = identity; save()
    }
    func candidate(for path: String, identity: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard paths[path] == nil else { return nil }
        let ids = Set(identities.filter { $0.value == identity }.keys)
        let matches = paths.filter { ids.contains($0.value) }
        return matches.count == 1 ? matches.first?.key : nil
    }
    func move(_ old: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        paths = FilePathIndex.moving(paths, from: old, to: new)
        save()
    }
    func remove(_ path: String) -> [NSFileProviderItemIdentifier] {
        lock.lock(); defer { lock.unlock() }
        let result = FilePathIndex.removing(paths, path: path)
        for (name, id) in paths where name == path || name.hasPrefix(path + "/") { tombstones[name] = id }
        paths = result.remaining
        for id in result.removed { identities.removeValue(forKey: id) }
        save()
        return tombstones.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.values.map { NSFileProviderItemIdentifier($0) }
    }
}

final class FileItem: NSObject, NSFileProviderItem {
    let path: String
    let remote: RemoteItem
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    init(path: String, remote: RemoteItem, index: ItemIndex) {
        self.path = path; self.remote = remote
        index.note(path, identity: remote.identity)
        self.itemIdentifier = index.identifier(path)
        let parent = (path as NSString).deletingLastPathComponent
        self.parentItemIdentifier = index.identifier(parent == "." ? "" : parent)
    }
    var filename: String { path.isEmpty ? "Caboose" : remote.name }
    var contentType: UTType { remote.kind == "directory" ? .folder : (UTType(mimeType: remote.contentType) ?? UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data) }
    var documentSize: NSNumber? { remote.kind == "file" ? NSNumber(value: remote.size) : nil }
    var contentModificationDate: Date? { Date(timeIntervalSince1970: remote.mtime / 1000) }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: Data(remote.etag.utf8), metadataVersion: Data(remote.etag.utf8)) }
    var capabilities: NSFileProviderItemCapabilities {
        path.isEmpty ? [.allowsReading, .allowsWriting] : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }
}
