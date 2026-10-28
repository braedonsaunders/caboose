import Foundation

/// A validated handoff from the authenticated owner's computer.
public enum PhoneEvent: Equatable, Decodable {
    case open(URL)
    case share(File)
    case print(File)

    public struct File: Equatable, Decodable {
        public let id: String
        public let path: String
        public let name: String
        public let size: Int
        public let contentType: String
    }

    private enum Keys: String, CodingKey { case type, url }
    public static let maxFileBytes = 10 * 1024 * 1024
    private static let schemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "geo"]

    public static func allowedURL(_ url: URL) -> Bool {
        let value = url.absoluteString
        return value.utf8.count <= 8192 && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
            && schemes.contains(url.scheme?.lowercased() ?? "")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .type)
        if kind == "phone.open" {
            let raw = try c.decode(String.self, forKey: .url)
            guard let url = URL(string: raw), Self.allowedURL(url) else { throw invalid(decoder) }
            self = .open(url)
            return
        }
        guard kind == "phone.share" || kind == "phone.print" else { throw invalid(decoder) }
        let file = try File(from: decoder)
        let idValid = file.id.utf8.count == 32 && file.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        let safeName = !file.name.isEmpty && file.name != "." && file.name != ".." && file.name.count <= 200 && !file.name.unicodeScalars.contains {
            $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\"
        }
        guard idValid, file.path == "/home/caboose/.cache/caboose/phone/files/\(file.id)", safeName,
              (0...Self.maxFileBytes).contains(file.size), !file.contentType.isEmpty,
              kind != "phone.print" || file.contentType == "application/pdf" else { throw invalid(decoder) }
        self = kind == "phone.share" ? .share(file) : .print(file)
    }
}

private func invalid(_ decoder: Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid phone handoff"))
}
