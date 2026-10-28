import Foundation

public struct FileListingEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let mtime: Double
    public init(name: String, isDirectory: Bool, mtime: Double) {
        self.name = name; self.isDirectory = isDirectory; self.mtime = mtime
    }
}
public struct RecentFile: Equatable, Sendable {
    public let path: String
    public let mtime: Double
}
/// Walk a file-service tree without following links (the service filters those).
public enum RecentFiles {
    public static func scan(list: (String) async throws -> [FileListingEntry]) async throws -> [RecentFile] {
        var directories = [""]
        var files: [RecentFile] = []
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            for item in try await list(directory) {
                let path = directory.isEmpty ? item.name : directory + "/" + item.name
                if item.isDirectory { directories.append(path) }
                else { files.append(RecentFile(path: path, mtime: item.mtime)) }
            }
        }
        return files.sorted { $0.mtime == $1.mtime ? $0.path < $1.path : $0.mtime > $1.mtime }
    }
}
