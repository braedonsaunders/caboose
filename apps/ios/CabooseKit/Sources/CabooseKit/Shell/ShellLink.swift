import Foundation

/// The app's tabs. Terminal appears only once the app has a native terminal to show.
public enum ShellTab: String, CaseIterable, Hashable, Sendable {
    case home, desktop, agents, apps, terminal
}

/// A `caboose://` link the app's shell handles. Pairing links (`caboose://connect`) are
/// parsed by the app's credentials and are not shell links.
public enum ShellLink: Equatable, Sendable {
    /// `caboose://home`, `caboose://desktop`, `caboose://agents`, `caboose://apps`, `caboose://terminal`.
    case tab(ShellTab)
    /// `caboose://task/<id>`: an agent task.
    case task(String)
    /// `caboose://command/<id>`: a command run on the computer.
    case command(String)
    /// `caboose://airplay`: Home's AirPlay action.
    case airPlay

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "caboose", let host = url.host?.lowercased() else { return nil }
        switch host {
        case "task":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .task(id)
        case "command":
            guard let id = url.pathComponents.dropFirst().first, ComputerCommand.isValidID(id) else { return nil }
            self = .command(id)
        case "airplay":
            self = .airPlay
        default:
            guard let tab = ShellTab(rawValue: host) else { return nil }
            self = .tab(tab)
        }
    }
}
