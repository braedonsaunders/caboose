import Foundation

/// One entry IDBFS wrote or removed in a save database, keyed by its absolute path in the
/// game's file system.
public struct GameSaveChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(Data)
        case directory
        case removed
    }

    public var path: String
    public var kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// What a `PUT /v1/fs/content` requires of the computer's copy.
public enum GamePrecondition: Equatable, Sendable {
    /// `If-None-Match: *`: the file must not exist yet.
    case create
    /// `If-Match`: the file must still be the version with this etag.
    case match(String)
}

/// One `/v1/fs` request that writes a save to the computer, all paths home-relative.
public enum GameSaveOperation: Equatable, Sendable {
    /// `POST /v1/fs/mkdir`; a directory that already exists is fine.
    case mkdir(String)
    /// `PUT /v1/fs/content`.
    case put(String, Data, GamePrecondition)
    /// `DELETE /v1/fs/item`, to the Trash, with `If-Match` when the file's etag is known.
    case delete(String, ifMatch: String?)
}

/// An operation and the change it carries out (`origin`, the game's path), so a batch that
/// fails partway can give back what it did not do.
public struct GameSaveStep: Equatable, Sendable {
    public var origin: String
    public var operation: GameSaveOperation

    public init(origin: String, operation: GameSaveOperation) {
        self.origin = origin
        self.operation = operation
    }
}

/// Turns a batch of IDBFS changes into the requests that write them to the computer.
public enum GameSavePlanner {
    /// - Parameters:
    ///   - changes: in the order the game made them; the last change to a path wins.
    ///   - etags: the etag last seen for each host file.
    ///   - directories: host directories known to exist; any other directory above a write is
    ///     made first, outermost first.
    /// Directories are made, then files written, then removals done deepest first; a removal
    /// inside a removed directory is left to the directory's.
    public static func plan(_ changes: [GameSaveChange], saves: [GameSave], etags: [String: String],
                            directories: Set<String>) -> [GameSaveStep] {
        var latest: [String: GameSaveChange] = [:]
        for change in changes {
            guard let host = GameFiles.hostPath(change.path, saves: saves) else { continue }
            latest[host] = change
        }
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        func outermostFirst(_ a: String, _ b: String) -> Bool { depth(a) != depth(b) ? depth(a) < depth(b) : a < b }

        var known = directories
        var steps: [GameSaveStep] = []
        func make(_ directory: String, for origin: String) {
            guard !known.contains(directory) else { return }
            known.insert(directory)
            steps.append(GameSaveStep(origin: origin, operation: .mkdir(directory)))
        }
        for host in latest.keys.sorted(by: outermostFirst) {
            guard let change = latest[host], change.kind == .directory else { continue }
            for ancestor in GameFiles.ancestors(of: host) { make(ancestor, for: change.path) }
            make(host, for: change.path)
        }
        for host in latest.keys.sorted(by: outermostFirst) {
            guard let change = latest[host], case .file(let data) = change.kind else { continue }
            for ancestor in GameFiles.ancestors(of: host) { make(ancestor, for: change.path) }
            steps.append(GameSaveStep(origin: change.path, operation: .put(host, data, etags[host].map(GamePrecondition.match) ?? .create)))
        }
        let removed = latest.filter { $0.value.kind == .removed }
        for host in removed.keys.sorted(by: outermostFirst).reversed() {
            guard let change = removed[host], !GameFiles.ancestors(of: host).contains(where: { removed[$0] != nil }) else { continue }
            steps.append(GameSaveStep(origin: change.path, operation: .delete(host, ifMatch: etags[host])))
        }
        return steps
    }
}
