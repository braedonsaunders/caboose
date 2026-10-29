import Foundation

/// One representation of a copy: its MIME type and its bytes.
public struct ClipboardEntry: Sendable, Equatable {
    public let mime: String
    public let data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

/// One copy, as a `clipboard` message carries it (docs/display.md, Clipboard): its first
/// representation and the same content in other types.
public struct ClipboardContent: Sendable, Equatable {
    public let entries: [ClipboardEntry]

    /// Nil without entries: a copy always has a first representation.
    public init?(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    public func data(_ mime: String) -> Data? { entries.first { $0.mime == mime }?.data }

    public var text: String? { data(ClipboardPolicy.text).flatMap { String(data: $0, encoding: .utf8) } }

    /// The absolute paths of the files in the copy, if it has any.
    public var filePaths: [String]? { data(ClipboardPolicy.uriList).flatMap(ClipboardPolicy.filePaths) }

    public var totalBytes: Int { entries.reduce(0) { $0 + $1.data.count } }
}

/// The clipboard's types, limits and checks, the same as the compositor's
/// (guest/display/protocol/src/clipboard.rs).
public enum ClipboardPolicy {
    public static let text = "text/plain;charset=utf-8"
    public static let png = "image/png"
    public static let jpeg = "image/jpeg"
    public static let uriList = "text/uri-list"
    /// Every type a copy carries, in the order a sender lists them.
    public static let types = [text, png, jpeg, uriList]
    /// What this client takes from the computer besides text, sent in its hello.
    public static let clientTypes = [png, jpeg, uriList]

    /// The most one copy carries, every representation together.
    public static let maxBytes = 12 * 1024 * 1024
    public static let maxTextBytes = 1024 * 1024
    public static let maxURIListBytes = 256 * 1024
    public static let maxFiles = 64
    /// The computer's home; the host's `/v1/fs` routes reach only files under it.
    public static let home = "/home/caboose"

    public enum Refusal: Error, Equatable {
        case unknownType, duplicate, tooLarge, malformed
    }

    /// Whether `data` is what `mime` says it is.
    public static func check(_ mime: String, _ data: Data) -> Refusal? {
        switch mime {
        case text:
            if data.count > maxTextBytes { return .tooLarge }
            return String(data: data, encoding: .utf8) == nil ? .malformed : nil
        case png:
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ? nil : .malformed
        case jpeg:
            return data.starts(with: [0xFF, 0xD8, 0xFF]) ? nil : .malformed
        case uriList:
            if data.count > maxURIListBytes { return .tooLarge }
            return filePathsResult(data).refusal
        default:
            return .unknownType
        }
    }

    /// Checks a whole copy: known types, each once, each what it says, within `maxBytes`.
    public static func validate(_ content: ClipboardContent) -> Refusal? {
        if content.totalBytes > maxBytes { return .tooLarge }
        var seen = Set<String>()
        for entry in content.entries {
            guard seen.insert(entry.mime).inserted else { return .duplicate }
            if let refusal = check(entry.mime, entry.data) { return refusal }
        }
        return nil
    }

    /// The absolute paths of a `text/uri-list` of `file://` URIs, or nil if it is not one.
    public static func filePaths(_ data: Data) -> [String]? { filePathsResult(data).paths }

    private static func filePathsResult(_ data: Data) -> (paths: [String]?, refusal: Refusal?) {
        guard let list = String(data: data, encoding: .utf8) else { return (nil, .malformed) }
        var paths: [String] = []
        for raw in list.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.hasPrefix("file://") else { return (nil, .malformed) }
            var rest = line.dropFirst("file://".count)
            if rest.hasPrefix("localhost") { rest = rest.dropFirst("localhost".count) }
            guard rest.hasPrefix("/"), let decoded = percentDecode(String(rest)), !decoded.contains("\0") else {
                return (nil, .malformed)
            }
            paths.append(decoded)
            if paths.count > maxFiles { return (nil, .tooLarge) }
        }
        return paths.isEmpty ? (nil, .malformed) : (paths, nil)
    }

    /// A `text/uri-list` naming `paths`, each line ending in CRLF.
    public static func uriList(_ paths: [String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let lines = paths.map { "file://" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0) + "\r\n" }
        return Data(lines.joined().utf8)
    }

    /// The home-relative path of an absolute path on the computer, as `/v1/fs` takes it;
    /// nil outside the home or with `.` or `..` components.
    public static func homeRelative(_ path: String) -> String? {
        guard path.hasPrefix(home + "/") else { return nil }
        let relative = String(path.dropFirst(home.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return relative
    }

    /// A copy of the phone's clipboard: its text, then its image in the first of
    /// `images` (best first) that fits beside the text, then the files the phone uploaded.
    /// Nil if nothing fits.
    public static func content(text: String?, images: [ClipboardEntry] = [], files: [String] = []) -> ClipboardContent? {
        var entries: [ClipboardEntry] = []
        if let text, !text.isEmpty, let data = text.data(using: .utf8), data.count <= maxTextBytes {
            entries.append(ClipboardEntry(mime: self.text, data: data))
        }
        let list = files.isEmpty ? nil : uriList(Array(files.prefix(maxFiles)))
        let reserved = entries.reduce(0) { $0 + $1.data.count } + (list?.count ?? 0)
        if let image = images.first(where: { check($0.mime, $0.data) == nil && reserved + $0.data.count <= maxBytes }) {
            entries.append(image)
        }
        if let list, list.count <= maxURIListBytes { entries.append(ClipboardEntry(mime: uriList, data: list)) }
        return ClipboardContent(entries).flatMap { validate($0) == nil ? $0 : nil }
    }

    /// What this client keeps of a copy from the computer: the valid representations of
    /// the types it takes; nil if none is.
    public static func accepted(_ content: ClipboardContent) -> ClipboardContent? {
        guard content.totalBytes <= maxBytes else { return nil }
        var seen = Set<String>()
        return ClipboardContent(content.entries.filter { entry in
            (entry.mime == text || clientTypes.contains(entry.mime)) && seen.insert(entry.mime).inserted
                && check(entry.mime, entry.data) == nil
        })
    }

    private static func percentDecode(_ string: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(string.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
