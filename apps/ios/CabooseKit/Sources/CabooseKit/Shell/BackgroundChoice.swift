import Foundation

/// What lies behind the app's tabs and the computer's desktop, on the phone and on a TV alike:
/// one choice for both, so the app and the desktop are one surface.
public enum BackgroundChoice: Codable, Equatable, Hashable, Sendable {
    /// The brand gradient.
    case gradient
    /// Photographs from the library, a new one every quarter hour.
    case rotating
    /// One photograph from the library, by its id, until the owner picks another.
    case photo(Int)
    /// The owner's own picture, kept on the phone.
    case custom

    /// Shows a photograph rather than the gradient.
    public var showsPhotograph: Bool { self != .gradient }

    /// Shows the library's photographs, so there is a next one to move to.
    public var usesLibrary: Bool {
        switch self {
        case .rotating, .photo: true
        case .gradient, .custom: false
        }
    }

    /// Changes photograph on its own every `rotationInterval`.
    public var rotates: Bool { self == .rotating }

    public static let rotationInterval: TimeInterval = 15 * 60

    /// The library photograph to show: the fixed one, else the current one while rotating,
    /// else nil (gradient, or the owner's own picture).
    public func libraryPhoto(current: Int?) -> Int? {
        switch self {
        case .photo(let id): id
        case .rotating: current
        case .gradient, .custom: nil
        }
    }

    /// What the desktop's "next photograph" control does: a rotating background moves on, a
    /// fixed one becomes the next photograph, and the gradient or the owner's picture start
    /// rotating.
    public func next(choosing id: Int) -> BackgroundChoice {
        switch self {
        case .photo: .photo(id)
        case .rotating, .gradient, .custom: .rotating
        }
    }
}
