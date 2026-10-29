import CabooseKit
import Foundation

/// Copies a computer's newest capture into its vault, and restores a stored capture onto a
/// computer. One operation at a time; each step is committed, so an interrupted backup (a
/// background task running out of time, the phone leaving Wi-Fi) resumes where it stopped.
actor BackupEngine {
    static let shared = BackupEngine()

    struct Progress: Sendable, Equatable {
        var message: String
        var done: Int64
        var total: Int64
        var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
    }

    enum Outcome: Sendable, Equatable {
        /// The newest capture is stored.
        case stored(CaptureInfo)
        /// The host has no capture yet; one is taken the next time the computer parks.
        case waiting
        case unavailable(String)
    }

    /// Captures kept on the phone for each computer.
    static let kept = 2

    private func client(_ credentials: Credentials) async -> HostClient {
        HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
    }

    func backUp(_ credentials: Credentials, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        let host = await client(credentials)
        var status = try await host.backupStatus()
        guard status.available else { return .unavailable(status.reason ?? "This host cannot make backups") }
        if !status.enabled { status = try await host.setBackups(enabled: true) }
        guard let capture = status.capture else {
            _ = try await host.requestCapture()
            return .waiting
        }
        let location = BackupStore.location
        guard let directory = BackupStore.vaultDirectory(for: credentials.id, in: location) else {
            throw BackupError.unreadableVault("\(location.title) is unavailable")
        }
        let vault = try ChunkVault.open(directory: directory, key: try BackupKey.load(),
                                        label: .init(computerName: credentials.displayName, hostAddress: credentials.hostURL.absoluteString))
        if !vault.contains(snapshot: capture.id) {
            let detail = try await host.capture(capture.id)
            let manifest = try detail.manifest.validated()
            let lengths = Dictionary(manifest.dataChunks.map { ($0.hash, $0.length) }, uniquingKeysWith: { first, _ in first })
            let missing = vault.missing(manifest.dataChunks.map(\.hash))
            let total = missing.reduce(Int64(0)) { $0 + Int64(lengths[$1] ?? 0) }
            var done: Int64 = 0
            progress(Progress(message: "Backing up", done: 0, total: total))
            if !missing.isEmpty {
                for pack in try await host.planPacks(capture: capture.id, chunks: missing) {
                    try Task.checkCancellation()
                    let data = try await host.pack(pack.id)
                    try vault.ingest(pack: data, chunks: pack.chunks.map { ($0, lengths[$0] ?? 0) })
                    done += Int64(pack.bytes)
                    progress(Progress(message: "Backing up", done: done, total: total))
                }
            }
            try vault.save(ChunkVault.Snapshot(info: detail.info, manifest: manifest))
        }
        _ = try await host.completeBackup(capture: capture.id)
        try vault.prune(keeping: Self.kept)
        return .stored(capture)
    }

    /// Restore `snapshot` from the vault in `directory` onto the computer `credentials` names:
    /// its disk is replaced and it restarts. Chunks the host still holds are not sent.
    func restore(_ snapshot: ChunkVault.Snapshot, from directory: URL, onto credentials: Credentials,
                 progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        if (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            progress(Progress(message: "Downloading from iCloud", done: 0, total: 0))
            try await BackupStore.waitUntilDownloaded(directory)
        }
        let vault = try ChunkVault.open(directory: directory, key: try BackupKey.load())
        let host = await client(credentials)
        let started = try await host.beginRestore(image: snapshot.info.image, manifest: snapshot.manifest)
        let lengths = Dictionary(snapshot.manifest.dataChunks.map { ($0.hash, $0.length) }, uniquingKeysWith: { first, _ in first })
        let total = started.missing.reduce(Int64(0)) { $0 + Int64(lengths[$1] ?? 0) }
        var done: Int64 = 0
        var batch = Data()
        func flush() async throws {
            guard !batch.isEmpty else { return }
            _ = try await host.uploadChunks(restore: started.id, records: batch)
            batch = Data()
            progress(Progress(message: "Sending the backup", done: done, total: total))
        }
        progress(Progress(message: "Sending the backup", done: 0, total: total))
        for hash in started.missing {
            try Task.checkCancellation()
            let data = try vault.read(hash)
            batch.append(ChunkRecords.encode(hash: hash, data: data))
            done += Int64(data.count)
            if batch.count >= 64 << 20 { try await flush() }
        }
        try await flush()
        progress(Progress(message: "Restoring and restarting", done: total, total: total))
        _ = try await host.applyRestore(started.id)
    }
}
