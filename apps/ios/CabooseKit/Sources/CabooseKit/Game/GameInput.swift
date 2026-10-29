import CoreGraphics
import Foundation

/// A key as a game page's `KeyboardEvent` describes it, on a US layout.
public struct GameKey: Equatable, Sendable {
    public var key: String
    public var code: String
    /// The legacy `keyCode` (and `which`), which Emscripten and older pages still read.
    public var keyCode: Int
    /// 0 for most keys, 1 and 2 for the left and right modifiers.
    public var location: Int
    /// What a `keypress` for the key types, if it types anything.
    public var text: String?

    /// The modifier this key is (`shift`, `control`, `mod1`, `mod4`), if it is one.
    public var modifier: String? {
        switch key {
        case "Shift": "shift"
        case "Control": "control"
        case "Alt": "mod1"
        case "Meta": "mod4"
        default: nil
        }
    }

    /// The key that types `stroke` (an X keysym), or nil for a keysym a page has no key for.
    public static func key(for stroke: KeyStroke) -> GameKey? {
        if let special = special[stroke.keyval] { return special }
        // Latin-1 keysyms are their characters; 0x01000000 plus a code point is any other one.
        // The rest (0xFE00–0xFFFF and the like) are keys without a character.
        let scalarValue = stroke.keyval >= 0x0100_0000 ? stroke.keyval - 0x0100_0000 : stroke.keyval
        guard stroke.keyval < 0x100 || stroke.keyval >= 0x0100_0000,
              (0x20 ... 0x10FFFF).contains(scalarValue), !(0x7F ... 0x9F).contains(scalarValue),
              let scalar = Unicode.Scalar(UInt32(scalarValue)) else { return nil }
        let character = Character(scalar)
        let text = String(character)
        switch scalarValue {
        case 0x20:
            return GameKey(key: " ", code: "Space", keyCode: 32, location: 0, text: " ")
        case 0x61 ... 0x7A, 0x41 ... 0x5A:
            let upper = text.uppercased()
            return GameKey(key: text, code: "Key" + upper, keyCode: Int(upper.unicodeScalars.first!.value), location: 0, text: text)
        case 0x30 ... 0x39:
            return GameKey(key: text, code: "Digit" + text, keyCode: scalarValue, location: 0, text: text)
        default:
            if let (code, keyCode) = punctuation[character] {
                return GameKey(key: text, code: code, keyCode: keyCode, location: 0, text: text)
            }
            // A character with no key on a US layout still types: no code, no legacy code.
            return GameKey(key: text, code: "", keyCode: 0, location: 0, text: text)
        }
    }

    /// The modifier keys by the names display key events carry them under.
    static func modifier(_ name: String) -> GameKey? {
        switch name {
        case "shift": special[0xFFE1]
        case "control": special[0xFFE3]
        case "mod1", "alt": special[0xFFE9]
        case "mod4", "super", "meta": special[0xFFEB]
        default: nil
        }
    }

    private static let special: [Int: GameKey] = {
        var keys: [Int: GameKey] = [
            0xFF0D: GameKey(key: "Enter", code: "Enter", keyCode: 13, location: 0, text: "\r"),
            0xFF08: GameKey(key: "Backspace", code: "Backspace", keyCode: 8, location: 0),
            0xFF09: GameKey(key: "Tab", code: "Tab", keyCode: 9, location: 0),
            0xFF1B: GameKey(key: "Escape", code: "Escape", keyCode: 27, location: 0),
            0xFFFF: GameKey(key: "Delete", code: "Delete", keyCode: 46, location: 0),
            0xFF50: GameKey(key: "Home", code: "Home", keyCode: 36, location: 0),
            0xFF51: GameKey(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, location: 0),
            0xFF52: GameKey(key: "ArrowUp", code: "ArrowUp", keyCode: 38, location: 0),
            0xFF53: GameKey(key: "ArrowRight", code: "ArrowRight", keyCode: 39, location: 0),
            0xFF54: GameKey(key: "ArrowDown", code: "ArrowDown", keyCode: 40, location: 0),
            0xFF55: GameKey(key: "PageUp", code: "PageUp", keyCode: 33, location: 0),
            0xFF56: GameKey(key: "PageDown", code: "PageDown", keyCode: 34, location: 0),
            0xFF57: GameKey(key: "End", code: "End", keyCode: 35, location: 0),
            0xFFE1: GameKey(key: "Shift", code: "ShiftLeft", keyCode: 16, location: 1),
            0xFFE2: GameKey(key: "Shift", code: "ShiftRight", keyCode: 16, location: 2),
            0xFFE3: GameKey(key: "Control", code: "ControlLeft", keyCode: 17, location: 1),
            0xFFE4: GameKey(key: "Control", code: "ControlRight", keyCode: 17, location: 2),
            0xFFE9: GameKey(key: "Alt", code: "AltLeft", keyCode: 18, location: 1),
            0xFFEA: GameKey(key: "Alt", code: "AltRight", keyCode: 18, location: 2),
            0xFFE7: GameKey(key: "Meta", code: "MetaLeft", keyCode: 91, location: 1),
            0xFFEB: GameKey(key: "Meta", code: "MetaLeft", keyCode: 91, location: 1),
            0xFFEC: GameKey(key: "Meta", code: "MetaRight", keyCode: 92, location: 2),
        ]
        for number in 1 ... 12 {
            keys[0xFFBD + number] = GameKey(key: "F\(number)", code: "F\(number)", keyCode: 111 + number, location: 0)
        }
        return keys
    }()

    /// Each punctuation character's key on a US layout: its `code` and legacy `keyCode`.
    private static let punctuation: [Character: (String, Int)] = [
        "-": ("Minus", 189), "_": ("Minus", 189), "=": ("Equal", 187), "+": ("Equal", 187),
        "[": ("BracketLeft", 219), "{": ("BracketLeft", 219), "]": ("BracketRight", 221), "}": ("BracketRight", 221),
        "\\": ("Backslash", 220), "|": ("Backslash", 220), ";": ("Semicolon", 186), ":": ("Semicolon", 186),
        "'": ("Quote", 222), "\"": ("Quote", 222), ",": ("Comma", 188), "<": ("Comma", 188),
        ".": ("Period", 190), ">": ("Period", 190), "/": ("Slash", 191), "?": ("Slash", 191),
        "`": ("Backquote", 192), "~": ("Backquote", 192),
        "!": ("Digit1", 49), "@": ("Digit2", 50), "#": ("Digit3", 51), "$": ("Digit4", 52), "%": ("Digit5", 53),
        "^": ("Digit6", 54), "&": ("Digit7", 55), "*": ("Digit8", 56), "(": ("Digit9", 57), ")": ("Digit0", 48),
    ]
}

/// One DOM event for a game page, as `window.cabooseInput.dispatch` takes it. Positions and
/// distances are fractions of the window, so the page scales them by its own viewport and
/// the device's scale never enters.
public struct GameInputEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case pointerMove = "pointermove", pointerDown = "pointerdown", pointerUp = "pointerup"
        /// Ownership of the pointer went away with a button held: `pointercancel`, then the
        /// compatibility `mouseup` that releases the button in pages that only read mouse events.
        case pointerCancel = "pointercancel"
        case wheel
        case keyDown = "keydown", keyUp = "keyup"
    }

    public struct Modifiers: Equatable, Sendable {
        public var shift = false, control = false, alt = false, meta = false
    }

    public var kind: Kind
    public var x = 0.0, y = 0.0
    /// The DOM button that changed (pointer down/up/cancel), and every DOM button held after.
    public var button = 0, buttons = 0
    public var dx = 0.0, dy = 0.0
    public var key: GameKey?
    public var modifiers = Modifiers()

    /// The event as the page script takes it.
    var arguments: [String: Any] {
        var value: [String: Any] = ["type": kind.rawValue, "ctrl": modifiers.control, "shift": modifiers.shift,
                                    "alt": modifiers.alt, "meta": modifiers.meta]
        if let key {
            value["key"] = key.key
            value["code"] = key.code
            value["keyCode"] = key.keyCode
            value["location"] = key.location
            if let text = key.text { value["text"] = text }
        } else {
            value["x"] = x
            value["y"] = y
            value["button"] = button
            value["buttons"] = buttons
            if kind == .wheel {
                value["dx"] = dx
                value["dy"] = dy
            }
        }
        return value
    }
}

/// The input a game page takes from the controls that are not touches on it (a trackpad, the
/// app's own keyboard, a key bar), turned into DOM events. It keeps what is held, so every
/// press gets its release: when the input is released (`release()`), every held key goes up
/// and every held button is cancelled.
///
/// Pointer positions and scroll amounts arrive in the window's own pixels with the window's
/// pixel size, as display input does.
public struct GameInput: Equatable, Sendable {
    /// The DOM buttons held, as `MouseEvent.buttons` counts them.
    public private(set) var buttons = 0
    /// Where the pointer is, as fractions of the window.
    public private(set) var point = CGPoint(x: 0.5, y: 0.5)
    /// The keys held, by `code` (by `key` for a key with no code), in the order pressed.
    public private(set) var held: [GameKey] = []
    /// The modifier keys pressed only to type a key: released with it.
    private var implied: [GameKey] = []

    public init() {}

    /// The DOM button for an X button: 1, 2, 3, 8 and 9 are left, middle, right, back and forward.
    public static func domButton(forXButton button: Int) -> (button: Int, bit: Int)? {
        switch button {
        case 1: (0, 1)
        case 2: (1, 4)
        case 3: (2, 2)
        case 8: (3, 8)
        case 9: (4, 16)
        default: nil
        }
    }

    /// A position in a window of `size` pixels as fractions of it, kept inside the window.
    public static func fraction(_ point: CGPoint, in size: CGSize) -> CGPoint {
        func part(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            guard length > 0, value.isFinite else { return 0.5 }
            return min(1, max(0, value / length))
        }
        return CGPoint(x: part(point.x, size.width), y: part(point.y, size.height))
    }

    private var modifiers: GameInputEvent.Modifiers {
        var value = GameInputEvent.Modifiers()
        for key in held {
            switch key.modifier {
            case "shift": value.shift = true
            case "control": value.control = true
            case "mod1": value.alt = true
            case "mod4": value.meta = true
            default: break
            }
        }
        return value
    }

    private func pointerEvent(_ kind: GameInputEvent.Kind, button: Int = 0) -> GameInputEvent {
        GameInputEvent(kind: kind, x: point.x, y: point.y, button: button, buttons: buttons, modifiers: modifiers)
    }

    public mutating func move(to position: CGPoint, in size: CGSize) -> [GameInputEvent] {
        point = Self.fraction(position, in: size)
        return [pointerEvent(.pointerMove)]
    }

    public mutating func button(_ xButton: Int, pressed: Bool, at position: CGPoint, in size: CGSize) -> [GameInputEvent] {
        guard let (button, bit) = Self.domButton(forXButton: xButton) else { return [] }
        let moved = Self.fraction(position, in: size)
        var events: [GameInputEvent] = []
        if moved != point {
            point = moved
            events.append(pointerEvent(.pointerMove))
        }
        guard pressed == (buttons & bit == 0) else { return events }
        if pressed { buttons |= bit } else { buttons &= ~bit }
        events.append(pointerEvent(pressed ? .pointerDown : .pointerUp, button: button))
        return events
    }

    public mutating func scroll(dx: CGFloat, dy: CGFloat, at position: CGPoint, in size: CGSize) -> [GameInputEvent] {
        guard size.width > 0, size.height > 0, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return [] }
        point = Self.fraction(position, in: size)
        var event = pointerEvent(.wheel)
        event.dx = dx / size.width
        event.dy = dy / size.height
        return [event]
    }

    /// A key going down or up. A press that needs modifiers not held (`stroke.modifiers`, and
    /// `extraModifiers` such as a key bar's sticky Control) presses them first, and its release
    /// releases them after it.
    public mutating func key(_ stroke: KeyStroke, pressed: Bool, extraModifiers: [String] = []) -> [GameInputEvent] {
        guard let key = GameKey.key(for: stroke) else { return [] }
        if pressed {
            var events: [GameInputEvent] = []
            if key.modifier == nil {
                for name in Set(stroke.modifiers + extraModifiers).sorted() {
                    guard let modifier = GameKey.modifier(name), !held.contains(where: { $0.modifier == modifier.modifier }) else { continue }
                    events += down(modifier)
                    implied.append(modifier)
                }
            } else {
                implied.removeAll { $0.modifier == key.modifier }
            }
            return events + down(key)
        }
        guard held.contains(where: { Self.same($0, key) }) else { return [] }
        var events = up(key)
        if key.modifier == nil, !held.contains(where: { $0.modifier == nil }) {
            for modifier in implied.reversed() { events += up(modifier) }
            implied.removeAll()
        }
        return events
    }

    /// Types `text`: each character a press and release of its key, Return for a newline.
    public mutating func type(_ text: String) -> [GameInputEvent] {
        var events: [GameInputEvent] = []
        for character in text {
            // CRLF is one Character: one Return.
            let strokes = character.isNewline ? Keysyms.special["Return"].map { [$0] } ?? [] : Keysyms.strokes(for: character)
            for stroke in strokes { events += tap(stroke) }
        }
        return events
    }

    /// Deletes `count` characters before the caret: Backspace, `count` times.
    public mutating func backspace(_ count: Int) -> [GameInputEvent] {
        guard count > 0, let stroke = Keysyms.special["BackSpace"] else { return [] }
        return (0 ..< count).flatMap { _ in tap(stroke) }
    }

    /// The page loses this input: every held key goes up (the others before the modifiers)
    /// and every held button is cancelled.
    public mutating func release() -> [GameInputEvent] {
        var events: [GameInputEvent] = []
        for key in held.reversed() where key.modifier == nil { events += up(key) }
        for key in held.reversed() { events += up(key) }
        implied.removeAll()
        for (button, bit) in [(0, 1), (1, 4), (2, 2), (3, 8), (4, 16)] where buttons & bit != 0 {
            buttons &= ~bit
            events.append(pointerEvent(.pointerCancel, button: button))
        }
        return events
    }

    private mutating func tap(_ stroke: KeyStroke) -> [GameInputEvent] {
        key(stroke, pressed: true) + key(stroke, pressed: false)
    }

    private static func same(_ a: GameKey, _ b: GameKey) -> Bool {
        a.code.isEmpty && b.code.isEmpty ? a.key == b.key : a.code == b.code
    }

    private mutating func down(_ key: GameKey) -> [GameInputEvent] {
        // A key already down repeats; the page sees it held again, not pressed twice.
        if !held.contains(where: { Self.same($0, key) }) { held.append(key) }
        var event = GameInputEvent(kind: .keyDown, key: key, modifiers: modifiers)
        // Control, Alt and Meta make a key a shortcut, which types nothing.
        if event.modifiers.control || event.modifiers.alt || event.modifiers.meta { event.key?.text = nil }
        return [event]
    }

    private mutating func up(_ key: GameKey) -> [GameInputEvent] {
        guard let index = held.firstIndex(where: { Self.same($0, key) }) else { return [] }
        let released = held.remove(at: index)
        var event = GameInputEvent(kind: .keyUp, key: released, modifiers: modifiers)
        event.key?.text = nil
        return [event]
    }
}

/// The user script that gives a game page `window.cabooseInput`, through which the app hands
/// it `GameInputEvent`s: `dispatch(events)` dispatches each as the DOM events a browser makes
/// for the same input.
///
/// - Pointer: `pointer*` events, then the compatibility `mouse*` events (none between a
///   cancelled `pointerdown` and its `pointerup`), at the element under the point; while a
///   button is held they go to the element it went down on. `pointerover`/`pointerenter`/
///   `pointerout`/`pointerleave` and their mouse counterparts follow the element under the
///   point; `click`, `dblclick` and `contextmenu` follow the buttons; a press focuses a
///   focusable element. A cancel is `pointercancel`, then `mouseup`.
/// - Wheel: `wheel` in CSS pixels at the point.
/// - Keys: `keydown`, `keypress` for a key that types (when `keydown` was not cancelled) and
///   `keyup` at the focused element, with `keyCode`, `which` and `charCode`. In a text field
///   a typed key is inserted and Backspace deletes, as the browser would.
///
/// The events are untrusted (`isTrusted` is false): a page that ignores untrusted input does
/// not see them.
enum GameInputScript {
    static let source = #"""
    (function () {
      "use strict";
      let hover = null, captured = null, suppressMouse = false, last = null;
      const root = () => document.body || document.documentElement;
      const flags = (e) => ({ ctrlKey: !!e.ctrl, shiftKey: !!e.shift, altKey: !!e.alt, metaKey: !!e.meta });
      const legacy = (event, keyCode, charCode) => {
        for (const [name, value] of [["keyCode", keyCode], ["which", charCode || keyCode], ["charCode", charCode]]) {
          Object.defineProperty(event, name, { configurable: true, get: () => value });
        }
        return event;
      };
      const mouseInit = (e, x, y, extra) => Object.assign({
        bubbles: true, cancelable: true, composed: true, view: window,
        clientX: x, clientY: y, screenX: x, screenY: y, button: e.button || 0, buttons: e.buttons || 0,
      }, flags(e), extra || {});
      const pointerInit = (e, x, y) => mouseInit(e, x, y, {
        pointerId: 1, pointerType: "mouse", isPrimary: true, width: 1, height: 1, pressure: e.buttons ? 0.5 : 0,
      });
      const fire = (target, event) => target.dispatchEvent(event);
      const both = (target, type, e, x, y, mouseType, extra) => {
        const allowed = fire(target, new PointerEvent(type, Object.assign(pointerInit(e, x, y), extra || {})));
        if (mouseType && !suppressMouse) fire(target, new MouseEvent(mouseType, Object.assign(mouseInit(e, x, y), extra || {})));
        return allowed;
      };
      const crossing = (target, e, x, y) => {
        if (target === hover) return;
        const old = hover;
        hover = target;
        if (old && old.isConnected) {
          both(old, "pointerout", e, x, y, "mouseout", { relatedTarget: target });
          both(old, "pointerleave", e, x, y, "mouseleave", { relatedTarget: target, bubbles: false });
        }
        both(target, "pointerover", e, x, y, "mouseover", { relatedTarget: old });
        both(target, "pointerenter", e, x, y, "mouseenter", { relatedTarget: old, bubbles: false });
      };
      const at = (e) => {
        const x = e.x * window.innerWidth, y = e.y * window.innerHeight;
        const under = document.elementFromPoint(x, y) || root();
        return { x, y, under, target: captured && captured.isConnected ? captured : under };
      };
      const pointer = (e) => {
        const { x, y, under, target } = at(e);
        crossing(under, e, x, y);
        switch (e.type) {
          case "pointermove":
            both(target, "pointermove", e, x, y, "mousemove");
            break;
          case "pointerdown": {
            const first = !captured;
            if (first) captured = under;
            if (!both(target, "pointerdown", e, x, y, null) && first) suppressMouse = true;
            if (!suppressMouse && fire(target, new MouseEvent("mousedown", mouseInit(e, x, y)))) {
              if (target.tabIndex >= 0 && typeof target.focus === "function" && document.activeElement !== target) target.focus({ preventScroll: true });
            }
            if (e.button === 2 && !suppressMouse) fire(target, new MouseEvent("contextmenu", mouseInit(e, x, y)));
            break;
          }
          case "pointerup":
          case "pointercancel": {
            const cancel = e.type === "pointercancel";
            both(target, e.type, e, x, y, null);
            if (!suppressMouse) {
              fire(target, new MouseEvent("mouseup", mouseInit(e, x, y)));
              if (!cancel && (e.button === 0 || e.button === 1) && under === target) {
                const now = performance.now();
                const repeat = last && last.target === target && last.button === e.button && now - last.time < 500 && Math.hypot(last.x - x, last.y - y) < 8;
                const detail = repeat ? last.detail + 1 : 1;
                last = { target, button: e.button, time: now, x, y, detail };
                fire(target, new MouseEvent(e.button === 0 ? "click" : "auxclick", mouseInit(e, x, y, { detail })));
                if (e.button === 0 && detail === 2) fire(target, new MouseEvent("dblclick", mouseInit(e, x, y, { detail })));
              }
            }
            if (!e.buttons) { captured = null; suppressMouse = false; }
            break;
          }
          case "wheel":
            fire(target, new WheelEvent("wheel", mouseInit(e, x, y, {
              deltaX: e.dx * window.innerWidth, deltaY: e.dy * window.innerHeight, deltaZ: 0, deltaMode: 0,
            })));
            break;
        }
      };
      const editable = (target) => target && (target.isContentEditable || /^(INPUT|TEXTAREA)$/.test(target.tagName));
      const key = (e) => {
        const target = document.activeElement || root();
        const init = Object.assign({ bubbles: true, cancelable: true, composed: true, view: window,
          key: e.key, code: e.code, location: e.location || 0, repeat: false }, flags(e));
        const allowed = fire(target, legacy(new KeyboardEvent(e.type, init), e.keyCode, 0));
        if (e.type !== "keydown" || !allowed) return;
        if (e.text) {
          const charCode = e.text.codePointAt(0);
          if (fire(target, legacy(new KeyboardEvent("keypress", init), charCode, charCode)) && editable(target) && e.text !== "\r") {
            document.execCommand("insertText", false, e.text);
          }
        } else if (e.key === "Backspace" && editable(target)) {
          document.execCommand("delete", false);
        }
      };
      Object.defineProperty(window, "cabooseInput", { value: Object.freeze({
        dispatch(events) {
          for (const e of events) {
            if (e.type === "keydown" || e.type === "keyup") key(e); else pointer(e);
          }
        },
      }) });
    })();
    """#

    /// The call that hands `events` to the page, with the arguments
    /// `WKWebView.callAsyncJavaScript` binds for it.
    static func call(_ events: [GameInputEvent]) -> (body: String, arguments: [String: Any]) {
        ("if (window.cabooseInput) window.cabooseInput.dispatch(events);", ["events": events.map(\.arguments)])
    }
}
