import Foundation
import UniformTypeIdentifiers

/// A Linux application asking the phone to choose a file (docs/native-bridge.md § File
/// chooser), validated as strictly as the host does: the guest is not trusted.
public struct BridgeRequest: Equatable, Decodable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case open = "file.open", save = "file.save" }

    public struct Filter: Equatable, Decodable, Sendable {
        public let name: String
        public let patterns: [String]
        public let mimeTypes: [String]

        public init(name: String, patterns: [String], mimeTypes: [String]) {
            self.name = name; self.patterns = patterns; self.mimeTypes = mimeTypes
        }

        /// The extensions its `*.ext` patterns name, lowercased, in order.
        public var extensions: [String] {
            var seen = Set<String>()
            return patterns.compactMap { pattern in
                guard pattern.hasPrefix("*."), pattern.count > 2 else { return nil }
                let ext = String(pattern.dropFirst(2)).lowercased()
                guard !ext.contains(where: { "*?[]/".contains($0) }), seen.insert(ext).inserted else { return nil }
                return ext
            }
        }

        /// The types iOS can offer for it; empty when nothing resolves (every pattern a
        /// wildcard, or types iOS does not know).
        public var contentTypes: [UTType] {
            var types: [UTType] = []
            for mime in mimeTypes {
                if mime == "*/*" { return [] }
                if mime.hasSuffix("/*"), let family = Self.family(String(mime.dropLast(2))) { types.append(family); continue }
                if let type = UTType(mimeType: mime) { types.append(type) }
            }
            for ext in extensions { if let type = UTType(filenameExtension: ext) { types.append(type) } }
            // A dynamic type is one iOS made up for an unknown tag: no file conforms to it.
            var seen = Set<String>()
            return types.filter { !$0.isDynamic && seen.insert($0.identifier).inserted }
        }

        private static func family(_ prefix: String) -> UTType? {
            switch prefix {
            case "image": .image
            case "audio": .audio
            case "video": .movie
            case "text": .text
            case "font": .font
            default: nil
            }
        }
    }

    public let id: String
    public let type: Kind
    public let app: String
    public let title: String
    public let acceptLabel: String
    public let multiple: Bool
    public let directory: Bool
    public let filters: [Filter]
    public let currentFilter: Int?
    public let currentName: String
    public let currentFolder: String
    public let created: Int

    private enum Keys: String, CodingKey {
        case id, type, app, title, acceptLabel, multiple, directory, filters, currentFilter, currentName, currentFolder, created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(Kind.self, forKey: .type)
        app = try c.decode(String.self, forKey: .app)
        title = try c.decode(String.self, forKey: .title)
        acceptLabel = try c.decode(String.self, forKey: .acceptLabel)
        multiple = try c.decode(Bool.self, forKey: .multiple)
        directory = try c.decode(Bool.self, forKey: .directory)
        filters = try c.decode([Filter].self, forKey: .filters)
        currentFilter = try c.decodeIfPresent(Int.self, forKey: .currentFilter)
        currentName = try c.decode(String.self, forKey: .currentName)
        currentFolder = try c.decode(String.self, forKey: .currentFolder)
        created = try c.decode(Int.self, forKey: .created)
        guard Self.valid(self) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid bridge request"))
        }
    }

    private static func valid(_ r: BridgeRequest) -> Bool {
        let hex = r.id.utf8.count == 32 && r.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        guard hex, plain(r.app, 200), plain(r.title, 200), plain(r.acceptLabel, 64) else { return false }
        if r.type == .save && (r.multiple || r.directory) { return false }
        guard r.filters.count <= 32, r.filters.allSatisfy({ f in
            plain(f.name, 100) && f.patterns.count <= 32 && f.mimeTypes.count <= 32
                && f.patterns.allSatisfy { !$0.isEmpty && plain($0, 255) } && f.mimeTypes.allSatisfy { plain($0, 255) && $0.contains("/") }
        }) else { return false }
        if let index = r.currentFilter, !r.filters.indices.contains(index) { return false }
        guard plain(r.currentName, 255), r.currentName.utf8.count <= 255 else { return false }
        if r.type == .open ? !r.currentName.isEmpty : (r.currentName.contains("/") || r.currentName == "." || r.currentName == "..") { return false }
        guard r.currentFolder.isEmpty || ComputerPath(absolute: r.currentFolder) != nil else { return false }
        return r.created >= 0
    }

    /// The application's name for people: its id's last component ("org.libreoffice.LibreOffice" → "LibreOffice").
    public var appName: String? {
        guard !app.isEmpty else { return nil }
        let last = app.split(separator: ".").last.map(String.init) ?? app
        return last.isEmpty ? nil : last
    }

    /// What the picker may offer: the current filter's types, else every filter's, else nothing (any item).
    public var contentTypes: [UTType] {
        if let index = currentFilter { return filters[index].contentTypes }
        var seen = Set<String>()
        return filters.flatMap(\.contentTypes).filter { seen.insert($0.identifier).inserted }
    }

    /// The folder to start in: the application's, else Documents.
    public var startFolder: ComputerPath {
        ComputerPath(absolute: currentFolder) ?? ComputerPath(relative: "Documents") ?? .home
    }
}

private func plain(_ value: String, _ limit: Int) -> Bool {
    value.count <= limit && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

/// A path in the computer's home, as the host's `/v1/fs` routes take it (relative) and as
/// the portal answers (absolute, under `/home/caboose`).
public struct ComputerPath: Hashable, Sendable, CustomStringConvertible {
    public static let homeDirectory = "/home/caboose"
    public static let home = ComputerPath(components: [])

    /// The path's segments below the home; empty for the home itself.
    public let components: [String]

    private init(components: [String]) { self.components = components }

    /// A home-relative path ("" is the home), or nil if it is not one: empty, `.` or `..`
    /// segments, control characters.
    public init?(relative: String) {
        if relative.isEmpty { self.init(components: []); return }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(Self.segment) else { return nil }
        self.init(components: parts)
    }

    /// An absolute path under `/home/caboose` (the home itself included), as the host checks it.
    public init?(absolute: String) {
        guard absolute.utf8.count <= 4096 else { return nil }
        if absolute == Self.homeDirectory { self.init(components: []); return }
        guard absolute.hasPrefix(Self.homeDirectory + "/") else { return nil }
        self.init(relative: String(absolute.dropFirst(Self.homeDirectory.count + 1)))
    }

    static func segment(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && !part.contains("/")
            && !part.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    public var relative: String { components.joined(separator: "/") }
    public var absolute: String { components.isEmpty ? Self.homeDirectory : Self.homeDirectory + "/" + relative }
    public var name: String { components.last ?? "Home" }
    public var parent: ComputerPath? { components.isEmpty ? nil : ComputerPath(components: Array(components.dropLast())) }
    public var description: String { absolute }

    /// A child of this folder, or nil for a name that is not one segment.
    public func appending(_ name: String) -> ComputerPath? {
        Self.segment(name) ? ComputerPath(components: components + [name]) : nil
    }

    /// The breadcrumb from the home to this path, inclusive.
    public var ancestry: [ComputerPath] {
        (0...components.count).map { ComputerPath(components: Array(components.prefix($0))) }
    }
}

/// The phone's answer to a request, as `POST /v1/bridge/requests/:id` takes it.
public enum BridgeAnswer: Equatable, Sendable, Encodable {
    case chose([ComputerPath], filter: Int?)
    case cancel
    case computer

    private enum Keys: String, CodingKey { case response, paths, filter }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .chose(let paths, let filter):
            try c.encode("ok", forKey: .response)
            try c.encode(paths.map(\.absolute), forKey: .paths)
            if let filter { try c.encode(filter, forKey: .filter) }
        case .cancel: try c.encode("cancel", forKey: .response)
        case .computer: try c.encode("computer", forKey: .response)
        }
    }
}

/// File names in the save sheet.
public enum SaveName {
    /// Whether `name` can be saved as one file in a folder.
    public static func valid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed == name && ComputerPath.segment(name) && name.utf8.count <= 255
    }

    /// `name` with the extension the chosen filter asks for: kept when it already is one of
    /// the filter's, else replaced (or added) with the filter's first.
    public static func applying(_ filter: BridgeRequest.Filter?, to name: String) -> String {
        guard let filter, let first = filter.extensions.first else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        if filter.extensions.contains(ext) { return name }
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        return base.isEmpty ? name : base + "." + first
    }

    /// The range of the name to select for editing: its base, before the extension.
    public static func baseRange(of name: String) -> Range<String.Index> {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return name.startIndex..<name.endIndex }
        return name.startIndex..<name.index(name.endIndex, offsetBy: -(ext.count + 1))
    }
}
