import CoreGraphics
import Foundation

/// The on-screen controller of Laptop's Gamepad mode: how it is laid out, how touches become a
/// `GameGamepadState`, and which keys it presses in a window that does not take a controller.
///
/// A game handed off to this device sees the controller through its Gamepad API
/// (`RemoteGame.gamepad`). Any other window gets keys: each control presses the key the owner
/// assigned to it for as long as it is held. No controller device exists on the computer.
public enum LaptopGamepad {
    /// One control of the pad.
    public enum Control: Hashable, Sendable {
        case dpad, leftStick, rightStick
        case button(GameGamepadState.Button)
    }

    /// A control and where it is, in the pad's own points.
    public struct Item: Equatable, Sendable {
        public var control: Control
        public var frame: CGRect
    }

    /// What drives a direction pad in the left cluster.
    public enum LeftControl: String, Codable, CaseIterable, Sendable { case dpad, stick }

    /// What a game running on this device receives.
    public enum GameRoute: String, Codable, CaseIterable, Sendable {
        /// A standard controller through the page's Gamepad API.
        case controller
        /// The keys assigned below, like any other window.
        case keys
    }

    /// The keys a stick presses past half its travel.
    public enum StickKeys: String, Codable, CaseIterable, Sendable {
        case arrows, wasd, none
        public var title: String {
            switch self { case .arrows: "Arrow Keys"; case .wasd: "W A S D"; case .none: "None" }
        }
        /// Up, down, left, right.
        var keys: [String]? {
            switch self {
            case .arrows: ["Up", "Down", "Left", "Right"]
            case .wasd: ["w", "s", "a", "d"]
            case .none: nil
            }
        }
    }

    /// The owner's arrangement and key assignments, kept between launches.
    public struct Settings: Codable, Equatable, Sendable {
        public var left: LeftControl = .dpad
        public var showsRightStick = false
        public var showsTriggers = true
        /// The size of the clusters, 0.8 to 1.25 of their fitted size.
        public var scale = 1.0
        public var haptics = true
        public var games: GameRoute = .controller
        /// Each button's key by `Button` name; a missing or empty one presses nothing.
        public var keys: [String: String] = LaptopGamepad.defaultKeys
        public var dpadKeys: StickKeys = .arrows
        public var leftStickKeys: StickKeys = .arrows
        public var rightStickKeys: StickKeys = .wasd

        public init() {}

        public func key(for button: GameGamepadState.Button) -> String? {
            keys[LaptopGamepad.name(button)].flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The settings stored as `data`, or the defaults when there are none or they are unreadable.
        public static func decode(_ data: Data?) -> Settings {
            data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }

        public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            left = (try? container.decode(LeftControl.self, forKey: .left)) ?? defaults.left
            showsRightStick = (try? container.decode(Bool.self, forKey: .showsRightStick)) ?? defaults.showsRightStick
            showsTriggers = (try? container.decode(Bool.self, forKey: .showsTriggers)) ?? defaults.showsTriggers
            scale = min(1.25, max(0.8, (try? container.decode(Double.self, forKey: .scale)) ?? defaults.scale))
            haptics = (try? container.decode(Bool.self, forKey: .haptics)) ?? defaults.haptics
            games = (try? container.decode(GameRoute.self, forKey: .games)) ?? defaults.games
            keys = (try? container.decode([String: String].self, forKey: .keys)) ?? defaults.keys
            dpadKeys = (try? container.decode(StickKeys.self, forKey: .dpadKeys)) ?? defaults.dpadKeys
            leftStickKeys = (try? container.decode(StickKeys.self, forKey: .leftStickKeys)) ?? defaults.leftStickKeys
            rightStickKeys = (try? container.decode(StickKeys.self, forKey: .rightStickKeys)) ?? defaults.rightStickKeys
        }
    }

    /// A button's stable name, the key `Settings.keys` uses.
    public static func name(_ button: GameGamepadState.Button) -> String { String(describing: button) }

    /// What each button is called on the pad.
    public static func title(_ button: GameGamepadState.Button) -> String {
        switch button {
        case .south: "A"
        case .east: "B"
        case .west: "X"
        case .north: "Y"
        case .leftShoulder: "L1"
        case .rightShoulder: "R1"
        case .leftTrigger: "L2"
        case .rightTrigger: "R2"
        case .select: "Select"
        case .start: "Start"
        case .leftStick: "L3"
        case .rightStick: "R3"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .home: "Home"
        }
    }

    /// The buttons drawn as buttons (the d-pad's directions are the d-pad).
    public static let assignableButtons: [GameGamepadState.Button] = [
        .south, .east, .west, .north, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger, .select, .start,
    ]

    public static let defaultKeys: [String: String] = [
        "south": "space", "east": "Escape", "west": "z", "north": "x",
        "leftShoulder": "q", "rightShoulder": "e", "leftTrigger": "Shift_L", "rightTrigger": "Control_L",
        "select": "Tab", "start": "Return",
    ]

    /// The keys a button can be given, by name, and what the picker calls them.
    public static let keyChoices: [(name: String, title: String)] = {
        var choices: [(name: String, title: String)] = [
            ("", "None"), ("space", "Space"), ("Return", "Return"), ("Escape", "Escape"), ("Tab", "Tab"),
            ("BackSpace", "Delete"), ("Shift_L", "Shift"), ("Control_L", "Control"), ("Alt_L", "Option"),
            ("Up", "↑"), ("Down", "↓"), ("Left", "←"), ("Right", "→"),
        ]
        choices += "abcdefghijklmnopqrstuvwxyz0123456789".map { (name: String($0), title: String($0).uppercased()) }
        choices += (1 ... 12).map { (name: "F\($0)", title: "F\($0)") }
        return choices
    }()

    /// The keystroke a key name presses: a special key, `space`, or one character.
    public static func stroke(for name: String) -> KeyStroke? {
        if let special = Keysyms.special[name] { return special }
        if name == "space" { return Keysyms.stroke(for: " ") }
        guard name.count == 1, let character = name.first else { return nil }
        return Keysyms.stroke(for: character)
    }

    // MARK: Layout

    /// The pad's controls in a `size` area: shoulder and trigger buttons along the top edge,
    /// the d-pad or stick on the left, the face buttons on the right, Select and Start in the
    /// middle, and the right stick below them when it shows.
    public static func items(in size: CGSize, settings: Settings) -> [Item] {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return [] }
        let margin: CGFloat = 12
        let shoulderHeight: CGFloat = min(40, size.height * 0.14)
        let top = margin + shoulderHeight + 10
        let room = max(0, size.height - top - margin)
        let fitted = min(room, size.width * 0.34)
        let side = min(fitted * CGFloat(min(1.25, max(0.8, settings.scale))), room, size.width * 0.42)
        let clusterY = top + (room - side) / 2
        var items: [Item] = []

        let shoulderWidth = min(110, size.width * 0.2)
        let triggerWidth = settings.showsTriggers ? shoulderWidth * 0.8 : 0
        let gap: CGFloat = settings.showsTriggers ? 8 : 0
        if settings.showsTriggers {
            items.append(Item(control: .button(.leftTrigger), frame: CGRect(x: margin, y: margin, width: triggerWidth, height: shoulderHeight)))
            items.append(Item(control: .button(.rightTrigger),
                              frame: CGRect(x: size.width - margin - triggerWidth, y: margin, width: triggerWidth, height: shoulderHeight)))
        }
        items.append(Item(control: .button(.leftShoulder),
                          frame: CGRect(x: margin + triggerWidth + gap, y: margin, width: shoulderWidth, height: shoulderHeight)))
        items.append(Item(control: .button(.rightShoulder),
                          frame: CGRect(x: size.width - margin - triggerWidth - gap - shoulderWidth, y: margin,
                                        width: shoulderWidth, height: shoulderHeight)))

        let left = CGRect(x: margin + 8, y: clusterY, width: side, height: side)
        items.append(Item(control: settings.left == .dpad ? .dpad : .leftStick, frame: left))
        let face = CGRect(x: size.width - margin - 8 - side, y: clusterY, width: side, height: side)
        let button = side * 0.32
        let center = CGPoint(x: face.midX, y: face.midY)
        let reach = (side - button) / 2
        let diamond: [(GameGamepadState.Button, CGFloat, CGFloat)] = [(.north, 0, -1), (.south, 0, 1), (.west, -1, 0), (.east, 1, 0)]
        for (name, dx, dy) in diamond {
            items.append(Item(control: .button(name), frame: CGRect(x: center.x + reach * dx - button / 2,
                                                                    y: center.y + reach * dy - button / 2,
                                                                    width: button, height: button)))
        }

        let middle = size.width / 2
        let pill = CGSize(width: min(72, (face.minX - left.maxX) / 2 - 8), height: 30)
        if pill.width > 24 {
            items.append(Item(control: .button(.select), frame: CGRect(x: middle - 6 - pill.width, y: clusterY, width: pill.width, height: pill.height)))
            items.append(Item(control: .button(.start), frame: CGRect(x: middle + 6, y: clusterY, width: pill.width, height: pill.height)))
        }
        if settings.showsRightStick {
            let stick = min(side * 0.72, face.minX - left.maxX - 16, room - pill.height - 12)
            if stick > 40 {
                items.append(Item(control: .rightStick, frame: CGRect(x: middle - stick / 2, y: clusterY + side - stick,
                                                                      width: stick, height: stick)))
            }
        }
        return items
    }

    // MARK: Touches

    /// The control a touch at `point` begins on: the nearest within reach of it, so a thumb a
    /// little off a button still presses it.
    public static func control(at point: CGPoint, in items: [Item]) -> Control? {
        var best: (Control, CGFloat)?
        for item in items {
            let slack = item.control == .dpad || item.control == .leftStick || item.control == .rightStick ? 0.15 : 0.35
            let reach = item.frame.insetBy(dx: -item.frame.width * slack, dy: -item.frame.height * slack)
            guard reach.contains(point) else { continue }
            let distance = hypot(point.x - item.frame.midX, point.y - item.frame.midY) / max(1, max(item.frame.width, item.frame.height))
            if best == nil || distance < best!.1 { best = (item.control, distance) }
        }
        return best?.0
    }

    /// The pad's state while each control in `held` has a finger at its point.
    public static func state(held: [(control: Control, point: CGPoint)], items: [Item]) -> GameGamepadState {
        var state = GameGamepadState()
        for (control, point) in held {
            guard let frame = items.first(where: { $0.control == control })?.frame else { continue }
            let radius = max(1, frame.width / 2)
            let dx = (point.x - frame.midX) / radius, dy = (point.y - frame.midY) / radius
            switch control {
            case .button(let button):
                state[button] = 1
            case .dpad:
                guard hypot(dx, dy) > 0.25 else { continue }
                // Eight directions: a diagonal presses both of its neighbours.
                let angle = atan2(dy, dx)
                let sector = Int(((angle + .pi) / (.pi / 4)).rounded()) % 8
                let directions: [[GameGamepadState.Button]] = [[.left], [.left, .up], [.up], [.up, .right], [.right], [.right, .down], [.down], [.down, .left]]
                for direction in directions[sector] { state[direction] = 1 }
            case .leftStick, .rightStick:
                let length = hypot(dx, dy)
                let scale = length > 1 ? 1 / length : 1
                let deadzone = length < 0.08
                let (xAxis, yAxis): (GameGamepadState.Axis, GameGamepadState.Axis) = control == .leftStick ? (.leftX, .leftY) : (.rightX, .rightY)
                state[xAxis] = deadzone ? 0 : Double(dx * scale)
                state[yAxis] = deadzone ? 0 : Double(dy * scale)
            }
        }
        return state
    }

    // MARK: Keys

    /// The keys `state` holds down under `settings`, by name.
    public static func keys(for state: GameGamepadState, settings: Settings) -> Set<String> {
        var keys = Set<String>()
        for button in assignableButtons where state[button] > 0.5 {
            if let key = settings.key(for: button) { keys.insert(key) }
        }
        if let dpad = settings.dpadKeys.keys {
            for (index, button) in [GameGamepadState.Button.up, .down, .left, .right].enumerated() where state[button] > 0.5 {
                keys.insert(dpad[index])
            }
        }
        let sticks: [(GameGamepadState.Axis, GameGamepadState.Axis, StickKeys)] = [
            (.leftX, .leftY, settings.leftStickKeys), (.rightX, .rightY, settings.rightStickKeys),
        ]
        for (x, y, set) in sticks {
            guard let names = set.keys else { continue }
            if state[y] < -0.5 { keys.insert(names[0]) }
            if state[y] > 0.5 { keys.insert(names[1]) }
            if state[x] < -0.5 { keys.insert(names[2]) }
            if state[x] > 0.5 { keys.insert(names[3]) }
        }
        return keys
    }

    /// The key releases then presses that take the keys held for `old` to those for `new`.
    public static func keyChanges(from old: GameGamepadState, to new: GameGamepadState, settings: Settings) -> [(name: String, pressed: Bool)] {
        let before = keys(for: old, settings: settings), after = keys(for: new, settings: settings)
        return before.subtracting(after).sorted().map { (name: $0, pressed: false) }
            + after.subtracting(before).sorted().map { (name: $0, pressed: true) }
    }
}
