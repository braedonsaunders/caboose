import CoreGraphics
import Foundation

extension OnScreenGamepad {
    /// The fingers on the pad and what each holds, turned into `GameGamepadState`.
    ///
    /// A finger belongs to the group it lands on until it lifts. On the face buttons and the
    /// shoulders it presses whatever is under it as it slides, and both buttons in the seam
    /// between neighbours. A floating stick centres where its finger lands, and its centre
    /// follows a finger that travels past the rim. A tap then a press on a stick clicks it
    /// (L3, R3) for as long as that press lasts. A trigger pulls fully when touched and eases
    /// off as its finger slides down.
    public struct Tracker: Sendable {
        struct Finger: Sendable {
            /// Nil once the pad has taken the finger's controls away; it then holds nothing.
            var cluster: Cluster?
            var origin: CGPoint
            var point: CGPoint
            var began: TimeInterval
            /// A stick's centre.
            var center: CGPoint?
            /// Whether this press clicks its stick.
            var clicks = false
        }

        private var fingers: [Int: Finger] = [:]
        /// The last short tap on each stick, which a press soon after it turns into a click.
        private var taps: [Cluster: (time: TimeInterval, point: CGPoint)] = [:]

        /// How soon after a tap a press clicks the stick.
        static let clickWindow: TimeInterval = 0.3
        /// How short a touch is to count as a tap.
        static let tapDuration: TimeInterval = 0.25

        public init() {}

        /// Whether any finger is on the pad, holding something or not.
        public var isEmpty: Bool { fingers.isEmpty }

        /// A finger landed at `point`. It takes the group under it; a stick another finger is
        /// already holding is passed over.
        public mutating func began(_ id: Int, at point: CGPoint, time: TimeInterval, in layout: Layout, sticks: StickMode) {
            let held = Set(fingers.values.compactMap { $0.cluster }.filter { $0 == .leftStick || $0 == .rightStick })
            let cluster = OnScreenGamepad.cluster(at: point, in: layout, sticks: sticks, excluding: held)
            var finger = Finger(cluster: cluster, origin: point, point: point, began: time)
            if let cluster, let stick = Self.stick(cluster), let item = layout.item(stick) {
                finger.center = sticks == .floating ? point : CGPoint(x: item.frame.midX, y: item.frame.midY)
                if let tap = taps[cluster], time - tap.time <= Self.clickWindow,
                   hypot(point.x - tap.point.x, point.y - tap.point.y) <= item.frame.width / 2 {
                    finger.clicks = true
                }
                taps[cluster] = nil
            }
            fingers[id] = finger
        }

        public mutating func moved(_ id: Int, to point: CGPoint, in layout: Layout, sticks: StickMode) {
            guard var finger = fingers[id] else { return }
            finger.point = point
            if sticks == .floating, let cluster = finger.cluster, let stick = Self.stick(cluster),
               let item = layout.item(stick), let center = finger.center {
                let radius = item.frame.width / 2
                let dx = point.x - center.x, dy = point.y - center.y
                let distance = hypot(dx, dy)
                if distance > radius, radius > 0 {
                    finger.center = CGPoint(x: point.x - dx / distance * radius, y: point.y - dy / distance * radius)
                }
            }
            fingers[id] = finger
        }

        public mutating func ended(_ id: Int, at time: TimeInterval, in layout: Layout) {
            guard let finger = fingers.removeValue(forKey: id) else { return }
            guard let cluster = finger.cluster, let stick = Self.stick(cluster), let item = layout.item(stick) else { return }
            let travel = hypot(finger.point.x - finger.origin.x, finger.point.y - finger.origin.y)
            if !finger.clicks, time - finger.began <= Self.tapDuration, travel <= item.frame.width * 0.18 {
                taps[cluster] = (time, finger.point)
            }
        }

        /// Every finger lets go of what it holds; each controls nothing until it lifts.
        public mutating func disown() {
            for id in fingers.keys { fingers[id]?.cluster = nil }
            taps.removeAll()
        }

        /// Forgets every finger, as when the pad leaves the screen.
        public mutating func clear() {
            fingers.removeAll()
            taps.removeAll()
        }

        /// Where each stick a finger holds is centred.
        public var stickCenters: [Control: CGPoint] {
            var centers: [Control: CGPoint] = [:]
            for finger in fingers.values {
                if let cluster = finger.cluster, let stick = Self.stick(cluster), let center = finger.center { centers[stick] = center }
            }
            return centers
        }

        /// The groups fingers hold now.
        public var heldClusters: Set<Cluster> { Set(fingers.values.compactMap(\.cluster)) }

        /// The controller's state with these fingers on `layout`.
        public func state(in layout: Layout) -> GameGamepadState {
            var state = GameGamepadState()
            for finger in fingers.values {
                guard let cluster = finger.cluster else { continue }
                switch cluster {
                case .dpad:
                    guard let item = layout.item(.dpad) else { continue }
                    let offset = CGVector(dx: finger.point.x - item.frame.midX, dy: finger.point.y - item.frame.midY)
                    for direction in OnScreenGamepad.directions(offset, radius: item.frame.width / 2) { state[direction] = 1 }
                case .leftStick, .rightStick:
                    guard let stick = Self.stick(cluster), let item = layout.item(stick), let center = finger.center else { continue }
                    let left = cluster == .leftStick
                    let axes = OnScreenGamepad.stickAxes(CGVector(dx: finger.point.x - center.x, dy: finger.point.y - center.y),
                                                         radius: item.frame.width / 2)
                    // Two fingers never share a stick, so a value set here is this finger's.
                    state[left ? .leftX : .rightX] = axes.x
                    state[left ? .leftY : .rightY] = axes.y
                    if finger.clicks { state[left ? .leftStick : .rightStick] = 1 }
                case .face, .leftShoulders, .rightShoulders, .button:
                    for button in OnScreenGamepad.pressed(in: cluster, at: finger.point, items: layout.items(in: cluster)) {
                        var value = 1.0
                        // An arcade panel's triggers are buttons like the rest, rolled onto from above.
                        if cluster == .leftShoulders || cluster == .rightShoulders,
                           button == .leftTrigger || button == .rightTrigger,
                           let item = layout.item(.button(button)) {
                            value = OnScreenGamepad.triggerValue(slide: finger.point.y - finger.origin.y, height: item.frame.height)
                        }
                        state[button] = max(state[button], value)
                    }
                }
            }
            return state
        }

        static func stick(_ cluster: Cluster) -> Control? {
            switch cluster {
            case .leftStick: .leftStick
            case .rightStick: .rightStick
            default: nil
            }
        }
    }

    // MARK: Hit testing

    /// The group a finger landing at `point` takes: the nearest control within reach of it,
    /// so a thumb a little off a button still presses it; else, with floating sticks, the
    /// stick whose side of the pad it is on. Groups in `excluding` are passed over.
    public static func cluster(at point: CGPoint, in layout: Layout, sticks: StickMode, excluding: Set<Cluster> = []) -> Cluster? {
        var best: (cluster: Cluster, distance: CGFloat)?
        for item in layout.items where !excluding.contains(item.cluster) {
            let slack: CGFloat
            switch item.cluster {
            case .face: slack = 0.45
            case .leftShoulders, .rightShoulders: slack = 0.4
            case .dpad: slack = 0.4
            case .leftStick, .rightStick: slack = sticks == .fixed ? 0.3 : 0.1
            case .button: slack = 0.3
            }
            let reach = item.frame.insetBy(dx: -item.frame.width * slack, dy: -item.frame.height * slack)
            guard reach.contains(point) else { continue }
            let distance = hypot(point.x - item.frame.midX, point.y - item.frame.midY) / max(1, max(item.frame.width, item.frame.height))
            if best == nil || distance < best!.distance { best = (item.cluster, distance) }
        }
        if let best { return best.cluster }
        guard sticks == .floating else { return nil }
        for (stick, cluster) in [(Control.leftStick, Cluster.leftStick), (.rightStick, .rightStick)]
        where !excluding.contains(cluster) && layout.zones[stick]?.contains(point) == true {
            return cluster
        }
        return nil
    }

    /// The buttons of `cluster` a finger at `point` presses.
    static func pressed(in cluster: Cluster, at point: CGPoint, items: [Item]) -> [GameGamepadState.Button] {
        func button(_ item: Item) -> GameGamepadState.Button? {
            if case .button(let button) = item.control { return button }
            return nil
        }
        switch cluster {
        case .dpad, .leftStick, .rightStick:
            return []
        case .button:
            // A lone button stays down until its finger slides well away from it.
            guard let item = items.first, let pressed = button(item) else { return [] }
            let reach = item.frame.insetBy(dx: -max(item.frame.width, item.frame.height) * 0.75,
                                           dy: -max(item.frame.width, item.frame.height) * 0.75)
            return reach.contains(point) ? [pressed] : []
        case .leftShoulders, .rightShoulders:
            // A row: the button across from the finger, both in the seam between two.
            let row = items.sorted { $0.frame.minX < $1.frame.minX }
            guard let first = row.first, let last = row.last,
                  point.x >= first.frame.minX - first.frame.width * 0.6, point.x <= last.frame.maxX + last.frame.width * 0.6 else { return [] }
            var pressed: [GameGamepadState.Button] = []
            for (index, item) in row.enumerated() {
                let low = index == 0 ? -CGFloat.infinity : (row[index - 1].frame.maxX + item.frame.minX) / 2
                let high = index == row.count - 1 ? CGFloat.infinity : (item.frame.maxX + row[index + 1].frame.minX) / 2
                let lowBand = index == 0 ? 0 : seam(row[index - 1], item)
                let highBand = index == row.count - 1 ? 0 : seam(item, row[index + 1])
                if point.x >= low - lowBand && point.x <= high + highBand, let button = button(item) { pressed.append(button) }
            }
            return pressed
        case .face:
            let ranked = items.compactMap { item -> (button: GameGamepadState.Button, center: CGPoint, radius: CGFloat, distance: CGFloat)? in
                guard let button = button(item) else { return nil }
                let center = CGPoint(x: item.frame.midX, y: item.frame.midY), radius = max(1, item.frame.width / 2)
                return (button, center, radius, hypot(point.x - center.x, point.y - center.y) / radius)
            }.sorted { $0.distance < $1.distance }
            guard let first = ranked.first, first.distance <= 1.4 else { return [] }
            var pressed = [first.button]
            if ranked.count > 1 {
                let second = ranked[1]
                let ab = CGVector(dx: second.center.x - first.center.x, dy: second.center.y - first.center.y)
                let length = hypot(ab.dx, ab.dy)
                let radius = max(first.radius, second.radius)
                // Neighbours only: never two buttons across the diamond from each other.
                if length > 0, length <= radius * 3 {
                    let along = ((point.x - first.center.x) * ab.dx + (point.y - first.center.y) * ab.dy) / (length * length)
                    let across = abs((point.x - first.center.x) * ab.dy - (point.y - first.center.y) * ab.dx) / length
                    if along >= 0.2, along <= 0.8, across <= radius * 0.8 { pressed.append(second.button) }
                }
            }
            return pressed
        }
    }

    /// Half the width of the seam between two buttons of a row in which both are pressed.
    private static func seam(_ a: Item, _ b: Item) -> CGFloat {
        max(0, b.frame.minX - a.frame.maxX) / 2 + min(a.frame.width, b.frame.width) * 0.15
    }

    // MARK: Response

    /// Past this share of its travel from centre a stick reads as moved.
    static let stickDeadzone = 0.1
    /// At this share of its travel a stick reads as fully over, so a thumb need not find the rim.
    static let stickSaturation = 0.85

    /// A stick's axes for a finger `offset` from its centre: nothing inside the dead zone, then
    /// rising evenly to full at `stickSaturation` of the radius, in the finger's direction.
    static func stickAxes(_ offset: CGVector, radius: CGFloat) -> (x: Double, y: Double) {
        guard radius > 0 else { return (0, 0) }
        let x = Double(offset.dx / radius), y = Double(offset.dy / radius)
        let length = hypot(x, y)
        guard length > stickDeadzone else { return (0, 0) }
        let magnitude = min(1, (length - stickDeadzone) / (stickSaturation - stickDeadzone))
        return (x / length * magnitude, y / length * magnitude)
    }

    /// The d-pad's directions for a finger `offset` from its centre: one of eight, a diagonal
    /// pressing both of its neighbours; none near the centre.
    static func directions(_ offset: CGVector, radius: CGFloat) -> [GameGamepadState.Button] {
        guard radius > 0, hypot(offset.dx, offset.dy) > radius * 0.22 else { return [] }
        let angle = atan2(offset.dy, offset.dx)
        let sector = Int(((angle + .pi) / (.pi / 4)).rounded()) % 8
        let directions: [[GameGamepadState.Button]] = [[.left], [.left, .up], [.up], [.up, .right], [.right], [.right, .down], [.down], [.down, .left]]
        return directions[sector]
    }

    /// A trigger's pull after its finger slid `slide` points down from where it landed: full,
    /// easing to 0.15 over twice the trigger's height.
    static func triggerValue(slide: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 1 }
        return 1 - min(0.85, Double(max(0, slide) / (height * 2)))
    }
}
