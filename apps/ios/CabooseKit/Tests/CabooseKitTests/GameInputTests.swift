import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// The app's own controls aimed at a game window become DOM events for its page
/// (docs/game-handoff.md, "Input"), and everything held is released when the page loses them.
@MainActor struct GameInputTests {
    let size = CGSize(width: 2560, height: 1600)

    func keys(_ events: [GameInputEvent]) -> [String] {
        events.compactMap { event in event.key.map { "\(event.kind == .keyDown ? "+" : "-")\($0.code.isEmpty ? $0.key : $0.code)" } }
    }

    @Test func pointerPositionsAreFractionsOfTheWindowAtAnyScale() {
        var input = GameInput()
        let move = input.move(to: CGPoint(x: 640, y: 1200), in: size)
        #expect(move == [GameInputEvent(kind: .pointerMove, x: 0.25, y: 0.75)])
        // The same spot in a window half the pixels (a different device scale) is the same fraction.
        #expect(input.move(to: CGPoint(x: 320, y: 600), in: CGSize(width: 1280, height: 800)) == move)
        #expect(GameInput.fraction(CGPoint(x: -5, y: 9999), in: size) == CGPoint(x: 0, y: 1))
        #expect(GameInput.fraction(CGPoint(x: 5, y: 5), in: .zero) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func xButtonsBecomeDOMButtons() {
        #expect(GameInput.domButton(forXButton: 1).map { [$0.button, $0.bit] } == [0, 1])
        #expect(GameInput.domButton(forXButton: 2).map { [$0.button, $0.bit] } == [1, 4])
        #expect(GameInput.domButton(forXButton: 3).map { [$0.button, $0.bit] } == [2, 2])
        #expect(GameInput.domButton(forXButton: 8).map { [$0.button, $0.bit] } == [3, 8])
        #expect(GameInput.domButton(forXButton: 9).map { [$0.button, $0.bit] } == [4, 16])
        #expect(GameInput.domButton(forXButton: 4) == nil)
        var input = GameInput()
        let point = CGPoint(x: 1280, y: 800)
        let down = input.button(1, pressed: true, at: point, in: size)
        #expect(down.map(\.kind) == [.pointerDown])
        #expect(down.last?.button == 0 && down.last?.buttons == 1)
        let right = input.button(3, pressed: true, at: point, in: size)
        #expect(right.last?.button == 2 && right.last?.buttons == 3)
        // A press of a button already down, or a release of one that is up, is no event.
        #expect(input.button(1, pressed: true, at: point, in: size).isEmpty)
        #expect(input.button(2, pressed: false, at: point, in: size).isEmpty)
        let up = input.button(1, pressed: false, at: CGPoint(x: 0, y: 0), in: size)
        #expect(up.map(\.kind) == [.pointerMove, .pointerUp])
        #expect(up.last?.button == 0 && up.last?.buttons == 2 && up.last?.x == 0)
    }

    @Test func scrollingIsAFractionOfTheWindowToo() {
        var input = GameInput()
        let wheel = input.scroll(dx: 0, dy: 160, at: CGPoint(x: 1280, y: 800), in: size)
        #expect(wheel.count == 1 && wheel[0].kind == .wheel && wheel[0].dy == 0.1 && wheel[0].dx == 0)
        #expect(input.scroll(dx: 0, dy: 0, at: .zero, in: size).isEmpty)
    }

    @Test func keysMapToTheirDOMKeys() {
        func key(_ stroke: KeyStroke?) -> GameKey? { stroke.flatMap(GameKey.key(for:)) }
        #expect(key(Keysyms.stroke(for: "a")) == GameKey(key: "a", code: "KeyA", keyCode: 65, location: 0, text: "a"))
        #expect(key(Keysyms.stroke(for: "A")) == GameKey(key: "A", code: "KeyA", keyCode: 65, location: 0, text: "A"))
        #expect(key(Keysyms.stroke(for: "7")) == GameKey(key: "7", code: "Digit7", keyCode: 55, location: 0, text: "7"))
        #expect(key(Keysyms.stroke(for: "[")) == GameKey(key: "[", code: "BracketLeft", keyCode: 219, location: 0, text: "["))
        #expect(key(Keysyms.stroke(for: "?"))?.code == "Slash")
        #expect(key(Keysyms.stroke(for: " "))?.code == "Space")
        #expect(key(Keysyms.stroke(for: "é")) == GameKey(key: "é", code: "", keyCode: 0, location: 0, text: "é"))
        #expect(key(Keysyms.stroke(for: "😀"))?.text == "😀")
        #expect(key(Keysyms.special["F1"]) == GameKey(key: "F1", code: "F1", keyCode: 112, location: 0))
        #expect(key(Keysyms.special["Left"])?.key == "ArrowLeft")
        #expect(key(Keysyms.special["Return"])?.keyCode == 13)
        #expect(key(Keysyms.special["Control_L"]) == GameKey(key: "Control", code: "ControlLeft", keyCode: 17, location: 1))
        #expect(key(KeyStroke(name: "none", keyval: 0xFE20)) == nil)
    }

    @Test func aShortcutPressesItsModifiersAroundTheKey() {
        var input = GameInput()
        let c = Keysyms.stroke(for: "c")!
        let down = input.key(c, pressed: true, extraModifiers: ["control"])
        #expect(keys(down) == ["+ControlLeft", "+KeyC"])
        #expect(down.last?.modifiers.control == true)
        // Control makes it a shortcut: nothing is typed.
        #expect(down.last?.key?.text == nil)
        #expect(keys(input.key(c, pressed: false, extraModifiers: ["control"])) == ["-KeyC", "-ControlLeft"])
        #expect(input.held.isEmpty)
    }

    @Test func aShiftedCharacterPressesShift() {
        var input = GameInput()
        let events = input.type("R!")
        #expect(keys(events) == ["+ShiftLeft", "+KeyR", "-KeyR", "-ShiftLeft", "+ShiftLeft", "+Digit1", "-Digit1", "-ShiftLeft"])
        #expect(events[1].modifiers.shift && events[1].key?.text == "R")
        #expect(input.held.isEmpty)
    }

    @Test func aModifierHeldByItselfStaysHeld() {
        var input = GameInput()
        let shift = Keysyms.special["Shift_L"]!
        #expect(keys(input.key(shift, pressed: true)) == ["+ShiftLeft"])
        let a = Keysyms.stroke(for: "A")!
        #expect(keys(input.key(a, pressed: true)) == ["+KeyA"])
        #expect(keys(input.key(a, pressed: false)) == ["-KeyA"])
        #expect(keys(input.key(shift, pressed: false)) == ["-ShiftLeft"])
    }

    @Test func aKeyUpWithoutItsKeyDownIsNoEvent() {
        var input = GameInput()
        #expect(input.key(Keysyms.special["Left"]!, pressed: false).isEmpty)
    }

    @Test func textAndBackspaceAreKeyTaps() {
        var input = GameInput()
        #expect(keys(input.type("a\r\n")) == ["+KeyA", "-KeyA", "+Enter", "-Enter"])
        #expect(keys(input.backspace(2)) == ["+Backspace", "-Backspace", "+Backspace", "-Backspace"])
        #expect(input.backspace(0).isEmpty)
    }

    @Test func releasingLetsGoOfEverythingHeld() {
        var input = GameInput()
        _ = input.key(Keysyms.special["Shift_L"]!, pressed: true)
        _ = input.key(Keysyms.special["Up"]!, pressed: true)
        _ = input.button(1, pressed: true, at: .zero, in: size)
        _ = input.button(3, pressed: true, at: .zero, in: size)
        let released = input.release()
        #expect(keys(released) == ["-ArrowUp", "-ShiftLeft"])
        #expect(released.filter { $0.kind == .pointerCancel }.map(\.button) == [0, 2])
        #expect(released.last?.buttons == 0)
        #expect(input.release().isEmpty)
        #expect(input.buttons == 0 && input.held.isEmpty)
    }

    @Test func theScriptCallCarriesEveryField() throws {
        var event = GameInputEvent(kind: .keyDown, key: GameKey(key: "a", code: "KeyA", keyCode: 65, location: 0, text: "a"))
        event.modifiers.shift = true
        let call = GameInputScript.call([event, GameInputEvent(kind: .wheel, x: 0.5, y: 0.25, dx: 0, dy: 0.1)])
        let events = try #require(call.arguments["events"] as? [[String: Any]])
        #expect(events[0]["type"] as? String == "keydown" && events[0]["code"] as? String == "KeyA")
        #expect(events[0]["keyCode"] as? Int == 65 && events[0]["text"] as? String == "a" && events[0]["shift"] as? Bool == true)
        #expect(events[1]["type"] as? String == "wheel" && events[1]["dy"] as? Double == 0.1 && events[1]["y"] as? Double == 0.25)
        #expect(GameInputScript.source.contains("cabooseInput"))
    }

    @Test func aGameTakesInputOnlyWhileItRuns() {
        let game = RemoteGame(GameDescriptor(id: 1, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface())
        var delivered: [[GameInputEvent]] = []
        game.inputSink = { delivered.append($0) }
        game.key(Keysyms.special["Up"]!, pressed: true)
        game.edit([.type("x"), .backspace(1)])
        game.releaseInput()
        #expect(delivered.map { keys($0) } == [["+ArrowUp"], ["+KeyX", "-KeyX"], ["+Backspace", "-Backspace"], ["-ArrowUp"]])
        game.end()
        game.key(Keysyms.special["Up"]!, pressed: true)
        #expect(delivered.count == 4)
    }
}
