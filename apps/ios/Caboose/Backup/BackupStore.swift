import CabooseKit
import CryptoKit
import Foundation
import Security

/// Where this phone keeps computer backups, and the key that seals them.
///
/// Backups live on this iPhone (excluded from the iPhone's own iCloud backup, since they can
/// be large) or in the app's iCloud Drive container. Either way they are sealed with one key
/// kept in iCloud Keychain, so another of the person's devices can read a backup in iCloud.
enum BackupStore {
    enum Location: String, CaseIterable, Identifiable, Sendable {
        case device
        case iCloud
        var id: String { rawValue }
        var title: String { self == .device ? "On This iPhone" : "iCloud Drive" }
    }

    static let containerIdentifier = "iCloud.com.braedonsaunders.caboose"
    private static let defaults = UserDefaults.standard
    private static let locationKey = "caboose.backup.location"
    private static let enabledKey = "caboose.backup.enabledComputers"

    static var location: Location {
        get { defaults.string(forKey: locationKey).flatMap(Location.init(rawValue:)) ?? .device }
        set { defaults.set(newValue.rawValue, forKey: locationKey) }
    }

    /// Computers (by `Credentials.id`) this phone backs up.
    static var enabled: Set<String> {
        get { Set(defaults.stringArray(forKey: enabledKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: enabledKey) }
    }

    /// The folder holding every computer's vault in `location`; nil when iCloud Drive is off.
    /// Call off the main thread: finding the iCloud container can take a moment.
    static func root(_ location: Location) -> URL? {
        let manager = FileManager.default
        switch location {
        case .device:
            guard var url = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Backups", isDirectory: true) else { return nil }
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return url
        case .iCloud:
            guard let container = manager.url(forUbiquityContainerIdentifier: containerIdentifier) else { return nil }
            let url = container.appendingPathComponent("Documents/Backups", isDirectory: true)
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    static func vaultDirectory(for computerID: String, in location: Location) -> URL? {
        root(location)?.appendingPathComponent(computerID, isDirectory: true)
    }

    struct StoredVault: Identifiable, Hashable, Sendable {
        var directory: URL
        var location: Location
        var label: ChunkVault.Label?
        var id: URL { directory }
    }

    /// Every vault on this phone and in iCloud Drive that this phone's key opens.
    static func vaults() throws -> [StoredVault] {
        let key = try BackupKey.load()
        var found: [StoredVault] = []
        for location in Location.allCases {
            guard let root = root(location) else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for directory in entries where directory.hasDirectoryPath {
                if location == .iCloud { downloadAll(in: directory) }
                if let label = ChunkVault.label(directory: directory, key: key) { found.append(StoredVault(directory: directory, location: location, label: label)) }
            }
        }
        return found
    }

    /// Ask iCloud for every file of a vault that is not on this device yet.
    static func downloadAll(in directory: URL) {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files { try? FileManager.default.startDownloadingUbiquitousItem(at: file) }
    }

    /// Wait until iCloud has every file of a vault on this device (restores read them all).
    static func waitUntilDownloaded(_ directory: URL) async throws {
        downloadAll(in: directory)
        for _ in 0 ..< 3600 {
            try Task.checkCancellation()
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])?.compactMap { $0 as? URL } ?? []
            let pending = files.contains { file in
                guard let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else { return false }
                return status != .current
            }
            if !pending { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw BackupError.unreadableVault("iCloud has not finished downloading the backup")
    }
}

/// The 256-bit key sealing every backup, in iCloud Keychain.
enum BackupKey {
    private static let service = "com.braedonsaunders.caboose.backup"
    private static let account = "vault-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any]
    }

    /// The key, made the first time a backup is stored.
    static func load() throws -> SymmetricKey {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw BackupError.unreadableVault("the Keychain refused the backup key (\(status))") }
        let key = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // Background backups run while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw BackupError.unreadableVault("the Keychain refused the backup key (\(added))") }
        return key
    }
}
