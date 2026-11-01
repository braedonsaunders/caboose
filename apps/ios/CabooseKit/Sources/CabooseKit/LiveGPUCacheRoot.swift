import Foundation

/// Where the live GPU decoder keeps one computer's persistent caches: the SPIR-V modules it
/// sent (`shaders/`) and the pipelines built from them (`pipeline/`), so a later session
/// names them by hash instead of sending them (docs/gpu-live.md, "Shader cache"). Each
/// pairing has its own directory, so one computer never sees what another one sent.
/// They live in Application Support, which iOS does not purge, and are excluded from the
/// phone's backup: they are rebuilt by using the computer.
public enum LiveGPUCacheRoot {
    static let folder = "CabooseGPU"

    /// The pairing's directory, created if needed. `pairing` is one path component.
    public static func directory(pairing: String, base: URL? = nil) throws -> URL {
        guard isComponent(pairing) else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = try base ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        var root = parent.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let directory = root.appendingPathComponent(pairing, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Forgets a pairing's caches (sign-out).
    public static func remove(pairing: String, base: URL? = nil) {
        guard isComponent(pairing),
              let parent = try? base ?? FileManager.default.url(for: .applicationSupportDirectory,
                  in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(pairing, isDirectory: true))
    }

    static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
