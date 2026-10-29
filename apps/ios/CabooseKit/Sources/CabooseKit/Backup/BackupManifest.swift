import Foundation

/// What a backed-up disk needs to boot: the base image its unchanged chunks come from, its
/// kernel and initramfs, and for a split image its read-only system image (docs/architecture.md,
/// Phone backups).
public struct BackupImage: Codable, Equatable, Hashable, Sendable {
    public var baseSha256: String
    public var vmlinux: String
    public var initrd: String
    public var systemErofs: String?

    public init(baseSha256: String, vmlinux: String, initrd: String, systemErofs: String?) {
        self.baseSha256 = baseSha256
        self.vmlinux = vmlinux
        self.initrd = initrd
        self.systemErofs = systemErofs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseSha256, forKey: .baseSha256)
        try container.encode(vmlinux, forKey: .vmlinux)
        try container.encode(initrd, forKey: .initrd)
        // The host distinguishes a disk without a split image by an explicit null.
        try container.encode(systemErofs, forKey: .systemErofs)
    }
}

/// One capture of a parked computer's disk on its host.
public struct CaptureInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var createdAt: String
    public var diskBytes: Int64
    public var chunkBytes: Int
    public var dataChunks: Int
    public var dataBytes: Int64
    public var image: BackupImage

    public init(id: String, createdAt: String, diskBytes: Int64, chunkBytes: Int, dataChunks: Int, dataBytes: Int64, image: BackupImage) {
        self.id = id
        self.createdAt = createdAt
        self.diskBytes = diskBytes
        self.chunkBytes = chunkBytes
        self.dataChunks = dataChunks
        self.dataBytes = dataBytes
        self.image = image
    }

    /// When the capture was taken.
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

public enum BackupError: LocalizedError, Equatable {
    case invalidManifest(String)
    case corruptChunk(String)
    case missingChunk(String)
    case wrongKey
    case unreadableVault(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): "The backup's description is invalid: \(reason)."
        case .corruptChunk(let hash): "Part of the backup (\(hash.prefix(12))) did not match its checksum."
        case .missingChunk(let hash): "Part of the backup (\(hash.prefix(12))) is missing from this device."
        case .wrongKey: "This backup was encrypted with a key this device does not have. Turn on iCloud Keychain on the device that made it."
        case .unreadableVault(let reason): "The backup on this device cannot be read: \(reason)."
        }
    }
}

/// A disk described in fixed-size chunks: zeros, the same as the base at that offset, or data
/// named by its SHA-256. Only data chunks are stored on the device.
public struct BackupManifest: Codable, Equatable, Hashable, Sendable {
    public enum Entry: Codable, Equatable, Hashable, Sendable {
        case data(String)
        case zero(Int)
        case base(Int)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let hash = try? container.decode(String.self) {
                self = .data(hash)
                return
            }
            let run = try container.decode([String: Int].self)
            guard run.count == 1, let (kind, count) = run.first else { throw BackupError.invalidManifest("a run has more than one kind") }
            switch kind {
            case "zero": self = .zero(count)
            case "base": self = .base(count)
            default: throw BackupError.invalidManifest("unknown run \(kind)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .data(let hash): try container.encode(hash)
            case .zero(let count): try container.encode(["zero": count])
            case .base(let count): try container.encode(["base": count])
            }
        }
    }

    /// One chunk, after runs are expanded.
    public enum Chunk: Equatable, Hashable, Sendable {
        case zero
        case base
        case data(String)
    }

    public var version: Int
    public var diskBytes: Int64
    public var chunkBytes: Int
    public var baseSha256: String?
    public var chunks: [Entry]

    public init(version: Int = 1, diskBytes: Int64, chunkBytes: Int, baseSha256: String?, chunks: [Entry]) {
        self.version = version
        self.diskBytes = diskBytes
        self.chunkBytes = chunkBytes
        self.baseSha256 = baseSha256
        self.chunks = chunks
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(diskBytes, forKey: .diskBytes)
        try container.encode(chunkBytes, forKey: .chunkBytes)
        try container.encode(baseSha256, forKey: .baseSha256)
        try container.encode(chunks, forKey: .chunks)
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// The same checks the host makes.
    public func validated() throws -> BackupManifest {
        guard version == 1 else { throw BackupError.invalidManifest("unsupported version") }
        guard chunkBytes >= 4096, chunkBytes <= 64 << 20, chunkBytes & (chunkBytes - 1) == 0 else { throw BackupError.invalidManifest("chunk size") }
        guard diskBytes > 0, diskBytes % 4096 == 0, diskBytes <= 16 << 40 else { throw BackupError.invalidManifest("disk size") }
        if let baseSha256, !Self.isHash(baseSha256) { throw BackupError.invalidManifest("base") }
        var count: Int64 = 0
        for entry in chunks {
            switch entry {
            case .data(let hash):
                guard Self.isHash(hash) else { throw BackupError.invalidManifest("chunk hash") }
                count += 1
            case .zero(let run), .base(let run):
                guard run > 0 else { throw BackupError.invalidManifest("empty run") }
                if case .base = entry, baseSha256 == nil { throw BackupError.invalidManifest("base chunks without a base") }
                count += Int64(run)
            }
        }
        guard count == (diskBytes + Int64(chunkBytes) - 1) / Int64(chunkBytes) else { throw BackupError.invalidManifest("chunks do not cover the disk") }
        return self
    }

    public var expanded: [Chunk] {
        var out: [Chunk] = []
        for entry in chunks {
            switch entry {
            case .data(let hash): out.append(.data(hash))
            case .zero(let run): out.append(contentsOf: repeatElement(.zero, count: run))
            case .base(let run): out.append(contentsOf: repeatElement(.base, count: run))
            }
        }
        return out
    }

    /// The length of the chunk at `index`: every chunk is full but possibly the last.
    public func length(ofChunk index: Int) -> Int {
        Int(min(Int64(chunkBytes), diskBytes - Int64(index) * Int64(chunkBytes)))
    }

    /// Each distinct data chunk once, in disk order, with its length.
    public var dataChunks: [(hash: String, length: Int)] {
        var seen = Set<String>()
        var out: [(hash: String, length: Int)] = []
        for (index, chunk) in expanded.enumerated() {
            guard case .data(let hash) = chunk, seen.insert(hash).inserted else { continue }
            out.append((hash, length(ofChunk: index)))
        }
        return out
    }
}

/// Chunks sent to the host for a restore: repeated `[32-byte SHA-256][4-byte big-endian length][bytes]`.
public enum ChunkRecords {
    public static func encode(hash: String, data: Data) -> Data {
        var record = Data(capacity: 36 + data.count)
        record.append(Data(hexString: hash) ?? Data(count: 32))
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
        record.append(data)
        return record
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.utf8.count / 2)
        var iterator = hexString.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = Self.nibble(high), let l = Self.nibble(low) else { return nil }
            bytes.append(h << 4 | l)
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48 ... 57: c - 48
        case 97 ... 102: c - 87
        case 65 ... 70: c - 55
        default: nil
        }
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
