import Foundation

/// Block structure for native chat rendering. Inline styles and links stay in the block text.
/// An unfinished fence remains code while an answer is streaming.
public enum ChatMarkdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(Int, String)
        case code(language: String, text: String)
        case html(String)
        case image(alt: String, destination: String)
        case quote(String)
        case list(marker: String, text: String)
        case divider
    }

    private static func standaloneImage(_ line: String) -> Block? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^\s]+)\)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let alt = Range(match.range(at: 1), in: line), let destination = Range(match.range(at: 2), in: line) else { return nil }
        return .image(alt: String(line[alt]), destination: String(line[destination]))
    }

    public static func blocks(_ source: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var language = ""
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let opening = fence {
                if trimmed.hasPrefix(opening), trimmed.dropFirst(opening.count).allSatisfy({ $0 == opening.first || $0.isWhitespace }) {
                    let contents = code.joined(separator: "\n")
                    if ["html", "inline-html"].contains(language.lowercased()), contents.utf8.count <= ChatArtifactPolicy.maximumHTMLBytes {
                        result.append(.html(contents))
                    } else { result.append(.code(language: language, text: contents)) }
                    code = []; fence = nil
                } else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = trimmed.first!
                let count = trimmed.prefix(while: { $0 == marker }).count
                fence = String(repeating: String(marker), count: count)
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
            } else if let image = standaloneImage(trimmed) {
                flush(); result.append(image)
            } else if trimmed.isEmpty {
                flush()
            } else if ["---", "***", "___"].contains(trimmed) {
                flush(); result.append(.divider)
            } else if trimmed.first == "#", let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }), trimmed.distance(from: trimmed.startIndex, to: space) <= 6 {
                flush(); result.append(.heading(trimmed.distance(from: trimmed.startIndex, to: space), String(trimmed[trimmed.index(after: space)...])))
            } else if trimmed.hasPrefix("> ") {
                flush(); result.append(.quote(String(trimmed.dropFirst(2))))
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                flush(); result.append(.list(marker: "•", text: String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); result.append(.list(marker: String(trimmed[range]).trimmingCharacters(in: .whitespaces), text: String(trimmed[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flush()
        if fence != nil { result.append(.code(language: language, text: code.joined(separator: "\n"))) }
        return result
    }
}

/// A replaceable snapshot of the message still being generated, never a transcript entry.
public struct AgentDraft: Decodable, Equatable, Sendable {
    public let turn: Int
    public let kind: String
    public let text: String

    public init(turn: Int, kind: String, text: String) { self.turn = turn; self.kind = kind; self.text = text }
}
