import Foundation

/// Transform a provider's path-to-identifier map when a directory moves or is deleted.
public enum FilePathIndex {
    public static func moving(_ entries: [String: String], from old: String, to new: String) -> [String: String] {
        var result = entries
        let moved = entries.filter { $0.key == old || $0.key.hasPrefix(old + "/") }
        for path in moved.keys { result.removeValue(forKey: path) }
        for (path, identifier) in moved { result[new + path.dropFirst(old.count)] = identifier }
        return result
    }
    public static func removing(_ entries: [String: String], path: String) -> (remaining: [String: String], removed: [String]) {
        var result = entries
        let removed = entries.filter { $0.key == path || $0.key.hasPrefix(path + "/") }
        for path in removed.keys { result.removeValue(forKey: path) }
        return (result, Array(removed.values))
    }
}
