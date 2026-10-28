import Foundation

/// Construct a home-relative create destination from a folder and one filename.
public enum ShortcutPath {
    public static func destination(folder: String, filename: String) -> String? {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\0"),
              !folder.hasPrefix("/"), !folder.contains("\0") else { return nil }
        let parts = folder.isEmpty ? [] : folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return (parts + [filename]).joined(separator: "/")
    }
}
