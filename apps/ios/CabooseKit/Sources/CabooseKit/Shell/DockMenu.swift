/// What holding an app in a dock offers: Open, Pin or Unpin, and Close for each of its
/// windows, named by title (or the app's name for a window without one). Where windows can
/// have iPadOS windows of their own, each window also offers Open in New Window, or Move to
/// Desktop when it is already in one. Where the computer has app scopes (`TaskManager`), a
/// running app offers a single Quit, which escalates to Force Quit when the app does not end.
public enum DockMenu {
    /// What ending the app offers, from its running apps (`TaskManager.matching`).
    public struct Ending: Equatable, Sendable {
        /// Some window of it can be asked to close.
        public let canQuit: Bool
        /// It runs: its processes can be ended.
        public let canForceQuit: Bool

        public init(canQuit: Bool, canForceQuit: Bool) {
            self.canQuit = canQuit
            self.canForceQuit = canForceQuit
        }

        /// From the app's running apps; nil when it has none.
        public init?(_ running: [RunningApp]) {
            let ending = running.filter(\.canEnd)
            guard !ending.isEmpty else { return nil }
            self.init(canQuit: ending.contains(where: \.canQuit), canForceQuit: true)
        }
    }

    public struct Window: Equatable, Sendable {
        public let id: Int
        public let title: String
        /// Shown in an iPadOS window of its own.
        public let detached: Bool

        public init(id: Int, title: String, detached: Bool = false) {
            self.id = id
            self.title = title
            self.detached = detached
        }
    }

    public enum Action: Equatable, Sendable {
        /// Goes to the app's window, or opens the app when it has none.
        case open
        case pin
        case unpin
        case openInNewWindow(window: Int, title: String)
        case moveToDesktop(window: Int, title: String)
        case close(window: Int, title: String)
        /// Asks every window of the app to close.
        case quit
        /// Ends every process of the app, after the owner confirms.
        case forceQuit

        public var title: String {
            switch self {
            case .open: "Open"
            case .pin: "Pin"
            case .unpin: "Unpin"
            case .openInNewWindow(_, let title): "Open \(title) in New Window"
            case .moveToDesktop(_, let title): "Move \(title) to Desktop"
            case .close(_, let title): "Close \(title)"
            case .quit: "Quit"
            case .forceQuit: "Force Quit…"
            }
        }
    }

    /// `pinnable` is false for an application only its windows make, which no desktop entry
    /// names: it has nothing to keep once they close. `ending` adds Quit and Force Quit.
    public static func actions(appName: String, pinned: Bool, pinnable: Bool = true, windows: [Window], windowScenes: Bool = false,
                               ending: Ending? = nil) -> [Action] {
        var actions: [Action] = pinnable ? [.open, pinned ? .unpin : .pin] : [.open]
        if windowScenes {
            for window in windows {
                let title = window.title.isEmpty ? appName : window.title
                actions.append(window.detached ? .moveToDesktop(window: window.id, title: title)
                                               : .openInNewWindow(window: window.id, title: title))
            }
        }
        // One way to end an app, as on a Mac: Quit closes every window and ends the app, and
        // offers Force Quit on its own when the app does not end (or has no windows to close).
        // Closing windows one by one is offered only where the computer cannot end the app.
        if let ending, ending.canQuit || ending.canForceQuit {
            actions.append(.quit)
        } else {
            for window in windows {
                actions.append(.close(window: window.id, title: window.title.isEmpty ? appName : window.title))
            }
        }
        return actions
    }
}
