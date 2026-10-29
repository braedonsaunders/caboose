import CoreGraphics

/// Switching windows from the keyboard: ⌥Tab opens a strip of the windows down the
/// desktop's leading edge, most recently used first, with the one before the current
/// window selected, so a quick press and release goes back to it. Each further Tab moves
/// the selection on (⇧ back), wrapping around, and letting go of ⌥ goes to the selection.
///
/// The order is taken when the strip opens and holds still while it is open, so the
/// selection never jumps under the owner's hand; a window that closes meanwhile leaves it.
/// Held open by a finger, the strip may have no selection: letting go there goes nowhere.
/// The strip may also open without a selection (`present`), for choosing by touch alone.
public struct QuickSwitch: Equatable, Sendable {
    /// The windows in the strip, most recently used first.
    public private(set) var windows: [Int] = []
    private var index: Int?

    public init() {}

    public private(set) var isOpen = false
    public var selection: Int? { index.map { windows[$0] } }

    /// Opens on `recent` with nothing selected.
    public mutating func present(_ recent: [Int]) {
        guard !recent.isEmpty else {
            close()
            return
        }
        windows = recent
        index = nil
        isOpen = true
    }

    /// Nothing selected: closing now goes nowhere.
    public mutating func deselect() {
        if isOpen { index = nil }
    }

    public mutating func open(_ recent: [Int], reverse: Bool = false) {
        guard !recent.isEmpty else {
            close()
            return
        }
        windows = recent
        index = recent.count == 1 ? 0 : (reverse ? recent.count - 1 : 1)
        isOpen = true
    }

    public mutating func advance(reverse: Bool = false) {
        guard isOpen, !windows.isEmpty else { return }
        guard let index else {
            self.index = reverse ? windows.count - 1 : 0
            return
        }
        self.index = (index + (reverse ? windows.count - 1 : 1)) % windows.count
    }

    public mutating func select(_ window: Int) {
        if let found = windows.firstIndex(of: window) { index = found }
    }

    /// Windows that closed leave the strip. The selection stays on its window while it is
    /// there, else moves to the window that took its place.
    public mutating func prune(keeping live: Set<Int>) {
        guard isOpen else { return }
        let selected = index.map { windows[$0] }
        let before = index.map { windows[..<$0].filter(live.contains).count }
        windows.removeAll { !live.contains($0) }
        if windows.isEmpty {
            index = nil
            isOpen = false
            return
        }
        guard let selected, let before else { return }
        index = windows.firstIndex(of: selected) ?? min(before, windows.count - 1)
    }

    /// Closes the strip, answering the window it ended on.
    @discardableResult public mutating func close() -> Int? {
        defer {
            windows = []
            index = nil
            isOpen = false
        }
        return selection
    }

    // MARK: Layout

    /// The strip's measurements for `count` windows on a screen `height` points tall: as
    /// large as `maximumItem`, smaller until all fit, and never below `minimumItem`, past
    /// which only the windows around the selection are shown.
    public struct Strip: Equatable, Sendable {
        public let item: CGFloat
        public let spacing: CGFloat
        public let padding: CGFloat
        /// The windows shown, as indices into the strip's windows.
        public let visible: Range<Int>

        public var size: CGSize {
            let count = CGFloat(visible.count)
            return CGSize(width: item + 2 * padding, height: count * item + max(0, count - 1) * spacing + 2 * padding)
        }

        /// Where the window at `index` sits, in the strip's own coordinates.
        public func frame(of index: Int) -> CGRect? {
            guard visible.contains(index) else { return nil }
            let offset = CGFloat(index - visible.lowerBound)
            return CGRect(x: padding, y: padding + offset * (item + spacing), width: item, height: item)
        }

        /// The window whose row is at `y` in the strip's own coordinates, each row taking half
        /// the spacing on either side. Above or below the shown rows there is none, so a finger
        /// that slides back off the strip selects nothing.
        public func index(atY y: CGFloat) -> Int? {
            guard !visible.isEmpty else { return nil }
            let offset = Int(((y - padding + spacing / 2) / (item + spacing)).rounded(.down))
            guard y >= padding - spacing / 2, offset >= 0, offset < visible.count else { return nil }
            return visible.lowerBound + offset
        }
    }

    public func strip(height: CGFloat, maximumItem: CGFloat = 64, minimumItem: CGFloat = 36) -> Strip {
        let padding: CGFloat = 10, spacing: CGFloat = 8
        let count = windows.count
        guard count > 0 else { return Strip(item: maximumItem, spacing: spacing, padding: padding, visible: 0..<0) }
        let room = max(0, height - 2 * padding)
        let fitting = (room + spacing) / CGFloat(count) - spacing
        let item = min(maximumItem, max(minimumItem, fitting.rounded(.down)))
        let fits = max(1, Int((room + spacing) / (item + spacing)))
        guard fits < count else { return Strip(item: item, spacing: spacing, padding: padding, visible: 0..<count) }
        let selected = index ?? 0
        let start = min(max(0, selected - fits / 2), count - fits)
        return Strip(item: item, spacing: spacing, padding: padding, visible: start..<(start + fits))
    }
}
