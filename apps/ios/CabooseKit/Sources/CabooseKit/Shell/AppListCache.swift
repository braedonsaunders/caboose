import CryptoKit
import Foundation

/// The last successful installed-app response, scoped to a pairing. It is presentation
/// data only: the host still resolves and validates every launch against installed apps.
public actor AppListCache {
    public enum Failure: Error { case tooLarge }
    public static let byteLimit = 16 * 1024 * 1024
    private let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CabooseApps", isDirectory: true)) {
        self.directory = directory
    }

    public func read(pairing: String) -> Data? {
        let file = file(pairing)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.byteLimit,
              let data = try? Data(contentsOf: file), data.count <= Self.byteLimit else { return nil }
        return data
    }

    public func write(_ data: Data, pairing: String) throws {
        guard data.count <= Self.byteLimit else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(pairing), options: .atomic)
    }

    public func remove(pairing: String) {
        try? FileManager.default.removeItem(at: file(pairing))
    }

    private func file(_ pairing: String) -> URL {
        let key = SHA256.hash(data: Data(pairing.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
}
