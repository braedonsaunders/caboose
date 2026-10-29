/// What holding an app in a dock offers: Open, Pin or Unpin, and Close for each of its
/// windows, named by title (or the app's name for a window without one).
public enum DockMenu {
    public struct Window: Equatable, Sendable {
        public let id: Int
        public let title: String

        public init(id: Int, title: String) {
            self.id = id
            self.title = title
        }
    }

    public enum Action: Equatable, Sendable {
        /// Goes to the app's window, or opens the app when it has none.
        case open
        case pin
        case unpin
        case close(window: Int, title: String)

        public var title: String {
            switch self {
            case .open: "Open"
            case .pin: "Pin"
            case .unpin: "Unpin"
            case .close(_, let title): "Close \(title)"
            }
        }
    }

    public static func actions(appName: String, pinned: Bool, windows: [Window]) -> [Action] {
        [.open, pinned ? .unpin : .pin]
            + windows.map { .close(window: $0.id, title: $0.title.isEmpty ? appName : $0.title) }
    }
}
