import Foundation

public enum DesktopItemPolicy {
    public static let directory = "Desktop"
    public static func path(name: String) -> String? {
        ShortcutPath.destination(folder: directory, filename: name)
    }
    public static func symbol(name: String, directory: Bool) -> String {
        if directory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "desktop": return "arrow.up.forward.app.fill"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo.fill"
        case "mp4", "mov", "mkv", "webm": return "film.fill"
        case "mp3", "wav", "flac", "m4a": return "music.note"
        case "zip", "gz", "tar", "7z": return "archivebox.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }
}

/// Reads only our installed-app reference from a standard desktop entry; never Exec.
public enum DesktopAppShortcut {
    public static let maximumBytes = 262144
    /// The cap is enforced on actual bytes, including unknown or dishonest Content-Length.
    public static func read<S: AsyncSequence>(_ stream: S) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            data.append(byte)
        }
        return data
    }

    public static func appID(from data: Data) -> String? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        var inEntry = false
        var result: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEntry = line == "[Desktop Entry]"; continue }
            guard inEntry, line.hasPrefix("X-Caboose-AppId="), result == nil else { continue }
            let value = String(line.dropFirst("X-Caboose-AppId=".count))
            guard value.hasSuffix(".desktop"), value.count <= 240, !value.contains("/"),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            result = value
        }
        return result
    }
}
