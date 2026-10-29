import CryptoKit
import Foundation

/// How a handed-off game's URLs, files and saves map onto the computer's home: the pure rules
/// `CabooseGameSchemeHandler` and `GameSaveSync` follow (docs/game-handoff.md).
public enum GameFiles {
    /// Where `caboose-game://<id>/<path>` points under `root`.
    public enum Resolution: Equatable, Sendable {
        /// The home-relative path to serve.
        case file(String)
        /// A `..` that leaves `root`, or a NUL: answered 403.
        case forbidden
        /// Nothing to serve (the bare origin): answered 404.
        case notFound
    }

    /// Resolves a request's (percent-decoded) URL path against `root`, a home-relative
    /// directory. Empty and `.` components are dropped and `..` steps back, but never above `root`.
    public static func resolve(_ requestPath: String, root: String) -> Resolution {
        guard !requestPath.contains("\0") else { return .forbidden }
        var components: [Substring] = []
        for component in requestPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return .forbidden }
                components.removeLast()
            default: components.append(component)
            }
        }
        guard !components.isEmpty else { return .notFound }
        return .file(join(root, components.joined(separator: "/")))
    }

    /// Two home-relative paths joined, either of them possibly empty (the home itself).
    static func join(_ base: String, _ rest: String) -> String {
        let base = base.split(separator: "/").joined(separator: "/")
        let rest = rest.split(separator: "/").joined(separator: "/")
        if base.isEmpty { return rest }
        return rest.isEmpty ? base : base + "/" + rest
    }

    /// The `Content-Type` for a file by its extension: `application/wasm` for `.wasm`, so
    /// WebKit compiles it while it streams.
    public static func contentType(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "application/octet-stream" }
        return contentTypes[name[name.index(after: dot)...].lowercased()] ?? "application/octet-stream"
    }

    static let contentTypes: [String: String] = [
        "wasm": "application/wasm", "js": "text/javascript", "mjs": "text/javascript",
        "html": "text/html", "htm": "text/html", "css": "text/css", "json": "application/json",
        "txt": "text/plain", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "ico": "image/x-icon",
        "wav": "audio/wav", "ogg": "audio/ogg", "mp3": "audio/mpeg", "ttf": "font/ttf", "woff2": "font/woff2",
        "data": "application/octet-stream", "pck": "application/octet-stream", "wad": "application/octet-stream",
        "zip": "application/octet-stream", "bin": "application/octet-stream",
    ]

    /// The headers of every game response: cross-origin isolation, which threaded WebAssembly
    /// (`SharedArrayBuffer`) needs, the type from the extension, the length, and byte ranges.
    public static func responseHeaders(for path: String, length: Int?, contentRange: String? = nil) -> [String: String] {
        var headers = [
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "same-origin",
            "Content-Type": contentType(of: path),
            "Accept-Ranges": "bytes",
        ]
        if let length { headers["Content-Length"] = String(length) }
        if let contentRange { headers["Content-Range"] = contentRange }
        return headers
    }

    /// The name a file is kept under in the game cache: one computer's file at one version.
    /// `computer` is `GameHostAccess.computerKey`; the etag is the host's opaque, quoted one.
    public static func cacheKey(computer: String, path: String, etag: String) -> String {
        let digest = SHA256.hash(data: Data("\(computer)\u{0}\(path)\u{0}\(etag)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Where the device's version of a save goes when the computer's copy changed underneath
    /// it: `<name> (iPhone).<ext>` beside the original (`(iPad)` on an iPad). A leading dot
    /// is part of the name, not an extension.
    public static func conflictPath(_ path: String, device: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.popLast(), !name.isEmpty else { return path }
        let renamed: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            renamed = "\(name[..<dot]) (\(device))\(name[dot...])"
        } else {
            renamed = "\(name) (\(device))"
        }
        return (components + [renamed]).joined(separator: "/")
    }

    /// The computer's path for an absolute path of the game's file system, through the save
    /// whose mount holds it; nil outside every save, at a mount itself, or for a path with
    /// `.`, `..`, empty components or a NUL. The deepest mount wins.
    public static func hostPath(_ virtualPath: String, saves: [GameSave]) -> String? {
        guard virtualPath.hasPrefix("/"), !virtualPath.contains("\0") else { return nil }
        let components = virtualPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let save = saves.filter { virtualPath.hasPrefix(mountPrefix($0.mount)) }.max { $0.mount.count < $1.mount.count }
        guard let save else { return nil }
        return join(save.path, String(virtualPath.dropFirst(mountPrefix(save.mount).count)))
    }

    /// A save's host path back in the game's file system: `mount` joined with the path below `save.path`.
    static func virtualPath(_ hostPath: String, in save: GameSave) -> String? {
        let root = join(save.path, "")
        let rest: String
        if root.isEmpty { rest = hostPath } else {
            guard hostPath.hasPrefix(root + "/") else { return nil }
            rest = String(hostPath.dropFirst(root.count + 1))
        }
        guard !rest.isEmpty else { return nil }
        return mountPrefix(save.mount) + rest
    }

    /// A mount with one trailing slash: `/powder` → `/powder/`, `/` → `/`.
    static func mountPrefix(_ mount: String) -> String {
        mount.hasSuffix("/") ? mount : mount + "/"
    }

    /// Every directory above a home-relative path, outermost first: `a/b/c` → `a`, `a/b`.
    static func ancestors(of path: String) -> [String] {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return [] }
        return (1 ..< components.count).map { components[..<$0].joined(separator: "/") }
    }
}

/// A single `Range: bytes=…` request: `a-b`, `a-` or the suffix `-n`.
public enum GameByteRange: Equatable, Sendable {
    case from(Int, through: Int?)
    case suffix(Int)

    /// Nil for anything but one well-formed byte range, which is answered with the whole file.
    public init?(header: String) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces), last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        func number(_ text: String) -> Int? { text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) ? Int(text) : nil }
        if first.isEmpty {
            guard let count = number(last) else { return nil }
            self = .suffix(count)
        } else {
            guard let start = number(first) else { return nil }
            if last.isEmpty {
                self = .from(start, through: nil)
            } else {
                guard let end = number(last), end >= start else { return nil }
                self = .from(start, through: end)
            }
        }
    }

    /// The bytes of a `size`-byte file this asks for; nil when it cannot be satisfied (416).
    public func bytes(ofSize size: Int) -> ClosedRange<Int>? {
        guard size > 0 else { return nil }
        switch self {
        case .from(let start, let end):
            guard start < size else { return nil }
            return start ... min(end ?? size - 1, size - 1)
        case .suffix(let count):
            guard count > 0 else { return nil }
            return max(0, size - count) ... size - 1
        }
    }
}
