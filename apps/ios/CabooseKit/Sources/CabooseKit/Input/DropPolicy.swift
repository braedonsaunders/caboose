import Foundation
import UniformTypeIdentifiers

/// Chooses one representation per dropped or pasted item, preferring real files and
/// images over text, and the clipboard types a drop offers the computer.
public enum DropPolicy {
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

    /// The clipboard types a drop offers the computer, from each dragged item's type
    /// identifiers: text as text; a single image as PNG (when it is one) or JPEG, and as a
    /// file; everything else that is data as files. The phone delivers exactly these.
    public static func dropTypes(for items: [[String]]) -> [String] {
        dropTypes(for: items) { identifier, parent in
            guard let type = UTType(identifier), let supertype = UTType(parent) else { return false }
            return type.conforms(to: supertype)
        }
    }

    static func dropTypes(for items: [[String]], conforms: (String, String) -> Bool) -> [String] {
        var text = false, files = false
        var images: [String] = []
        for identifiers in items {
            switch representation(for: identifiers, conforms: conforms) {
            case .text: text = true
            case .file(let type) where conforms(type, UTType.image.identifier):
                images.append(conforms(type, UTType.png.identifier) ? ClipboardPolicy.png : ClipboardPolicy.jpeg)
                files = true
            case .file, .fileURL: files = true
            case nil: continue
            }
        }
        var types: [String] = []
        if text { types.append(ClipboardPolicy.text) }
        if images.count == 1 { types.append(images[0]) }
        if files { types.append(ClipboardPolicy.uriList) }
        return types
    }
}
