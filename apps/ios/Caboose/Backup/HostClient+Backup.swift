import CabooseKit
import Foundation

/// `/v1/backup`: phone backups of the computer's disk (docs/architecture.md, Phone backups).
/// None of these routes wakes the computer.
extension HostClient {
    struct BackupStatus: Decodable, Equatable, Sendable {
        struct Device: Decodable, Equatable, Sendable {
            var id: String
            var name: String?
            var lastCompletedAt: String?
        }
        var available: Bool
        var reason: String?
        /// Whether this phone keeps backups of the computer.
        var enabled: Bool
        var devices: [Device]
        /// The newest capture on the host.
        var capture: CaptureInfo?
        var capturing: Bool
        /// A capture was asked for and will be taken the next time the computer parks.
        var pending: Bool
    }

    struct CaptureDetail: Decodable, Sendable {
        var info: CaptureInfo
        var manifest: BackupManifest
    }

    struct BackupPack: Decodable, Sendable {
        var id: String
        var chunks: [String]
        var bytes: Int
    }

    struct RestoreStarted: Decodable, Sendable {
        var id: String
        var missing: [String]
    }

    private func json<T: Decodable, Body: Encodable>(_ method: String, _ path: String, _ body: Body, timeout: TimeInterval) async throws -> T {
        let data = try await send(method, path, payload: try JSONEncoder().encode(body), contentType: "application/json", accept: "application/json", timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func backupStatus() async throws -> BackupStatus { try await request("GET", "/v1/backup", timeout: 20) }

    func setBackups(enabled: Bool) async throws -> BackupStatus {
        try await request("PUT", "/v1/backup/device", body: ["enabled": .bool(enabled)], timeout: 20)
    }

    /// Ask for a fresh capture: now if the computer is parked, otherwise when it next parks.
    func requestCapture() async throws -> BackupStatus { try await request("POST", "/v1/backup/capture", timeout: 20) }

    func capture(_ id: String) async throws -> CaptureDetail {
        try await request("GET", "/v1/backup/captures/\(id.pathComponent)", timeout: 60)
    }

    func planPacks(capture: String, chunks: [String]) async throws -> [BackupPack] {
        struct Body: Encodable { var chunks: [String] }
        struct Reply: Decodable { var packs: [BackupPack] }
        let reply: Reply = try await json("POST", "/v1/backup/captures/\(capture.pathComponent)/packs", Body(chunks: chunks), timeout: 120)
        return reply.packs
    }

    /// A pack's chunks, concatenated in the order the plan listed them.
    func pack(_ id: String) async throws -> Data { try await data("/v1/backup/packs/\(id.pathComponent)", accept: "application/octet-stream", timeout: 600) }

    func completeBackup(capture: String) async throws -> BackupStatus {
        try await request("POST", "/v1/backup/complete", body: ["capture": .string(capture)], timeout: 20)
    }

    func beginRestore(image: BackupImage, manifest: BackupManifest) async throws -> RestoreStarted {
        struct Body: Encodable { var image: BackupImage; var manifest: BackupManifest }
        return try await json("POST", "/v1/backup/restores", Body(image: image, manifest: manifest), timeout: 300)
    }

    /// Records built with `ChunkRecords.encode`; answers how many chunks are still missing.
    func uploadChunks(restore: String, records: Data) async throws -> Int {
        struct Reply: Decodable { var missing: Int }
        let data = try await send("PUT", "/v1/backup/restores/\(restore.pathComponent)/chunks", payload: records, contentType: "application/octet-stream", accept: "application/json", timeout: 600)
        return try JSONDecoder().decode(Reply.self, from: data).missing
    }

    /// Replaces the computer's disk and restarts it: memory and everything since the backup are discarded.
    func applyRestore(_ id: String) async throws -> BackupStatus {
        try await request("POST", "/v1/backup/restores/\(id.pathComponent)/apply", body: ["confirm": .bool(true)], timeout: 900)
    }
}

private extension String {
    var pathComponent: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? self }
}
