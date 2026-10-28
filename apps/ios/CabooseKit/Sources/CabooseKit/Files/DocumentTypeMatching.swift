import Foundation

public enum DocumentTypeMatching {
    public static func matches(filename: String, typeIdentifier: String?, extensions: [String], typeIdentifiers: [String]) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty && extensions.contains(where: { $0.lowercased() == ext }) { return true }
        guard let typeIdentifier, !typeIdentifier.isEmpty else { return false }
        return typeIdentifiers.contains { $0.caseInsensitiveCompare(typeIdentifier) == .orderedSame }
    }
}
