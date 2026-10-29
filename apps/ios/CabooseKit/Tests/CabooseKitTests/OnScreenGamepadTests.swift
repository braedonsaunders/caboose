import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// The on-screen controller: each type's layout at every pad size, fingers to controller
/// state, and the keys it holds in windows that do not take a controller.
struct OnScreenGamepadTests {
    typealias Pad = OnScreenGamepad

    /// The panel below an iPhone Duo's hinge, a flat phone's manual Laptop panel, a landscape
    /// and a portrait phone, an iPad's lower half, and two awkward ones.
    static let sizes: [CGSize] = [
        CGSize(width: 620, height: 290), CGSize(width: 334, height: 380), CGSize(width: 844, height: 390),
        CGSize(width: 390, height: 760), CGSize(width: 1180, height: 400), CGSize(width: 1024, height: 700),
        CGSize(width: 300, height: 200), CGSize(width: 700, height: 330),
    ]

    let phone = CGSize(width: 844, height: 390)

    func layout(_ style: Pad.Style, _ size: CGSize? = nil, _ change: (inout Pad.Settings) -> Void = { _ in }) -> Pad.Layout {
        var settings = Pad.Settings()
        change(&settings)
        return Pad.layout(in: size ?? phone, style: style, settings: settings)
    }

    func center(_ control: Pad.Control, _ layout: Pad.Layout) throws -> CGPoint {
        let frame = try #require(layout.item(control)?.frame)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The shape as a horizontal segment and a radius: a circle is a segment of no length.
    func outline(_ item: Pad.Item) -> (minX: CGFloat, maxX: CGFloat, y: CGFloat, radius: CGFloat) {
        let frame = item.frame
        switch item.shape {
        case .circle:
            return (frame.midX, frame.midX, frame.midY, frame.width / 2)
        case .capsule:
            let radius = min(frame.width, frame.height) / 2
            return (frame.minX + radius, frame.maxX - radius, frame.midY, radius)
        }
    }

    func overlap(_ a: Pad.Item, _ b: Pad.Item) -> Bool {
        let p = outline(a), q = outline(b)
        let dx = max(0, q.minX - p.maxX, p.minX - q.maxX)
        return hypot(dx, p.y - q.y) < p.radius + q.radius - 0.5
    }

    // MARK: Layout

    @Test func everyTypeFitsEveryPadWithoutOverlaps() {
        for style in Pad.Style.allCases {
            for size in Self.sizes {
                for scale in [0.8, 1.0, 1.2] {
                    let pad = layout(style, size) { $0.scale = scale }
                    let bounds = CGRect(origin: .zero, size: size)
                    let context = "\(style) \(size) \(scale)"
                    #expect(!pad.items.isEmpty, "\(context)")
                    #expect(bounds.contains(pad.hud), "\(context) hud \(pad.hud)")
                    for item in pad.items {
                        #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(item.frame), "\(context) \(item.control) \(item.frame)")
                        #expect(!item.frame.intersects(pad.hud), "\(context) \(item.control) under the strip")
                    }
                    for (index, item) in pad.items.enumerated() {
                        for other in pad.items[(index + 1)...] {
                            #expect(!overlap(item, other), "\(context) \(item.control) \(other.control)")
                        }
                    }
                }
            }
        }
        #expect(Pad.layout(in: .zero, style: .modern, settings: Pad.Settings()).items.isEmpty)
    }

    @Test func eachTypeHasItsOwnControls() {
        func controls(_ style: Pad.Style) -> Set<Pad.Control> { Set(layout(style).items.map(\.control)) }
        let modern = controls(.modern)
        #expect(modern.isSuperset(of: [.dpad, .leftStick, .rightStick, .button(.home), .button(.leftTrigger), .button(.rightShoulder)]))
        #expect(controls(.classic) == [.dpad, .button(.south), .button(.east), .button(.west), .button(.north),
                                       .button(.leftShoulder), .button(.rightShoulder), .button(.select), .button(.start)])
        #expect(controls(.retro) == [.dpad, .button(.south), .button(.east), .button(.select), .button(.start)])
        let arcade = controls(.arcade)
        #expect(arcade.contains(.dpad) && !arcade.contains(.leftStick) && arcade.count == 12)
        for style in Pad.Style.allCases {
            // The controls drawn are the buttons the type says it has (stick clicks are the sticks).
            let drawn = Set(controls(style).compactMap { control -> GameGamepadState.Button? in
                if case .button(let button) = control { return button }
                return nil
            })
            #expect(drawn == Set(style.buttons.filter { $0 != .leftStick && $0 != .rightStick }), "\(style)")
            #expect(style.hasSticks == !layout(style).zones.isEmpty)
        }
    }

    @Test func aPortraitPadStacksAndAWidePadSpreads() throws {
        let portrait = layout(.modern, CGSize(width: 390, height: 760))
        let wide = layout(.modern, phone)
        // Portrait puts the strip above the shoulders; a wide pad fits it between them.
        let portraitShoulder = try #require(portrait.item(.button(.leftShoulder))?.frame)
        let wideShoulder = try #require(wide.item(.button(.leftShoulder))?.frame)
        #expect(portrait.hud.maxY <= portraitShoulder.minY)
        #expect(wide.hud.minY < wideShoulder.maxY && wide.hud.maxY > wideShoulder.minY)
        // Portrait's controls are larger than the wide blueprint squeezed to its width would give.
        let stick = try #require(portrait.item(.leftStick)?.frame)
        #expect(stick.width > 120)
        // Thumbs are at the sides: the face buttons hug the right edge of a wide pad.
        let face = try #require(wide.item(.button(.east))?.frame)
        #expect(phone.width - face.maxX < 40)
        // An extra-wide pad opens the middle rather than growing the controls.
        let ipad = layout(.modern, CGSize(width: 1180, height: 400))
        let left = try #require(ipad.item(.leftStick)?.frame), right = try #require(ipad.item(.button(.east))?.frame)
        #expect(left.minX < 60 && 1180 - right.maxX < 60 && left.width < 170)
    }

    @Test func sizeGrowsTheControls() throws {
        let small = try #require(layout(.classic) { $0.scale = 0.8 }.item(.dpad)?.frame)
        let large = try #require(layout(.classic) { $0.scale = 1.2 }.item(.dpad)?.frame)
        #expect(large.width > small.width * 1.4)
    }

    @Test func controlsAreThumbSizedOnAPhone() throws {
        for style in Pad.Style.allCases {
            for size in [phone, CGSize(width: 620, height: 290), CGSize(width: 390, height: 760)] {
                let pad = layout(style, size)
                for item in pad.items where item.cluster == .face {
                    #expect(item.frame.width >= 38, "\(style) \(size) \(item.control) \(item.frame.width)")
                }
                let dpad = try #require(pad.item(.dpad)?.frame)
                #expect(dpad.width >= 84, "\(style) \(size) d-pad \(dpad.width)")
            }
        }
    }

    // MARK: Fingers

    @Test func aTouchPressesTheButtonUnderItAndRollsAcross() throws {
        let pad = layout(.modern)
        var tracker = Pad.Tracker()
        let south = try center(.button(.south), pad), east = try center(.button(.east), pad)
        let radius = try #require(pad.item(.button(.south))?.frame.width) / 2
        tracker.began(1, at: CGPoint(x: south.x, y: south.y + radius * 1.2), time: 0, in: pad, sticks: .floating)
        // A thumb just off the button still presses it.
        var state = tracker.state(in: pad)
        #expect(state[.south] == 1 && state[.east] == 0)
        // Sliding into the seam presses both; on across, only the next.
        tracker.moved(1, to: CGPoint(x: (south.x + east.x) / 2, y: (south.y + east.y) / 2), in: pad, sticks: .floating)
        state = tracker.state(in: pad)
        #expect(state[.south] == 1 && state[.east] == 1)
        tracker.moved(1, to: east, in: pad, sticks: .floating)
        state = tracker.state(in: pad)
        #expect(state[.south] == 0 && state[.east] == 1)
        // Off the cluster altogether, nothing.
        tracker.moved(1, to: CGPoint(x: east.x, y: east.y + radius * 6), in: pad, sticks: .floating)
        state = tracker.state(in: pad)
        #expect(state[.south] == 0 && state[.east] == 0)
        tracker.ended(1, at: 0.5, in: pad)
        #expect(tracker.isEmpty && tracker.state(in: pad) == GameGamepadState())
    }

    @Test func buttonsAcrossTheDiamondAreNeverChorded() throws {
        for style in [Pad.Style.modern, .classic] {
            let pad = layout(style)
            let west = try center(.button(.west), pad), east = try center(.button(.east), pad)
            var tracker = Pad.Tracker()
            tracker.began(1, at: CGPoint(x: (west.x + east.x) / 2, y: west.y), time: 0, in: pad, sticks: .floating)
            let state = tracker.state(in: pad)
            #expect(!(state[.west] == 1 && state[.east] == 1), "\(style)")
        }
    }

    @Test func theArcadePanelChordsNeighboursInARowAndAColumn() throws {
        let pad = layout(.arcade)
        let x = try center(.button(.west), pad), y = try center(.button(.north), pad), a = try center(.button(.south), pad)
        var tracker = Pad.Tracker()
        tracker.began(1, at: CGPoint(x: (x.x + y.x) / 2, y: (x.y + y.y) / 2), time: 0, in: pad, sticks: .floating)
        tracker.began(2, at: CGPoint(x: (x.x + a.x) / 2, y: (x.y + a.y) / 2), time: 0, in: pad, sticks: .floating)
        let state = tracker.state(in: pad)
        #expect(state[.west] == 1 && state[.north] == 1 && state[.south] == 1)
        // Rolling from a punch down onto a trigger presses it fully.
        var roll = Pad.Tracker()
        let rb = try center(.button(.rightShoulder), pad), rt = try center(.button(.rightTrigger), pad)
        roll.began(1, at: rb, time: 0, in: pad, sticks: .floating)
        roll.moved(1, to: rt, in: pad, sticks: .floating)
        #expect(roll.state(in: pad)[.rightTrigger] == 1)
    }

    @Test func shouldersChordInTheirSeamAndTriggersEaseOff() throws {
        let pad = layout(.modern)
        let lt = try #require(pad.item(.button(.leftTrigger))?.frame), lb = try #require(pad.item(.button(.leftShoulder))?.frame)
        var tracker = Pad.Tracker()
        tracker.began(1, at: CGPoint(x: (lt.maxX + lb.minX) / 2, y: lt.midY), time: 0, in: pad, sticks: .floating)
        var state = tracker.state(in: pad)
        #expect(state[.leftTrigger] == 1 && state[.leftShoulder] == 1)
        tracker.ended(1, at: 0.1, in: pad)

        tracker.began(2, at: CGPoint(x: lt.midX, y: lt.midY), time: 1, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftTrigger] == 1 && tracker.state(in: pad)[.leftShoulder] == 0)
        tracker.moved(2, to: CGPoint(x: lt.midX, y: lt.midY + lt.height), in: pad, sticks: .floating)
        state = tracker.state(in: pad)
        #expect(abs(state[.leftTrigger] - 0.5) < 0.01)
        tracker.moved(2, to: CGPoint(x: lt.midX, y: lt.midY + lt.height * 5), in: pad, sticks: .floating)
        #expect(abs(tracker.state(in: pad)[.leftTrigger] - 0.15) < 0.01)
        tracker.moved(2, to: CGPoint(x: lt.midX, y: lt.midY - 10), in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftTrigger] == 1)
    }

    @Test func aFloatingStickCentresUnderTheThumbAndFollowsIt() throws {
        let pad = layout(.modern)
        let zone = try #require(pad.zones[.leftStick])
        let stick = try #require(pad.item(.leftStick)?.frame)
        let radius = stick.width / 2
        // Somewhere on the left that is not a control.
        let landing = CGPoint(x: zone.minX + 4, y: zone.maxY - 4)
        #expect(Pad.cluster(at: landing, in: pad, sticks: .floating) == .leftStick)
        #expect(Pad.cluster(at: landing, in: pad, sticks: .fixed) == nil)
        var tracker = Pad.Tracker()
        tracker.began(1, at: landing, time: 0, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftX] == 0)
        #expect(tracker.stickCenters[.leftStick] == landing)
        tracker.moved(1, to: CGPoint(x: landing.x + radius * 0.475, y: landing.y), in: pad, sticks: .floating)
        #expect(abs(tracker.state(in: pad)[.leftX] - 0.5) < 0.001)
        // Past the rim the centre follows, so a reversal answers at once.
        tracker.moved(1, to: CGPoint(x: landing.x + radius * 3, y: landing.y), in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftX] == 1)
        tracker.moved(1, to: CGPoint(x: landing.x + radius * 1.5, y: landing.y), in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftX] < -0.5)
        // A second thumb on the same side does not take the stick from the first.
        tracker.began(2, at: CGPoint(x: landing.x + 2, y: landing.y - 2), time: 0.1, in: pad, sticks: .floating)
        #expect(tracker.heldClusters == [.leftStick])
    }

    @Test func aFixedStickStaysPutAndSaturatesAtItsRim() throws {
        let pad = layout(.modern)
        let stick = try #require(pad.item(.rightStick)?.frame)
        let middle = CGPoint(x: stick.midX, y: stick.midY)
        var tracker = Pad.Tracker()
        tracker.began(1, at: CGPoint(x: middle.x + 4, y: middle.y), time: 0, in: pad, sticks: .fixed)
        #expect(tracker.stickCenters[.rightStick] == middle)
        tracker.moved(1, to: CGPoint(x: middle.x, y: middle.y - stick.height * 3), in: pad, sticks: .fixed)
        #expect(tracker.state(in: pad)[.rightY] == -1)
        tracker.moved(1, to: CGPoint(x: middle.x, y: middle.y - stick.height * 0.25), in: pad, sticks: .fixed)
        #expect(tracker.state(in: pad)[.rightY] < -0.4)
        #expect(tracker.stickCenters[.rightStick] == middle)
    }

    @Test func aTapThenPressClicksTheStick() throws {
        let pad = layout(.modern)
        let stick = try center(.leftStick, pad)
        var tracker = Pad.Tracker()
        tracker.began(1, at: stick, time: 0, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftStick] == 0)
        tracker.ended(1, at: 0.1, in: pad)
        tracker.began(2, at: stick, time: 0.25, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftStick] == 1)
        // The clicked stick still steers.
        tracker.moved(2, to: CGPoint(x: stick.x + 200, y: stick.y), in: pad, sticks: .floating)
        let state = tracker.state(in: pad)
        #expect(state[.leftStick] == 1 && state[.leftX] == 1)
        tracker.ended(2, at: 1, in: pad)
        // A slow second press is just a press.
        tracker.began(3, at: stick, time: 1.6, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftStick] == 0)
        tracker.ended(3, at: 1.7, in: pad)
        tracker.began(4, at: stick, time: 2.5, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.leftStick] == 0)
    }

    @Test func theDpadHasEightDirections() throws {
        let pad = layout(.classic)
        let dpad = try #require(pad.item(.dpad)?.frame)
        func pressed(_ dx: CGFloat, _ dy: CGFloat) -> Set<GameGamepadState.Button> {
            var tracker = Pad.Tracker()
            tracker.began(1, at: CGPoint(x: dpad.midX + dx * dpad.width / 2, y: dpad.midY + dy * dpad.height / 2), time: 0, in: pad, sticks: .floating)
            let state = tracker.state(in: pad)
            return Set([GameGamepadState.Button.up, .down, .left, .right].filter { state[$0] == 1 })
        }
        #expect(pressed(0, -0.8) == [.up])
        #expect(pressed(0.8, 0) == [.right])
        #expect(pressed(0.6, 0.6) == [.right, .down])
        #expect(pressed(-0.6, -0.6) == [.left, .up])
        #expect(pressed(0.05, 0.05).isEmpty)
        // The lever and its finger keep their direction past the d-pad's edge.
        #expect(pressed(-1.3, 0) == [.left])
    }

    @Test func letGoReleasesEverythingUntilTheFingersLift() throws {
        let pad = layout(.modern)
        var tracker = Pad.Tracker()
        tracker.began(1, at: try center(.button(.south), pad), time: 0, in: pad, sticks: .floating)
        tracker.began(2, at: try center(.leftStick, pad), time: 0, in: pad, sticks: .floating)
        tracker.disown()
        #expect(tracker.state(in: pad) == GameGamepadState() && !tracker.isEmpty)
        tracker.moved(2, to: CGPoint(x: 0, y: 0), in: pad, sticks: .floating)
        #expect(tracker.state(in: pad) == GameGamepadState())
        tracker.began(3, at: try center(.button(.north), pad), time: 1, in: pad, sticks: .floating)
        #expect(tracker.state(in: pad)[.north] == 1)
        tracker.clear()
        #expect(tracker.isEmpty)
    }

    @Test func stickResponseHasADeadzoneAndSaturates() {
        #expect(Pad.stickAxes(CGVector(dx: 5, dy: 0), radius: 100) == (0, 0))
        #expect(Pad.stickAxes(CGVector(dx: 85, dy: 0), radius: 100).x == 1)
        let diagonal = Pad.stickAxes(CGVector(dx: 300, dy: 300), radius: 100)
        #expect(abs(hypot(diagonal.x, diagonal.y) - 1) < 0.0001)
        #expect(Pad.stickAxes(CGVector(dx: 10, dy: 10), radius: 0) == (0, 0))
    }

    // MARK: Keys

    @Test func controlsHoldTheirKeysAndReleaseThem() {
        var settings = Pad.Settings()
        var jump = GameGamepadState()
        jump[.south] = 1
        jump[.up] = 1
        jump[.leftX] = -0.9
        #expect(Pad.keys(for: jump, settings: settings) == ["space", "Up", "Left"])
        let pressed = Pad.keyChanges(from: GameGamepadState(), to: jump, settings: settings)
        #expect(pressed.allSatisfy { $0.pressed } && pressed.count == 3)
        var next = jump
        next[.south] = 0
        let changes = Pad.keyChanges(from: jump, to: next, settings: settings)
        #expect(changes.map { $0.name } == ["space"] && changes.map { $0.pressed } == [false])
        let released = Pad.keyChanges(from: next, to: GameGamepadState(), settings: settings)
        #expect(Set(released.map { $0.name }) == ["Up", "Left"] && released.allSatisfy { !$0.pressed })
        // The right stick is W A S D by default; None presses nothing.
        var look = GameGamepadState()
        look[.rightY] = -1
        #expect(Pad.keys(for: look, settings: settings) == ["w"])
        var quiet = settings
        quiet.rightStickKeys = .none
        quiet.keys["south"] = ""
        #expect(Pad.keys(for: look, settings: quiet).isEmpty)
        #expect(Pad.keys(for: jump, settings: quiet) == ["Up", "Left"])
        // Guide and the stick clicks take keys too; an eased-off trigger lets its key go.
        settings.keys["home"] = "Escape"
        settings.keys["leftStick"] = "Shift_L"
        var extra = GameGamepadState()
        extra[.home] = 1
        extra[.leftStick] = 1
        extra[.rightTrigger] = 0.3
        #expect(Pad.keys(for: extra, settings: settings) == ["Escape", "Shift_L"])
    }

    @Test func everyKeyChoiceIsAKeystroke() {
        for choice in Pad.keyChoices where !choice.name.isEmpty {
            #expect(Pad.stroke(for: choice.name) != nil, "\(choice.name)")
        }
        for key in Pad.defaultKeys.values { #expect(Pad.stroke(for: key) != nil, "\(key)") }
        #expect(Pad.stroke(for: "space")?.keyval == 0x20)
        #expect(Pad.stroke(for: "nonsense") == nil)
    }

    // MARK: Settings

    @Test func storedSettingsSurviveAndBadOnesFallBack() {
        var settings = Pad.Settings()
        settings.choose(.retro, for: "fceux")
        settings.labels = .playstation
        settings.sticks = .fixed
        settings.games = .keys
        settings.keys["start"] = "p"
        #expect(Pad.Settings.decode(settings.encoded) == settings)
        #expect(Pad.Settings.decode(nil) == Pad.Settings())
        #expect(Pad.Settings.decode(Data("nope".utf8)) == Pad.Settings())
        let partial = Pad.Settings.decode(Data(#"{"left":"stick","showsRightStick":true,"scale":9,"keys":{"south":"x"},"appStyles":{"a":"retro","b":"hologram"}}"#.utf8))
        #expect(partial.scale == 1.2 && partial.keys == ["south": "x"] && partial.style == .modern)
        #expect(partial.appStyles == ["a": .retro])
    }

    @Test func eachAppRemembersItsController() {
        var settings = Pad.Settings()
        #expect(settings.style(for: "fceux") == .modern && settings.style(for: nil) == .modern)
        settings.choose(.retro, for: "fceux")
        settings.choose(.arcade, for: "mame")
        #expect(settings.style(for: "fceux") == .retro && settings.style(for: "mame") == .arcade)
        // A new app starts with the type chosen last.
        #expect(settings.style(for: "dosbox") == .arcade)
        settings.choose(.classic, for: nil)
        #expect(settings.style(for: "dosbox") == .classic && settings.style(for: "fceux") == .retro)
    }

    @Test func buttonsAreLabelledLikeTheControllersTheyRecall() {
        #expect(Pad.label(.south, style: .classic).name == "B" && Pad.label(.east, style: .classic).name == "A")
        #expect(Pad.label(.north, style: .classic).name == "X" && Pad.label(.leftShoulder, style: .retro).name == "L")
        #expect(Pad.label(.south, style: .modern).name == "A" && Pad.label(.leftTrigger, style: .modern).name == "LT")
        #expect(Pad.label(.south, style: .modern, labels: .playstation).symbol == "xmark")
        #expect(Pad.label(.rightTrigger, style: .arcade, labels: .playstation).name == "R2")
        // Classic and Retro keep their own markings whatever the labels setting.
        #expect(Pad.label(.east, style: .retro, labels: .playstation).name == "A")
        for style in Pad.Style.allCases {
            for button in style.buttons { #expect(!Pad.label(button, style: style).name.isEmpty) }
        }
    }

    @Test func feedbackMarksPressesDirectionsAndClicks() {
        var pressed = GameGamepadState()
        pressed[.south] = 1
        #expect(Pad.feedback(from: GameGamepadState(), to: pressed) == .press)
        #expect(Pad.feedback(from: pressed, to: GameGamepadState()) == nil)
        #expect(Pad.feedback(from: pressed, to: pressed) == nil)
        var up = GameGamepadState()
        up[.up] = 1
        var upRight = up
        upRight[.right] = 1
        #expect(Pad.feedback(from: GameGamepadState(), to: up) == .direction)
        #expect(Pad.feedback(from: up, to: upRight) == .direction)
        #expect(Pad.feedback(from: upRight, to: GameGamepadState()) == nil)
        var click = GameGamepadState()
        click[.rightStick] = 1
        click[.east] = 1
        #expect(Pad.feedback(from: GameGamepadState(), to: click) == .click)
    }
}
