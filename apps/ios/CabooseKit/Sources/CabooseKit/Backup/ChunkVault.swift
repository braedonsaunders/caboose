import CryptoKit
import Foundation

/// A computer's backups on this device: its data chunks, encrypted and packed into files, and
/// the captures (manifests) they make up.
///
/// Every file is sealed with AES-GCM under keys derived from one 256-bit key the app keeps in
/// the Keychain. A chunk is stored under an HMAC of its SHA-256, so the files name nothing
/// about their contents, and is authenticated with that name, so chunks cannot be swapped.
/// A chunk held by several captures is stored once. One owner at a time: callers serialize use.
public final class ChunkVault {
    /// Which computer the backups are of, for listing backups from computers this phone no longer uses.
    public struct Label: Codable, Equatable, Hashable, Sendable {
        public var computerName: String
        public var hostAddress: String
        public init(computerName: String, hostAddress: String) {
            self.computerName = computerName
            self.hostAddress = hostAddress
        }
    }

    public struct Snapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var info: CaptureInfo
        public var manifest: BackupManifest
        public var id: String { info.id }
        public init(info: CaptureInfo, manifest: BackupManifest) {
            self.info = info
            self.manifest = manifest
        }
    }

    struct Location: Codable, Equatable {
        var pack: String
        var offset: Int
        var length: Int
    }

    struct Index: Codable {
        var chunks: [String: Location] = [:]
    }

    struct Header: Codable {
        var version: Int
        var keyCheck: String
    }

    public let directory: URL
    private let sealing: SymmetricKey
    private let naming: SymmetricKey
    private var index = Index()

    private var packs: URL { directory.appendingPathComponent("packs", isDirectory: true) }
    private var snapshotsDirectory: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }

    private init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("caboose backup sealing".utf8), outputByteCount: 32)
        naming = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("caboose backup naming".utf8), outputByteCount: 32)
    }

    private var keyCheck: String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("caboose backup vault".utf8), using: naming)).hexString
    }

    /// Open (or create) the vault in `directory`. A vault made with another key is refused.
    public static func open(directory: URL, key: SymmetricKey, label: Label? = nil) throws -> ChunkVault {
        let vault = ChunkVault(directory: directory, key: key)
        let manager = FileManager.default
        try manager.createDirectory(at: vault.packs, withIntermediateDirectories: true)
        try manager.createDirectory(at: vault.snapshotsDirectory, withIntermediateDirectories: true)
        let headerURL = directory.appendingPathComponent("vault.json")
        if let data = try? Data(contentsOf: headerURL) {
            guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1 else { throw BackupError.unreadableVault("unknown format") }
            guard header.keyCheck == vault.keyCheck else { throw BackupError.wrongKey }
        } else {
            try JSONEncoder().encode(Header(version: 1, keyCheck: vault.keyCheck)).write(to: headerURL, options: .atomic)
        }
        if let label { try vault.writeSealed(label, to: directory.appendingPathComponent("label.sealed"), role: "label") }
        let indexURL = directory.appendingPathComponent("index.sealed")
        if manager.fileExists(atPath: indexURL.path) { vault.index = try vault.readSealed(Index.self, from: indexURL, role: "index") }
        return vault
    }

    /// The label of the vault in `directory`, if it is readable with `key`.
    public static func label(directory: URL, key: SymmetricKey) -> Label? {
        let vault = ChunkVault(directory: directory, key: key)
        return try? vault.readSealed(Label.self, from: directory.appendingPathComponent("label.sealed"), role: "label")
    }

    // MARK: Sealing

    private func seal(_ data: Data, role: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: sealing, authenticating: Data(role.utf8)).combined else { throw BackupError.unreadableVault("sealing failed") }
        return combined
    }

    private func unseal(_ sealed: Data, role: String) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: sealing, authenticating: Data(role.utf8))
        } catch {
            throw BackupError.unreadableVault("a file failed its integrity check")
        }
    }

    private func writeSealed<T: Encodable>(_ value: T, to url: URL, role: String) throws {
        try seal(try JSONEncoder().encode(value), role: role).write(to: url, options: .atomic)
    }

    private func readSealed<T: Decodable>(_ type: T.Type, from url: URL, role: String) throws -> T {
        let data = try unseal(try Data(contentsOf: url), role: role)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw BackupError.unreadableVault("a file is malformed") }
    }

    /// The stored name of a chunk: an HMAC of its SHA-256.
    func name(_ hash: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(hash.utf8), using: naming)).hexString
    }

    // MARK: Chunks

    public func contains(_ hash: String) -> Bool { index.chunks[name(hash)] != nil }

    /// The hashes this vault does not hold yet, in the order given.
    public func missing(_ hashes: [String]) -> [String] { hashes.filter { !contains($0) } }

    /// Store the chunks of a pack downloaded from the host: their bytes concatenated in the
    /// listed order. Every chunk is checked against its hash before anything is written.
    @discardableResult
    public func ingest(pack: Data, chunks: [(hash: String, length: Int)]) throws -> Int {
        guard pack.count == chunks.reduce(0, { $0 + $1.length }) else { throw BackupError.corruptChunk(chunks.first?.hash ?? "") }
        var sealed = Data()
        var added: [(String, Location)] = []
        let packName = UUID().uuidString.lowercased() + ".pack"
        var offset = pack.startIndex
        for chunk in chunks {
            let data = pack.subdata(in: offset ..< offset + chunk.length)
            offset += chunk.length
            guard SHA256.hash(data: data).hexString == chunk.hash else { throw BackupError.corruptChunk(chunk.hash) }
            let id = name(chunk.hash)
            guard index.chunks[id] == nil, !added.contains(where: { $0.0 == id }) else { continue }
            let record = try seal(data, role: "chunk:" + id)
            added.append((id, Location(pack: packName, offset: sealed.count, length: record.count)))
            sealed.append(record)
        }
        guard !added.isEmpty else { return 0 }
        try sealed.write(to: packs.appendingPathComponent(packName), options: .atomic)
        for (id, location) in added { index.chunks[id] = location }
        try saveIndex()
        return added.count
    }

    /// A chunk's bytes, checked against its hash.
    public func read(_ hash: String) throws -> Data {
        let id = name(hash)
        guard let location = index.chunks[id] else { throw BackupError.missingChunk(hash) }
        let handle = try FileHandle(forReadingFrom: packs.appendingPathComponent(location.pack))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(location.offset))
        guard let record = try handle.read(upToCount: location.length), record.count == location.length else { throw BackupError.missingChunk(hash) }
        let data = try unseal(record, role: "chunk:" + id)
        guard SHA256.hash(data: data).hexString == hash else { throw BackupError.corruptChunk(hash) }
        return data
    }

    private func saveIndex() throws {
        try writeSealed(index, to: directory.appendingPathComponent("index.sealed"), role: "index")
    }

    // MARK: Snapshots

    private func snapshotURL(_ id: String) -> URL { snapshotsDirectory.appendingPathComponent("\(name("snapshot:" + id)).sealed") }

    /// Record a capture once every one of its data chunks is held.
    public func save(_ snapshot: Snapshot) throws {
        _ = try snapshot.manifest.validated()
        if let absent = snapshot.manifest.dataChunks.first(where: { !contains($0.hash) }) { throw BackupError.missingChunk(absent.hash) }
        try writeSealed(snapshot, to: snapshotURL(snapshot.id), role: "snapshot")
    }

    public func contains(snapshot id: String) -> Bool { FileManager.default.fileExists(atPath: snapshotURL(id).path) }

    /// Stored captures, oldest first.
    public func snapshots() throws -> [Snapshot] {
        let files = try FileManager.default.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sealed" }
        return try files.map { try readSealed(Snapshot.self, from: $0, role: "snapshot") }.sorted { $0.info.createdAt < $1.info.createdAt }
    }

    /// Bytes this vault occupies on the device.
    public var storedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Keep the newest `count` captures and the chunks they need; reclaim the rest. Packs
    /// with at most half their bytes still needed are rewritten.
    public func prune(keeping count: Int) throws {
        let snapshots = try snapshots()
        for snapshot in snapshots.dropLast(count) { try FileManager.default.removeItem(at: snapshotURL(snapshot.id)) }
        let live = Set(snapshots.suffix(count).flatMap { $0.manifest.dataChunks.map { name($0.hash) } })
        index.chunks = index.chunks.filter { live.contains($0.key) }
        var byPack: [String: [(String, Location)]] = [:]
        for (id, location) in index.chunks { byPack[location.pack, default: []].append((id, location)) }
        let files = try FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: [.fileSizeKey])
        var obsolete: [URL] = []
        var rewrite = Data()
        let rewriteName = UUID().uuidString.lowercased() + ".pack"
        for file in files where file.pathExtension == "pack" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let entries = byPack[file.lastPathComponent] else { obsolete.append(file); continue }
            let liveBytes = entries.reduce(0) { $0 + $1.1.length }
            guard liveBytes * 2 <= size else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            for (id, location) in entries {
                try handle.seek(toOffset: UInt64(location.offset))
                guard let record = try handle.read(upToCount: location.length), record.count == location.length else { continue }
                index.chunks[id] = Location(pack: rewriteName, offset: rewrite.count, length: record.count)
                rewrite.append(record)
            }
            obsolete.append(file)
        }
        if !rewrite.isEmpty { try rewrite.write(to: packs.appendingPathComponent(rewriteName), options: .atomic) }
        try saveIndex()
        for file in obsolete { try? FileManager.default.removeItem(at: file) }
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
