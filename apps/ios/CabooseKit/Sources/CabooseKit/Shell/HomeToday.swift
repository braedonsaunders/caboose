import CoreGraphics
import Foundation

/// Home's Today: what came in while the owner was away, what Ask finds for what they type,
/// how big a window's live tile is, and where the shell's tabs sit.
public enum HomeToday {}

// MARK: Since you left

extension HomeToday {
    /// An agent task as Home needs it.
    public struct AgentTask: Sendable {
        public let id: String
        public let title: String
        public let agent: String
        /// The host's status: `running`, `paused`, `succeeded`, `failed` or `cancelled`.
        public let status: String
        public let finishedAt: Date?
        public let summary: String?

        public init(id: String, title: String, agent: String, status: String, finishedAt: Date?, summary: String?) {
            self.id = id
            self.title = title
            self.agent = agent
            self.status = status
            self.finishedAt = finishedAt
            self.summary = summary
        }
    }

    /// Something that finished or changed while the owner was away.
    public struct Arrival: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case agentSucceeded
            case agentFailed
            case file
        }

        /// The task's id, or the file's path.
        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let date: Date
    }

    /// Agent turns that ended and files that changed after `since`, newest first, at most
    /// `limit`, with no more than `fileLimit` of them files so a busy folder cannot bury
    /// the agents' work. A cancelled turn is left out: the owner stopped it.
    public static func arrivals(tasks: [AgentTask], files: [RecentFile], since: Date,
                                limit: Int, fileLimit: Int = 3) -> [Arrival] {
        var arrivals: [Arrival] = []
        for task in tasks {
            guard let date = task.finishedAt, date > since else { continue }
            let kind: Arrival.Kind
            switch task.status {
            case "succeeded": kind = .agentSucceeded
            case "failed": kind = .agentFailed
            default: continue
            }
            arrivals.append(Arrival(id: task.id, kind: kind, title: task.title,
                                    detail: firstLine(task.summary) ?? task.agent, date: date))
        }
        let changed = RecentFiles.visible(files, limit: files.count).lazy
            .map { ($0, Date(timeIntervalSince1970: $0.mtime / 1000)) }
            .filter { $0.1 > since }
            .prefix(fileLimit)
        for (file, date) in changed {
            let name = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            arrivals.append(Arrival(id: file.path, kind: .file, title: name,
                                    detail: folder.isEmpty ? "Home" : folder, date: date))
        }
        return Array(arrivals.sorted { $0.date > $1.date }.prefix(limit))
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line
    }
}

// MARK: Ask

extension HomeToday {
    /// Something Ask can open: a window, an app or a file.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public enum Kind: Int, Comparable, Sendable {
            case window, app, file
            public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }

        public let kind: Kind
        /// The window's id, the app's desktop id, or the file's path.
        public let key: String
        public let title: String
        public let subtitle: String
        public var id: String { "\(kind.rawValue):\(key)" }

        public init(kind: Kind, key: String, title: String, subtitle: String) {
            self.kind = kind
            self.key = key
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// The candidates matching `query`, best first, at most `limit`. Every word of the query
    /// must start a word of the title or subtitle, ignoring case and accents. A title that
    /// starts with the query ranks first, then one where every word is in the title; within
    /// a rank, open windows come before apps and apps before files, each in the order given.
    public static func find(_ query: String, in candidates: [Candidate], limit: Int) -> [Candidate] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        let phrase = terms.joined(separator: " ")
        var scored: [(score: Int, index: Int, candidate: Candidate)] = []
        for (index, candidate) in candidates.enumerated() {
            let title = words(candidate.title)
            let all = title + words(candidate.subtitle)
            guard terms.allSatisfy({ term in all.contains { $0.hasPrefix(term) } }) else { continue }
            let score: Int
            if title.joined(separator: " ").hasPrefix(phrase) { score = 0 }
            else if terms.allSatisfy({ term in title.contains { $0.hasPrefix(term) } }) { score = 1 }
            else { score = 2 }
            scored.append((score, index, candidate))
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.candidate.kind != $1.candidate.kind { return $0.candidate.kind < $1.candidate.kind }
            return $0.index < $1.index
        }
        .prefix(limit)
        .map(\.candidate)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

// MARK: Layout

extension HomeToday {
    /// A live window's tile on Home at `height`: the window's own shape, kept between a
    /// tall portrait and a wide landscape so a strip of them reads as one row.
    public static func tileSize(window: CGSize, height: CGFloat) -> CGSize {
        guard window.width > 0, window.height > 0 else { return CGSize(width: height * 0.75, height: height) }
        let aspect = min(max(window.width / window.height, 0.62), 1.5)
        return CGSize(width: (height * aspect).rounded(), height: height)
    }

    /// Where the shell's tabs sit.
    public enum TabPlacement: Equatable, Sendable {
        /// The system's own: its vertical bar on the side (iPhone Duo), or iPad's tab bar.
        case system
        /// A short cluster at the bottom right, beside the tab's own control at the bottom.
        case cluster
        /// A sidebar down the trailing edge with the tabs at its foot.
        case sidebar
    }

    /// The system keeps its placement where it draws a vertical bar, and on iPad. An iPhone
    /// whose bars are horizontal puts the tabs at the bottom right: a cluster when held
    /// upright, a sidebar once the screen is wide enough to give one up (`sidebarWidth`),
    /// as on a Duo opened out or any phone on its side.
    public static func tabPlacement(isPhone: Bool, hasVerticalBar: Bool, width: CGFloat,
                                    sidebarWidth: CGFloat = 600) -> TabPlacement {
        guard isPhone, !hasVerticalBar else { return .system }
        return width >= sidebarWidth ? .sidebar : .cluster
    }
}
