import CoreGraphics
import Foundation

/// The on-screen controller the app draws below Laptop's hinge and across the phone while a
/// display shows the desktop: its controller types, how each is labelled, the owner's settings,
/// and which keys it presses in a window that does not take a controller.
///
/// A game handed off to this device sees the controller through its Gamepad API
/// (`RemoteGame.gamepad`). Any other window gets keys: each control presses the key the owner
/// assigned to it for as long as it is held; or, when the owner chooses `WindowRoute.controller`,
/// the computer's gamepad device for the on-screen controller (docs/devices.md).
/// `layout(in:style:settings:)` places a type's controls and `Tracker` turns fingers into
/// `GameGamepadState`.
public enum OnScreenGamepad {
    /// A kind of controller, each with its own arrangement and look.
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Twin offset sticks, a d-pad, four face buttons, bumpers, analog triggers, View, Menu
        /// and Guide: every control of the standard mapping.
        case modern
        /// A d-pad, four face buttons in a diamond, two shoulder buttons, Select and Start.
        case classic
        /// A d-pad, two buttons, Select and Start.
        case retro
        /// An eight-way lever and eight buttons in two curved rows.
        case arcade

        public var title: String {
            switch self {
            case .modern: "Modern"
            case .classic: "Classic"
            case .retro: "Retro"
            case .arcade: "Arcade"
            }
        }

        public var summary: String {
            switch self {
            case .modern: "Twin sticks, triggers and bumpers"
            case .classic: "D-pad, four buttons and shoulders"
            case .retro: "D-pad and two buttons"
            case .arcade: "Lever and eight buttons"
            }
        }

        public var symbol: String {
            switch self {
            case .modern: "gamecontroller.fill"
            case .classic: "gamecontroller"
            case .retro: "dpad.fill"
            case .arcade: "arcade.stick"
            }
        }

        /// The buttons this type has, besides the d-pad's directions.
        public var buttons: [GameGamepadState.Button] {
            switch self {
            case .modern:
                [.south, .east, .west, .north, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
                 .select, .start, .home, .leftStick, .rightStick]
            case .classic: [.south, .east, .west, .north, .leftShoulder, .rightShoulder, .select, .start]
            case .retro: [.south, .east, .select, .start]
            case .arcade:
                [.south, .east, .west, .north, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
                 .select, .start, .home]
            }
        }

        /// Whether the type has analog sticks.
        public var hasSticks: Bool { self == .modern }
        /// Whether its face buttons carry Xbox or PlayStation markings (`Settings.labels`); the
        /// others are marked as the controllers they recall.
        public var takesLabels: Bool { self == .modern || self == .arcade }
    }

    /// The markings on a Modern or Arcade controller's buttons.
    public enum Labels: String, Codable, CaseIterable, Sendable {
        case xbox, playstation
        public var title: String {
            switch self { case .xbox: "Xbox"; case .playstation: "PlayStation" }
        }
    }

    /// Where a stick's centre is.
    public enum StickMode: String, Codable, CaseIterable, Sendable {
        /// Where the thumb lands, anywhere on its side of the pad; the centre follows a thumb
        /// that travels past the rim, so a reversal answers at once.
        case floating
        /// Drawn in place; a touch must start on it.
        case fixed
        public var title: String {
            switch self { case .floating: "Wherever You Touch"; case .fixed: "Fixed in Place" }
        }
    }

    /// One control of the pad.
    public enum Control: Hashable, Sendable {
        case dpad, leftStick, rightStick
        case button(GameGamepadState.Button)
    }

    /// The controls a finger owns from the moment it lands until it lifts. Within a group the
    /// finger presses whichever buttons are under it, so a thumb rolls across the face buttons;
    /// between two neighbours it presses both.
    public enum Cluster: Hashable, Sendable {
        case dpad, leftStick, rightStick
        /// The face buttons (an Arcade controller's eight).
        case face
        /// A bumper and trigger side by side, resolved along the row; sliding down a trigger
        /// eases it off.
        case leftShoulders, rightShoulders
        /// A button on its own.
        case button(GameGamepadState.Button)
    }

    /// What a button is called, and the SF Symbol drawn in place of the name when it has one.
    public struct Label: Equatable, Sendable {
        public var name: String
        public var symbol: String?
        init(_ name: String, symbol: String? = nil) {
            self.name = name
            self.symbol = symbol
        }
    }

    /// What `button` is called on a `style` controller marked with `labels`.
    public static func label(_ button: GameGamepadState.Button, style: Style, labels: Labels = .xbox) -> Label {
        switch style {
        case .retro, .classic:
            switch button {
            case .south: return Label("B")
            case .east: return Label("A")
            case .west: return Label("Y")
            case .north: return Label("X")
            case .leftShoulder: return Label("L")
            case .rightShoulder: return Label("R")
            case .select: return Label("Select")
            case .start: return Label("Start")
            default: break
            }
        case .modern, .arcade:
            break
        }
        switch (labels, button) {
        case (.xbox, .south): return Label("A")
        case (.xbox, .east): return Label("B")
        case (.xbox, .west): return Label("X")
        case (.xbox, .north): return Label("Y")
        case (.xbox, .leftShoulder): return Label("LB")
        case (.xbox, .rightShoulder): return Label("RB")
        case (.xbox, .leftTrigger): return Label("LT")
        case (.xbox, .rightTrigger): return Label("RT")
        case (.xbox, .select): return Label("View", symbol: "rectangle.on.rectangle")
        case (.xbox, .start): return Label("Menu", symbol: "line.3.horizontal")
        case (.xbox, .home): return Label("Guide", symbol: "house.fill")
        case (.xbox, .leftStick): return Label("LS")
        case (.xbox, .rightStick): return Label("RS")
        case (.playstation, .south): return Label("Cross", symbol: "xmark")
        case (.playstation, .east): return Label("Circle", symbol: "circle")
        case (.playstation, .west): return Label("Square", symbol: "square")
        case (.playstation, .north): return Label("Triangle", symbol: "triangle")
        case (.playstation, .leftShoulder): return Label("L1")
        case (.playstation, .rightShoulder): return Label("R1")
        case (.playstation, .leftTrigger): return Label("L2")
        case (.playstation, .rightTrigger): return Label("R2")
        case (.playstation, .select): return Label("Create")
        case (.playstation, .start): return Label("Options", symbol: "line.3.horizontal")
        case (.playstation, .home): return Label("PS", symbol: "house.fill")
        case (.playstation, .leftStick): return Label("L3")
        case (.playstation, .rightStick): return Label("R3")
        case (_, .up): return Label("Up")
        case (_, .down): return Label("Down")
        case (_, .left): return Label("Left")
        case (_, .right): return Label("Right")
        }
    }

    /// What a game running on this device receives.
    public enum GameRoute: String, Codable, CaseIterable, Sendable {
        /// A standard controller through the page's Gamepad API.
        case controller
        /// The keys assigned below, like any other window.
        case keys
    }

    /// What a window that is not a game on this device receives.
    public enum WindowRoute: String, Codable, CaseIterable, Sendable {
        /// The keys assigned below.
        case keys
        /// The on-screen controller as a gamepad on the computer (docs/devices.md).
        case controller
    }

    /// The keys a stick or the d-pad presses past half its travel.
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

    /// The owner's controller, feel and key assignments, kept between launches.
    public struct Settings: Codable, Equatable, Sendable {
        /// The type for an app the owner has not chosen one for.
        public var style: Style = .modern
        /// The type last chosen for each app, by its window class.
        public var appStyles: [String: Style] = [:]
        public var labels: Labels = .xbox
        public var sticks: StickMode = .floating
        /// The size of the controls, 0.8 to 1.2 of their fitted size.
        public var scale = 1.0
        public var haptics = true
        public var games: GameRoute = .controller
        public var windows: WindowRoute = .keys
        /// Each button's key by `Button` name; a missing or empty one presses nothing.
        public var keys: [String: String] = OnScreenGamepad.defaultKeys
        public var dpadKeys: StickKeys = .arrows
        public var leftStickKeys: StickKeys = .arrows
        public var rightStickKeys: StickKeys = .wasd

        public static let scaleRange: ClosedRange<Double> = 0.8 ... 1.2

        public init() {}

        public func key(for button: GameGamepadState.Button) -> String? {
            keys[OnScreenGamepad.name(button)].flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The type the pad shows for the app whose window class is `app`.
        public func style(for app: String?) -> Style {
            app.flatMap { appStyles[$0] } ?? style
        }

        /// Chooses `style` for `app`, and for apps with no choice of their own.
        public mutating func choose(_ style: Style, for app: String?) {
            self.style = style
            if let app, !app.isEmpty { appStyles[app] = style }
        }

        /// The settings stored as `data`, or the defaults when there are none or they are unreadable.
        public static func decode(_ data: Data?) -> Settings {
            data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }

        public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decode(T.self, forKey: key)) ?? fallback
            }
            style = value(.style, defaults.style)
            // An app whose stored type this version does not know falls back to the default.
            let stored: [String: String] = value(.appStyles, [:])
            appStyles = stored.compactMapValues(Style.init(rawValue:))
            labels = value(.labels, defaults.labels)
            sticks = value(.sticks, defaults.sticks)
            scale = min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, value(.scale, defaults.scale)))
            haptics = value(.haptics, defaults.haptics)
            games = value(.games, defaults.games)
            windows = value(.windows, defaults.windows)
            keys = value(.keys, defaults.keys)
            dpadKeys = value(.dpadKeys, defaults.dpadKeys)
            leftStickKeys = value(.leftStickKeys, defaults.leftStickKeys)
            rightStickKeys = value(.rightStickKeys, defaults.rightStickKeys)
        }
    }

    /// A button's stable name, the key `Settings.keys` uses.
    public static func name(_ button: GameGamepadState.Button) -> String { String(describing: button) }

    /// The buttons drawn as buttons (the d-pad's directions are the d-pad), in the order the
    /// key assignments list them.
    public static let assignableButtons: [GameGamepadState.Button] = [
        .south, .east, .west, .north, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
        .select, .start, .home, .leftStick, .rightStick,
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

    // MARK: Feel

    /// The tap a change of state is felt as.
    public enum Feedback: Comparable, Sendable {
        /// The d-pad took a new direction.
        case direction
        /// A button went down.
        case press
        /// A stick was clicked.
        case click
    }

    /// The strongest feedback the change from `old` to `new` earns, if any.
    public static func feedback(from old: GameGamepadState, to new: GameGamepadState) -> Feedback? {
        func down(_ button: GameGamepadState.Button) -> Bool { new[button] > 0.5 && old[button] <= 0.5 }
        if down(.leftStick) || down(.rightStick) { return .click }
        if assignableButtons.contains(where: { $0 != .leftStick && $0 != .rightStick && down($0) }) { return .press }
        let directions: [GameGamepadState.Button] = [.up, .down, .left, .right]
        let before = directions.filter { old[$0] > 0.5 }, after = directions.filter { new[$0] > 0.5 }
        return !after.isEmpty && after != before ? .direction : nil
    }
}
