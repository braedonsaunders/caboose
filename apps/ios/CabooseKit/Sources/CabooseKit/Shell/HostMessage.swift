import Foundation

/// A message from the host (a component update's failure, `lastError`) made fit to show: a
/// line repeated many times appears once, and the whole is held to a few lines and a few
/// hundred characters. The host's own text is never shown as a wall.
public enum HostMessage {
    public static func clipped(_ raw: String, maxLines: Int = 4, maxCharacters: Int = 280) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            lines.append(text)
        }
        var clipped = lines.prefix(maxLines).joined(separator: "\n")
        if clipped.count > maxCharacters {
            clipped = String(clipped.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
        } else if lines.count > maxLines {
            clipped += "…"
        }
        return clipped
    }

    /// The one-line, plain-language status for a component update's state.
    public static func upgradeStatus(_ state: String) -> String? {
        switch state {
        case "checking": "Checking for Updates"
        case "updating": "Updating"
        case "failed": "Update Failed"
        default: nil
        }
    }
}
