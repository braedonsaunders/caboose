import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Laptop's on-screen gamepad: its layout, touches to controller state, and the keys it holds
/// in windows that do not take a controller.
struct LaptopGamepadTests {
    let size = CGSize(width: 620, height: 330)

    func frame(_ control: LaptopGamepad.Control, _ items: [LaptopGamepad.Item]) -> CGRect? {
        items.first { $0.control == control }?.frame
    }

    @Test func everyControlFitsAndNoneOverlap() {
        var settings = LaptopGamepad.Settings()
        settings.showsRightStick = true
        for scale in [0.8, 1.0, 1.25] {
            settings.scale = scale
            let items = LaptopGamepad.items(in: size, settings: settings)
            for item in items { #expect(CGRect(origin: .zero, size: size).contains(item.frame), "\(item.control)") }
            for (index, item) in items.enumerated() {
                for other in items[(index + 1)...] where item.control != .dpad && other.control != .dpad {
                    #expect(!item.frame.insetBy(dx: 1, dy: 1).intersects(other.frame.insetBy(dx: 1, dy: 1)), "\(item.control) \(other.control)")
                }
            }
        }
        #expect(LaptopGamepad.items(in: .zero, settings: settings).isEmpty)
    }

    @Test func theSettingsChooseTheControls() {
        var settings = LaptopGamepad.Settings()
        var controls = Set(LaptopGamepad.items(in: size, settings: settings).map(\.control))
        #expect(controls.contains(.dpad) && !controls.contains(.leftStick) && !controls.contains(.rightStick))
        #expect(controls.contains(.button(.leftTrigger)) && controls.contains(.button(.start)))
        for button in [GameGamepadState.Button.south, .east, .west, .north] { #expect(controls.contains(.button(button))) }
        settings.left = .stick
        settings.showsRightStick = true
        settings.showsTriggers = false
        controls = Set(LaptopGamepad.items(in: size, settings: settings).map(\.control))
        #expect(controls.contains(.leftStick) && controls.contains(.rightStick) && !controls.contains(.dpad))
        #expect(!controls.contains(.button(.leftTrigger)) && controls.contains(.button(.leftShoulder)))
    }

    @Test func aTouchPressesTheControlUnderIt() throws {
        let items = LaptopGamepad.items(in: size, settings: LaptopGamepad.Settings())
        let south = try #require(frame(.button(.south), items))
        #expect(LaptopGamepad.control(at: CGPoint(x: south.midX, y: south.midY), in: items) == .button(.south))
        // A thumb just off the button still presses it.
        #expect(LaptopGamepad.control(at: CGPoint(x: south.midX, y: south.maxY + 3), in: items) == .button(.south))
        #expect(LaptopGamepad.control(at: CGPoint(x: size.width / 2, y: size.height - 2), in: items) == nil)
        let state = LaptopGamepad.state(held: [(.button(.south), .zero)], items: items)
        #expect(state[.south] == 1 && state[.east] == 0)
    }

    @Test func theDpadHasEightDirections() throws {
        let items = LaptopGamepad.items(in: size, settings: LaptopGamepad.Settings())
        let dpad = try #require(frame(.dpad, items))
        func pressed(_ dx: CGFloat, _ dy: CGFloat) -> Set<GameGamepadState.Button> {
            let state = LaptopGamepad.state(held: [(.dpad, CGPoint(x: dpad.midX + dx * dpad.width / 2, y: dpad.midY + dy * dpad.height / 2))], items: items)
            return Set([GameGamepadState.Button.up, .down, .left, .right].filter { state[$0] == 1 })
        }
        #expect(pressed(0, -0.8) == [.up])
        #expect(pressed(0.8, 0) == [.right])
        #expect(pressed(0.6, 0.6) == [.right, .down])
        #expect(pressed(-0.6, -0.6) == [.left, .up])
        #expect(pressed(0.05, 0.05).isEmpty)
    }

    @Test func aStickIsAnalogAndStopsAtItsEdge() throws {
        var settings = LaptopGamepad.Settings()
        settings.left = .stick
        let items = LaptopGamepad.items(in: size, settings: settings)
        let stick = try #require(frame(.leftStick, items))
        let half = LaptopGamepad.state(held: [(.leftStick, CGPoint(x: stick.midX + stick.width / 4, y: stick.midY))], items: items)
        #expect(abs(half[.leftX] - 0.5) < 0.001 && half[.leftY] == 0)
        let far = LaptopGamepad.state(held: [(.leftStick, CGPoint(x: stick.midX, y: stick.minY - stick.height))], items: items)
        #expect(abs(far[.leftY] + 1) < 0.001)
        let rest = LaptopGamepad.state(held: [(.leftStick, CGPoint(x: stick.midX + 1, y: stick.midY))], items: items)
        #expect(rest[.leftX] == 0)
    }

    @Test func controlsHoldTheirKeysAndReleaseThem() {
        let settings = LaptopGamepad.Settings()
        var jump = GameGamepadState()
        jump[.south] = 1
        jump[.up] = 1
        jump[.leftX] = -0.9
        #expect(LaptopGamepad.keys(for: jump, settings: settings) == ["space", "Up", "Left"])
        let pressed = LaptopGamepad.keyChanges(from: GameGamepadState(), to: jump, settings: settings)
        #expect(pressed.allSatisfy { $0.pressed } && pressed.count == 3)
        var next = jump
        next[.south] = 0
        let changes = LaptopGamepad.keyChanges(from: jump, to: next, settings: settings)
        #expect(changes.map { $0.name } == ["space"] && changes.map { $0.pressed } == [false])
        let released = LaptopGamepad.keyChanges(from: next, to: GameGamepadState(), settings: settings)
        #expect(Set(released.map { $0.name }) == ["Up", "Left"] && released.allSatisfy { !$0.pressed })
        // The right stick is W A S D by default; None presses nothing.
        var look = GameGamepadState()
        look[.rightY] = -1
        #expect(LaptopGamepad.keys(for: look, settings: settings) == ["w"])
        var quiet = settings
        quiet.rightStickKeys = .none
        quiet.keys["south"] = ""
        #expect(LaptopGamepad.keys(for: look, settings: quiet).isEmpty)
        #expect(LaptopGamepad.keys(for: jump, settings: quiet) == ["Up", "Left"])
    }

    @Test func everyKeyChoiceIsAKeystroke() {
        for choice in LaptopGamepad.keyChoices where !choice.name.isEmpty {
            #expect(LaptopGamepad.stroke(for: choice.name) != nil, "\(choice.name)")
        }
        for key in LaptopGamepad.defaultKeys.values { #expect(LaptopGamepad.stroke(for: key) != nil, "\(key)") }
        #expect(LaptopGamepad.stroke(for: "space")?.keyval == 0x20)
        #expect(LaptopGamepad.stroke(for: "nonsense") == nil)
    }

    @Test func storedSettingsSurviveAndBadOnesFallBack() {
        var settings = LaptopGamepad.Settings()
        settings.left = .stick
        settings.games = .keys
        settings.keys["start"] = "p"
        #expect(LaptopGamepad.Settings.decode(settings.encoded) == settings)
        #expect(LaptopGamepad.Settings.decode(nil) == LaptopGamepad.Settings())
        #expect(LaptopGamepad.Settings.decode(Data("nope".utf8)) == LaptopGamepad.Settings())
        let partial = LaptopGamepad.Settings.decode(Data(#"{"showsRightStick":true,"scale":9}"#.utf8))
        #expect(partial.showsRightStick && partial.scale == 1.25 && partial.keys == LaptopGamepad.defaultKeys)
    }
}
