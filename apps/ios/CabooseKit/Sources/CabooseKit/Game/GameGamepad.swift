import Foundation

/// A game controller the app draws itself (an on-screen one), as a game page's Gamepad API
/// sees it. Set it on `RemoteGame.gamepad`; the page's `navigator.getGamepads()` then lists
/// it with the `"standard"` mapping after the controllers WebKit knows, and `window` gets
/// `gamepadconnected` and `gamepaddisconnected` for it. Hardware controllers reach the page
/// through WebKit directly and need none of this.
public struct GameGamepadState: Equatable, Sendable {
    /// The buttons of the W3C standard mapping, by their index there.
    public enum Button: Int, CaseIterable, Sendable {
        /// The face buttons: bottom (A, ✕), right (B, ○), left (X, □), top (Y, △).
        case south, east, west, north
        case leftShoulder, rightShoulder, leftTrigger, rightTrigger
        case select, start, leftStick, rightStick
        case up, down, left, right
        case home
    }

    /// The axes of the standard mapping: each stick's x then y, from -1 to 1, right and down positive.
    public enum Axis: Int, CaseIterable, Sendable {
        case leftX, leftY, rightX, rightY
    }

    /// Each button's value, 0 (released) to 1 (fully pressed), by `Button` index.
    public var buttons: [Double]
    /// Each axis's value, -1 to 1, by `Axis` index.
    public var axes: [Double]

    /// Missing values are 0 and extra ones are ignored, so `GameGamepadState()` is a
    /// connected controller at rest.
    public init(buttons: [Double] = [], axes: [Double] = []) {
        self.buttons = buttons
        self.axes = axes
    }

    public subscript(button: Button) -> Double {
        get { button.rawValue < buttons.count ? buttons[button.rawValue] : 0 }
        set {
            if buttons.count <= button.rawValue { buttons += Array(repeating: 0, count: button.rawValue + 1 - buttons.count) }
            buttons[button.rawValue] = newValue
        }
    }

    public subscript(axis: Axis) -> Double {
        get { axis.rawValue < axes.count ? axes[axis.rawValue] : 0 }
        set {
            if axes.count <= axis.rawValue { axes += Array(repeating: 0, count: axis.rawValue + 1 - axes.count) }
            axes[axis.rawValue] = newValue
        }
    }

    /// Exactly one value per standard button and axis, each in its range (NaN reads as 0).
    var normalized: (buttons: [Double], axes: [Double]) {
        func clamp(_ value: Double, _ low: Double) -> Double { value.isNaN ? 0 : min(1, max(low, value)) }
        return (Button.allCases.map { clamp(self[$0], 0) }, Axis.allCases.map { clamp(self[$0], -1) })
    }
}

/// The user script that gives a game page `window.cabooseGamepad`, through which the app
/// drives `GameGamepadState`:
///
/// - `update(buttons, axes)` sets the controller's state, connecting it first if it is not.
/// - `disconnect()` takes it away.
///
/// A button is `pressed` above 0.1 and `touched` above 0. The controller keeps the index it
/// connected at; a hardware controller that later takes that index moves it to the next
/// free one (disconnected, then connected again there).
enum GameGamepadScript {
    static let source = #"""
    (function () {
      "use strict";
      const original = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
      const id = "Caboose on-screen controller (STANDARD GAMEPAD)";
      let pad = null;
      const native = () => Array.prototype.slice.call(original() || []);
      const announce = (type, gamepad) => {
        const event = new Event(type);
        Object.defineProperty(event, "gamepad", { value: gamepad, enumerable: true });
        window.dispatchEvent(event);
      };
      const snapshot = (index, buttons, axes) => Object.freeze({
        id, index, connected: true, mapping: "standard", timestamp: performance.now(),
        axes: Object.freeze(axes.slice()),
        buttons: Object.freeze(buttons.map((value) => Object.freeze({ value, pressed: value > 0.1, touched: value > 0 }))),
        vibrationActuator: null,
      });
      const freeIndex = (pads) => {
        const gap = pads.findIndex((entry) => !entry);
        return gap === -1 ? pads.length : gap;
      };
      // A hardware controller took the on-screen one's index: move it.
      const settle = (pads) => {
        if (!pad || !pads[pad.index]) return;
        const gone = Object.freeze(Object.assign({}, pad, { connected: false }));
        pad = snapshot(freeIndex(pads), pad.buttons.map((button) => button.value), pad.axes);
        announce("gamepaddisconnected", gone);
        announce("gamepadconnected", pad);
      };
      Object.defineProperty(navigator, "getGamepads", { configurable: true, writable: true, value: function getGamepads() {
        const pads = native();
        settle(pads);
        if (pad) {
          while (pads.length < pad.index) pads.push(null);
          pads[pad.index] = pad;
        }
        return pads;
      } });
      Object.defineProperty(window, "cabooseGamepad", { value: Object.freeze({
        update(buttons, axes) {
          const pads = native();
          settle(pads);
          const connecting = !pad;
          pad = snapshot(pad ? pad.index : freeIndex(pads), Array.from(buttons, Number), Array.from(axes, Number));
          if (connecting) announce("gamepadconnected", pad);
        },
        disconnect() {
          if (!pad) return;
          const gone = Object.freeze(Object.assign({}, pad, { connected: false }));
          pad = null;
          announce("gamepaddisconnected", gone);
        },
      }) });
    })();
    """#

    /// The call that hands `state` to the page (nil disconnects), with the arguments
    /// `WKWebView.callAsyncJavaScript` binds for it.
    static func call(_ state: GameGamepadState?) -> (body: String, arguments: [String: Any]) {
        guard let state else { return ("if (window.cabooseGamepad) window.cabooseGamepad.disconnect();", [:]) }
        let values = state.normalized
        return ("if (window.cabooseGamepad) window.cabooseGamepad.update(buttons, axes);", ["buttons": values.buttons, "axes": values.axes])
    }
}
