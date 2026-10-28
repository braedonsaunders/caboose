import Foundation
import UniformTypeIdentifiers

/// Chooses one representation per dropped item, preferring real files and images over text.
public enum DropPolicy {
    public static let maxFileBytes = 50 * 1024 * 1024
    public enum Representation: Equatable {
        case fileURL
        case file(String)
        case text
    }
    public static func representation(for identifiers: [String]) -> Representation? {
        representation(for: identifiers) { identifier, parent in
            guard let type = UTType(identifier), let supertype = UTType(parent) else { return false }
            return type.conforms(to: supertype)
        }
    }
    static func representation(for identifiers: [String], conforms: (String, String) -> Bool) -> Representation? {
        if identifiers.contains(where: { conforms($0, UTType.fileURL.identifier) }) { return .fileURL }
        if let image = identifiers.first(where: { conforms($0, UTType.image.identifier) }) { return .file(image) }
        if identifiers.contains(where: { conforms($0, UTType.plainText.identifier) }) { return .text }
        if let file = identifiers.first(where: { conforms($0, UTType.data.identifier) && !conforms($0, UTType.url.identifier) }) {
            return .file(file)
        }
        return nil
    }
}
