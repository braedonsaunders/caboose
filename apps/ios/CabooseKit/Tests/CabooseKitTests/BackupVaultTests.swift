import CryptoKit
import XCTest
@testable import CabooseKit

final class BackupManifestTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    func testDecodesRunsAndHashesAsTheHostWritesThem() throws {
        let json = #"{"version":1,"diskBytes":20480,"chunkBytes":4096,"baseSha256":"\#(a)","chunks":[{"base":2},"\#(b)",{"zero":1},"\#(b)"]}"#
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(json.utf8)).validated()
        XCTAssertEqual(manifest.expanded, [.base, .base, .data(b), .zero, .data(b)])
        XCTAssertEqual(manifest.dataChunks.map(\.hash), [b])
        let again = try JSONDecoder().decode(BackupManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(again, manifest)
    }

    func testTheLastChunkMayBeShort() throws {
        let manifest = try BackupManifest(diskBytes: 12288, chunkBytes: 8192, baseSha256: nil, chunks: [.zero(1), .data(a)]).validated()
        XCTAssertEqual(manifest.length(ofChunk: 0), 8192)
        XCTAssertEqual(manifest.dataChunks.first?.length, 4096)
    }

    func testRejectsWhatTheHostWouldReject() {
        let invalid: [BackupManifest] = [
            BackupManifest(diskBytes: 8192, chunkBytes: 4096, baseSha256: nil, chunks: [.zero(1)]),
            BackupManifest(diskBytes: 4096, chunkBytes: 4096, baseSha256: nil, chunks: [.base(1)]),
            BackupManifest(diskBytes: 4096, chunkBytes: 3000, baseSha256: nil, chunks: [.zero(1)]),
            BackupManifest(diskBytes: 4096, chunkBytes: 4096, baseSha256: nil, chunks: [.data("ABC")]),
            BackupManifest(version: 2, diskBytes: 4096, chunkBytes: 4096, baseSha256: nil, chunks: [.zero(1)]),
        ]
        for manifest in invalid { XCTAssertThrowsError(try manifest.validated()) }
    }

    func testImagesEncodeAMissingSystemImageAsNull() throws {
        let image = BackupImage(baseSha256: a, vmlinux: b, initrd: b, systemErofs: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any]
        XCTAssertTrue(object?["systemErofs"] is NSNull)
    }

    func testUploadRecordsCarryHashLengthAndBytes() {
        let record = ChunkRecords.encode(hash: a, data: Data([1, 2, 3]))
        XCTAssertEqual(record.count, 39)
        XCTAssertEqual(record.prefix(32), Data(repeating: 0xaa, count: 32))
        XCTAssertEqual(Array(record[32 ..< 36]), [0, 0, 0, 3])
        XCTAssertEqual(Array(record.suffix(3)), [1, 2, 3])
    }
}

final class ChunkVaultTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func chunk(_ byte: UInt8, _ count: Int = 4096) -> (data: Data, hash: String) {
        let data = Data(repeating: byte, count: count)
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func snapshot(_ id: String, _ hashes: [String], date: String) -> ChunkVault.Snapshot {
        let manifest = BackupManifest(diskBytes: Int64(4096 * max(hashes.count, 1)), chunkBytes: 4096, baseSha256: nil, chunks: hashes.isEmpty ? [.zero(1)] : hashes.map { .data($0) })
        let info = CaptureInfo(id: id, createdAt: date, diskBytes: manifest.diskBytes, chunkBytes: 4096, dataChunks: hashes.count, dataBytes: Int64(hashes.count * 4096),
                               image: BackupImage(baseSha256: String(repeating: "c", count: 64), vmlinux: String(repeating: "d", count: 64), initrd: String(repeating: "e", count: 64), systemErofs: nil))
        return ChunkVault.Snapshot(info: info, manifest: manifest)
    }

    func testStoresChunksEncryptedUnderNamesThatRevealNothing() throws {
        let vault = try ChunkVault.open(directory: directory, key: key, label: .init(computerName: "Studio", hostAddress: "https://host.example"))
        let one = chunk(1), two = chunk(2)
        XCTAssertEqual(vault.missing([one.hash, two.hash]), [one.hash, two.hash])
        XCTAssertEqual(try vault.ingest(pack: one.data + two.data, chunks: [(one.hash, 4096), (two.hash, 4096)]), 2)
        XCTAssertEqual(vault.missing([one.hash, two.hash]), [])
        XCTAssertEqual(try vault.read(two.hash), two.data)
        // Nothing on disk holds the plaintext, a chunk's hash, or the computer's name.
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        for file in files where !file.hasDirectoryPath {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data(repeating: 1, count: 64)), file.lastPathComponent)
            XCTAssertNil(bytes.range(of: Data("Studio".utf8)), file.lastPathComponent)
            XCTAssertFalse(file.lastPathComponent.contains(one.hash.prefix(16)))
        }
        XCTAssertEqual(ChunkVault.label(directory: directory, key: key)?.computerName, "Studio")
        XCTAssertNil(ChunkVault.label(directory: directory, key: SymmetricKey(size: .bits256)))
    }

    func testAPackWithACorruptChunkStoresNothing() throws {
        let vault = try ChunkVault.open(directory: directory, key: key)
        let one = chunk(1), two = chunk(2)
        var pack = one.data + two.data
        pack[5000] ^= 0xff
        XCTAssertThrowsError(try vault.ingest(pack: pack, chunks: [(one.hash, 4096), (two.hash, 4096)])) { error in
            XCTAssertEqual(error as? BackupError, .corruptChunk(two.hash))
        }
        XCTAssertEqual(vault.missing([one.hash]), [one.hash])
        XCTAssertThrowsError(try vault.ingest(pack: one.data, chunks: [(one.hash, 4096), (two.hash, 4096)]))
    }

    func testAnotherKeyCannotOpenTheVault() throws {
        _ = try ChunkVault.open(directory: directory, key: key)
        XCTAssertThrowsError(try ChunkVault.open(directory: directory, key: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? BackupError, .wrongKey)
        }
    }

    func testReopensWithItsIndexAndSnapshots() throws {
        let one = chunk(1)
        do {
            let vault = try ChunkVault.open(directory: directory, key: key)
            try vault.ingest(pack: one.data, chunks: [(one.hash, 4096)])
            XCTAssertThrowsError(try vault.save(snapshot("s1", [one.hash, chunk(9).hash], date: "2026-10-29T00:00:00.000Z")))
            try vault.save(snapshot("s1", [one.hash], date: "2026-10-29T00:00:00.000Z"))
        }
        let vault = try ChunkVault.open(directory: directory, key: key)
        XCTAssertTrue(vault.contains(snapshot: "s1"))
        XCTAssertEqual(try vault.snapshots().map(\.id), ["s1"])
        XCTAssertEqual(try vault.read(one.hash), one.data)
    }

    func testPruningKeepsTheNewestCapturesAndReclaimsTheRest() throws {
        let vault = try ChunkVault.open(directory: directory, key: key)
        let shared = chunk(1, 65536), old = chunk(2, 65536), newer = chunk(3, 65536)
        try vault.ingest(pack: shared.data + old.data, chunks: [(shared.hash, 65536), (old.hash, 65536)])
        try vault.save(snapshot("s1", [shared.hash, old.hash], date: "2026-10-27T00:00:00.000Z"))
        try vault.ingest(pack: newer.data, chunks: [(newer.hash, 65536)])
        try vault.save(snapshot("s2", [shared.hash, newer.hash], date: "2026-10-28T00:00:00.000Z"))
        let before = vault.storedBytes
        try vault.prune(keeping: 1)
        XCTAssertEqual(try vault.snapshots().map(\.id), ["s2"])
        XCTAssertLessThan(vault.storedBytes, before)
        XCTAssertEqual(try vault.read(shared.hash), shared.data)
        XCTAssertEqual(try vault.read(newer.hash), newer.data)
        XCTAssertThrowsError(try vault.read(old.hash))
        let reopened = try ChunkVault.open(directory: directory, key: key)
        XCTAssertEqual(try reopened.read(shared.hash), shared.data)
    }
}
