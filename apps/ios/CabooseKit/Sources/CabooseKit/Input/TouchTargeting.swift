import Foundation

/// A control a finger can mean: its rectangle in window-local display pixels and its kind,
/// as the computer reads it from the window's accessibility tree (`targets`, docs/display.md).
public struct TouchTarget: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case other = 0, button, toggle, link, menu, tab, field, item, adjustable
    }

    public var rect: CGRect
    public var kind: Kind
    public var enabled: Bool

    public init(rect: CGRect, kind: Kind, enabled: Bool = true) {
        self.rect = rect
        self.kind = kind
        self.enabled = enabled
    }

    /// The wire form: `[x, y, w, h, kind]`, `kind` with 0x80 set for a disabled control.
    public init?(wire: [Double]) {
        guard wire.count >= 5, wire[2] > 0, wire[3] > 0, wire.allSatisfy(\.isFinite) else { return nil }
        let code = Int(wire[4])
        guard code >= 0, code <= 0xFF else { return nil }
        self.init(rect: CGRect(x: wire[0], y: wire[1], width: wire[2], height: wire[3]),
                  kind: Kind(rawValue: UInt8(code & 0x7F)) ?? .other, enabled: code & 0x80 == 0)
    }
}

/// Where a finger meant to press, among the window's controls.
///
/// A finger lands about a couple of millimetres from where its owner aimed, in any
/// direction, which on a desktop window is several controls wide. Each control near the
/// touch is scored by how likely a finger aiming somewhere on it would land where this one
/// did: the aim point is uniform over the control and the landing error Gaussian, which in
/// each axis is a difference of two normal CDFs over the control's width (Bayesian
/// touch, Bi and Zhai 2013). A small control right next to the finger therefore beats a
/// large one the finger is barely inside, and the control under the finger beats an equal
/// neighbour. Touching nothing in particular is a hypothesis too, spread evenly over a
/// patch many spreads wide: it outweighs every control a few spreads from the finger, and
/// controls far larger than that patch (a document, a canvas) never pull a touch at all.
///
/// The pull is at most a few spreads, so a control that has moved since it was read can
/// misplace a touch by no more than an unaided finger would.
public enum TouchAim {
    public struct Choice: Equatable, Sendable {
        /// The index of the chosen target.
        public var index: Int
        /// Where to press: the touch itself when it is on the target, else the nearest
        /// point well inside it.
        public var point: CGPoint
    }

    /// Every reading of one touch: the targets it may have meant with their probability,
    /// most likely first, and the probability that it meant none.
    public struct Reading: Equatable, Sendable {
        public var candidates: [(index: Int, probability: Double)]
        public var background: Double
        /// The press: the likeliest target, unless no target or a disabled one is likelier.
        public var choice: Choice?

        /// Whether a second, magnified look would settle it: the likeliest reading,
        /// target or none, is not clearly ahead of the next.
        public func isAmbiguous(below confidence: Double = 0.75) -> Bool {
            let readings = (candidates.map(\.probability) + [background]).sorted(by: >)
            return readings.count > 1 && readings[0] < confidence && readings[1] > 0.1
        }

        public static func == (a: Reading, b: Reading) -> Bool {
            a.choice == b.choice && a.background == b.background
                && a.candidates.map(\.index) == b.candidates.map(\.index)
                && a.candidates.map(\.probability) == b.candidates.map(\.probability)
        }
    }

    /// The touch belongs to no target when it is this many spreads from every one.
    static let reach: CGFloat = 3
    /// The background hypothesis: a uniform patch this many spreads wide.
    public static let backgroundSpan: CGFloat = 20

    /// The target `touch` most likely meant, given `spread`, the landing error's standard
    /// deviation in the targets' pixels; nil to press where the finger is.
    public static func choose(_ touch: CGPoint, spread: CGFloat, among targets: [TouchTarget],
                              backgroundSpan: CGFloat = backgroundSpan) -> Choice? {
        read(touch, spread: spread, among: targets, backgroundSpan: backgroundSpan).choice
    }

    public static func read(_ touch: CGPoint, spread: CGFloat, among targets: [TouchTarget],
                            backgroundSpan: CGFloat = backgroundSpan) -> Reading {
        guard spread > 0, spread.isFinite, touch.x.isFinite, touch.y.isFinite else {
            return Reading(candidates: [], background: 1, choice: nil)
        }
        var scores: [(index: Int, probability: Double)] = []
        for (index, target) in targets.enumerated() {
            let rect = target.rect
            guard rect.width > 0, rect.height > 0,
                  rect.insetBy(dx: -reach * spread, dy: -reach * spread).contains(touch) else { continue }
            let score = likelihood(touch, rect, spread) * prior(target)
            if score > 0 { scores.append((index, score)) }
        }
        let background = 1 / Double(backgroundSpan * spread * backgroundSpan * spread)
        let total = scores.reduce(background) { $0 + $1.probability }
        let candidates = scores.map { ($0.index, $0.probability / total) }.sorted { $0.1 > $1.1 }
        var choice: Choice?
        if let best = candidates.first, best.1 > background / total, targets[best.0].enabled {
            choice = Choice(index: best.0, point: pressPoint(touch, in: targets[best.0].rect, spread: spread))
        }
        return Reading(candidates: candidates, background: background / total, choice: choice)
    }

    /// How likely a finger aiming uniformly over `rect` lands at `touch`, per pixel².
    static func likelihood(_ touch: CGPoint, _ rect: CGRect, _ spread: CGFloat) -> Double {
        axis(Double(touch.x), Double(rect.minX), Double(rect.maxX), Double(spread))
            * axis(Double(touch.y), Double(rect.minY), Double(rect.maxY), Double(spread))
    }

    private static func axis(_ p: Double, _ low: Double, _ high: Double, _ spread: Double) -> Double {
        (normal((p - low) / spread) - normal((p - high) / spread)) / (high - low)
    }

    private static func normal(_ z: Double) -> Double { 0.5 * erfc(-z / 2.squareRoot()) }

    /// Disabled controls still claim their touches, so a press near one is not moved onto
    /// its neighbour; they never receive one.
    static func prior(_ target: TouchTarget) -> Double { 1 }

    /// The touch itself when it is on the target; otherwise the closest point inside it
    /// by a margin, so the press does not land on a border the toolkit gives a neighbour.
    static func pressPoint(_ touch: CGPoint, in rect: CGRect, spread: CGFloat) -> CGPoint {
        if rect.contains(touch) { return touch }
        let inset = min(rect.width, rect.height) * 0.3
        let inner = rect.insetBy(dx: min(inset, rect.width / 2), dy: min(inset, rect.height / 2))
        return CGPoint(x: min(max(touch.x, inner.minX), inner.maxX), y: min(max(touch.y, inner.minY), inner.maxY))
    }
}
