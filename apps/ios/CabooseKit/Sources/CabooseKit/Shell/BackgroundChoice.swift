import Foundation

/// What lies behind the app's tabs and the computer's desktop, on the phone and on a TV alike:
/// one choice for both, so the app and the desktop are one surface.
public enum BackgroundChoice: Codable, Equatable, Hashable, Sendable {
    /// The brand gradient.
    case gradient
    /// Wallpapers from the library, a new one every quarter hour.
    case rotating
    /// One wallpaper from the library, by its id, until the owner picks another.
    case photo(Int)
    /// The owner's own picture, kept on the phone.
    case custom

    /// Shows a picture rather than the gradient.
    public var showsPhotograph: Bool { self != .gradient }

    /// Shows the library's wallpapers, so there is a next one to move to.
    public var usesLibrary: Bool {
        switch self {
        case .rotating, .photo: true
        case .gradient, .custom: false
        }
    }

    /// Changes wallpaper on its own every `rotationInterval`.
    public var rotates: Bool { self == .rotating }

    public static let rotationInterval: TimeInterval = 15 * 60

    /// The library wallpaper to show: the fixed one, else the current one while rotating,
    /// else nil (gradient, or the owner's own picture).
    public func libraryPhoto(current: Int?) -> Int? {
        switch self {
        case .photo(let id): id
        case .rotating: current
        case .gradient, .custom: nil
        }
    }

    /// What the desktop's "next wallpaper" control does: a rotating background moves on, a
    /// fixed one becomes the next wallpaper, and the gradient or the owner's picture start
    /// rotating.
    public func next(choosing id: Int) -> BackgroundChoice {
        switch self {
        case .photo: .photo(id)
        case .rotating, .gradient, .custom: .rotating
        }
    }
}

/// One retained library picture. Its identity and bytes commit together; size-specific
/// render caches can disappear without losing the owner's background.
public struct BackgroundSnapshot: Codable, Equatable, Sendable {
    public let id: Int
    public let image: Data
    public static let maximumBytes = 12 * 1024 * 1024

    public init(id: Int, image: Data) { self.id = id; self.image = image }

    public func save(to file: URL) throws {
        guard !image.isEmpty, image.count <= Self.maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public static func load(from file: URL, choice: BackgroundChoice) -> Self? {
        guard choice.usesLibrary,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes + 4096,
              let data = try? Data(contentsOf: file),
              let saved = try? PropertyListDecoder().decode(Self.self, from: data),
              !saved.image.isEmpty, saved.image.count <= maximumBytes,
              choice.libraryPhoto(current: saved.id) == saved.id else { return nil }
        return saved
    }
}
