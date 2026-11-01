import Foundation

/// The computer's running applications, as a desktop shell's taskbar shows them: derived
/// from the windows that exist, however they were started (a dock launch, Steam, a
/// terminal, a script, a child process, Wine). Every top-level window belongs to exactly
/// one group. A group is a desktop entry the window matches, or, for a window no entry
/// claims, an application of its own named and drawn from its windows. A group lasts as
/// long as one of its windows: closing the last ends it; a minimized window still counts.
public struct Taskbar: Equatable, Sendable {
    /// An installed desktop entry.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var name: String
        public var startupWMClass: String?
        public var exec: String

        public init(id: String, name: String, startupWMClass: String? = nil, exec: String = "") {
            self.id = id
            self.name = name
            self.startupWMClass = startupWMClass
            self.exec = exec
        }
    }

    /// A top-level window, as the computer announced it.
    public struct Window: Equatable, Sendable {
        public var id: Int
        public var title: String
        /// Wayland's app_id, or X11's WM_CLASS (instance and class).
        public var instance: String?
        public var name: String?
        /// The desktop entry whose launch started the window's process.
        public var desktopID: String?
        public var pid: Int?

        public init(id: Int, title: String = "", instance: String? = nil, name: String? = nil, desktopID: String? = nil, pid: Int? = nil) {
            self.id = id
            self.title = title
            self.instance = instance
            self.name = name
            self.desktopID = desktopID
            self.pid = pid
        }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        /// The entry's id, or, for windows no entry claims, `window:` and what groups them.
        public var id: String
        /// The desktop entry the windows belong to; nil for an application of its own.
        public var entryID: String?
        /// The entry's name, or what the windows call their application.
        public var name: String
        /// Window ids, in the order they opened.
        public var windows: [Int]
    }

    /// Prefixes the id of a group no desktop entry claims.
    public static let unlistedPrefix = "window:"

    /// In the order the applications opened their first window.
    public private(set) var groups: [Group] = []
    private var byWindow: [Int: Int] = [:]

    public init() {}

    public init(windows: [Window], entries: [Entry]) {
        let windows = windows.sorted { $0.id < $1.id }
        var owner: [Int: String] = [:]
        for window in windows {
            if let index = Self.entry(for: window, among: entries) { owner[window.id] = entries[index].id }
        }
        // A window no entry claims belongs with another of its process that one does, as a
        // splash screen or a second window with its own class does.
        var byProcess: [Int: String] = [:]
        for window in windows {
            if let pid = window.pid, let id = owner[window.id], byProcess[pid] == nil { byProcess[pid] = id }
        }
        var order: [String] = []
        var members: [String: [Window]] = [:]
        for window in windows {
            let key = owner[window.id] ?? window.pid.flatMap { byProcess[$0] } ?? Self.unlistedKey(window)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(window)
        }
        for key in order {
            let windows = members[key] ?? []
            let entry = entries.first { $0.id == key }
            let name = entry?.name ?? Self.unlistedName(windows)
            byWindow.merge(windows.map { ($0.id, groups.count) }) { $1 }
            groups.append(Group(id: key, entryID: entry?.id, name: name, windows: windows.map(\.id)))
        }
    }

    /// The group a window belongs to.
    public func group(of window: Int) -> Group? { byWindow[window].map { groups[$0] } }

    public func group(id: String) -> Group? { groups.first { $0.id == id } }

    // MARK: Matching

    /// The entry a window belongs to, as GNOME's and KDE's window trackers decide: the
    /// entry it was launched from; one declaring its class (`StartupWMClass`); one whose
    /// id is its class; for a Steam game (`steam_app_<id>`), the entry Steam made to run
    /// it; one whose program is named as its class; then one whose id ends with the class
    /// or the class with the id. The earliest entry wins a tie.
    public static func entry(for window: Window, among entries: [Entry]) -> Int? {
        if let launched = window.desktopID?.lowercased(), let index = entries.firstIndex(where: { $0.id.lowercased() == launched }) {
            return index
        }
        let names = [window.instance, window.name].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let game = names.lazy.compactMap(steamGame).first
        var best: (rank: Int, index: Int)?
        for (index, entry) in entries.enumerated() {
            guard let rank = rank(entry, names: names, steamGame: game), rank < (best?.rank ?? .max) else { continue }
            best = (rank, index)
            if rank == 0 { break }
        }
        return best?.index
    }

    private static func rank(_ entry: Entry, names: [String], steamGame: String?) -> Int? {
        if let declared = entry.startupWMClass?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !declared.isEmpty, names.contains(declared) { return 0 }
        let id = stem(entry.id)
        guard !id.isEmpty else { return nil }
        if names.contains(id) { return 1 }
        if let steamGame, launchesSteamGame(entry.exec, steamGame) { return 2 }
        if let program = program(entry.exec), names.contains(program) { return 3 }
        if names.contains(where: { id.hasSuffix($0) || $0.hasSuffix(id) }) { return 4 }
        return nil
    }

    private static func stem(_ id: String) -> String {
        let lowered = id.lowercased()
        return lowered.hasSuffix(".desktop") ? String(lowered.dropLast(8)) : lowered
    }

    /// The Steam app id in a Proton or Steam game's class, `steam_app_<id>`.
    static func steamGame(_ name: String) -> String? {
        guard name.hasPrefix("steam_app_") else { return nil }
        let id = name.dropFirst("steam_app_".count)
        return !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber } ? String(id) : nil
    }

    /// Whether an Exec line runs the Steam game `id` (`steam steam://rungameid/<id>`, as the
    /// entries Steam writes do, through Flatpak or not).
    static func launchesSteamGame(_ exec: String, _ id: String) -> Bool {
        var rest = exec[...]
        while let range = rest.range(of: "steam://rungameid/") {
            let after = rest[range.upperBound...]
            if after.hasPrefix(id), after.dropFirst(id.count).first.map { $0.isASCII && $0.isNumber } != true { return true }
            rest = after
        }
        return false
    }

    /// The program an Exec line runs, lowercased, without its directory: past `env` and its
    /// assignments, and for `flatpak run`, the application it runs.
    static func program(_ exec: String) -> String? {
        var words = exec.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }[...]
        func base(_ word: String) -> String { (word.split(separator: "/").last.map(String.init) ?? word).lowercased() }
        if words.first.map(base) == "env" {
            words = words.dropFirst()
            while let word = words.first, word.contains("=") || word.hasPrefix("-") {
                words = words.dropFirst(word == "-u" || word == "--unset" ? 2 : 1)
            }
        }
        guard let first = words.first else { return nil }
        if base(first) == "flatpak", words.dropFirst().first == "run" {
            return words.dropFirst(2).first { !$0.hasPrefix("-") }?.lowercased()
        }
        let program = base(first)
        return program.isEmpty ? nil : program
    }

    // MARK: Applications of their own

    private static func unlistedKey(_ window: Window) -> String {
        if let name = [window.name, window.instance].compactMap({ $0?.lowercased() }).first(where: { !$0.isEmpty }) {
            return unlistedPrefix + "class:" + name
        }
        if let pid = window.pid { return unlistedPrefix + "pid:\(pid)" }
        return unlistedPrefix + "id:\(window.id)"
    }

    /// The class names it, unless the class says nothing to a person (none, or a Steam
    /// game's number): then its first window's title does.
    private static func unlistedName(_ windows: [Window]) -> String {
        let title = windows.lazy.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let name = windows.first.flatMap { [$0.name, $0.instance].compactMap { $0 }.first { !$0.isEmpty } }
        if let name, steamGame(name.lowercased()) == nil { return name }
        return title ?? name ?? "Window"
    }
}

/// The dock's place for one kind of everyday app (a web browser, a file manager): the
/// first of `ids` installed, else the first app of `category`. An id names its entry exactly
/// (`thunar` is `thunar.desktop`), or a variant of it in the same category (`firefox-esr`
/// for a browser); never another app that merely shares its prefix, such as Thunar's Bulk
/// Rename (`thunar-bulk-rename`).
public enum DockSlot {
    public static func choose<App>(ids: [String], category: String, among apps: [App],
                                   id: (App) -> String, categories: (App) -> [String]) -> App? {
        func stem(_ app: App) -> String {
            let lowered = id(app).lowercased()
            return lowered.hasSuffix(".desktop") ? String(lowered.dropLast(8)) : lowered
        }
        func variant(_ app: App, of wanted: String) -> Bool {
            stem(app).hasPrefix(wanted + "-") && (category.isEmpty || categories(app).contains(category))
        }
        for wanted in ids {
            if let app = apps.first(where: { stem($0) == wanted }) ?? apps.first(where: { variant($0, of: wanted) }) {
                return app
            }
        }
        return category.isEmpty ? nil : apps.first { categories($0).contains(category) }
    }
}

/// Fits the dock's apps into `fit` places: an app with a window is never the one left
/// out; everyday apps without one give up their places, from the end, first.
public enum DockFit {
    public static func visible<T>(_ items: [T], fit: Int, isRunning: (T) -> Bool) -> [T] {
        guard items.count > fit else { return items }
        var keep = items.map(isRunning)
        var spare = fit - keep.count(where: { $0 })
        for (index, running) in keep.enumerated() where !running {
            keep[index] = spare > 0
            if spare > 0 { spare -= 1 }
        }
        let kept = zip(items, keep).filter(\.1).map(\.0)
        return Array(kept.prefix(max(fit, 0)))
    }
}
