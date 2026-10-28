import CoreGraphics
import Foundation
import QuartzCore

public enum DisplaySessionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case ready
    case closed(reason: String?)
}

/// One connection to the computer's display server, whichever protocol it speaks: Xpra
/// (`XpraSession`) or Caboose Display (`CabooseDisplaySession`). The app's window screens,
/// desktop and input work against this, so both stand behind the same window model.
///
/// Positions are in the window's own pixel space; sizes and frames in the server's pixels.
@MainActor
public protocol DisplaySession: AnyObject {
    var state: DisplaySessionState { get }
    var windows: [Int: RemoteWindow] { get }
    /// Latest measured latency to the computer, in milliseconds.
    var latencyMs: Double? { get }
    /// The median time from a key leaving the phone to the next picture of that window.
    var typingEchoMs: Int? { get }

    var onClipboardText: ((String) -> Void)? { get set }
    var clipboardProvider: (() -> String?)? { get set }
    var onNotification: ((RemoteNotification) -> Void)? { get set }
    var onBell: (() -> Void)? { get set }
    var onRaise: ((Int) -> Void)? { get set }
    var onOpenURL: ((URL) -> Void)? { get set }
    /// A cached last frame for a window id, shown until the server's first picture arrives.
    var cachedFrame: ((Int) -> CGImage?)? { get set }
    var playsAudio: Bool { get set }

    func connect()
    func disconnect()

    // MARK: Windows

    /// Sizes and places a window. `state` changes its window-manager state as well, e.g.
    /// `["fullscreen": false]`.
    func configure(_ window: RemoteWindow, frame: CGRect, state: [String: Bool])
    func focus(_ window: RemoteWindow?)
    func close(_ window: RemoteWindow)
    /// Asks for a full repaint.
    func refresh(_ window: RemoteWindow)
    /// Changes the screen the server lays windows out for, on the live connection.
    func reconfigure(_ capabilities: ClientCapabilities)
    func offerClipboard(_ text: String)

    // MARK: Input

    func pointerMove(in window: RemoteWindow, to point: CGPoint, modifiers: [String])
    func pointerButton(in window: RemoteWindow, button: Int, pressed: Bool, at point: CGPoint, modifiers: [String])
    /// Deltas in pixels, positive down/right.
    func scroll(in window: RemoteWindow, dx: CGFloat, dy: CGFloat, at point: CGPoint, modifiers: [String])
    func resetScroll()
    func key(_ stroke: KeyStroke, pressed: Bool, in window: RemoteWindow?, extraModifiers: [String])
    func type(_ text: String, in window: RemoteWindow?)

    /// Makes the remote text match the iOS text system's edits.
    func edit(_ edits: [TypingBuffer.Edit], in window: RemoteWindow?)
    /// Whether marked text (IME composition) goes to the server as a preedit of its own
    /// instead of being typed and retyped.
    var composesText: Bool { get }
    /// The composition in progress, with its selection in UTF-16 units; "" ends it.
    func compose(_ preedit: String, selection: NSRange, in window: RemoteWindow?)

    /// Fingers on a window that takes touch itself (`RemoteWindow.acceptsTouch`).
    func touch(_ points: [TouchPoint], in window: RemoteWindow)
    /// Apple Pencil on a window that takes a tablet (`RemoteWindow.acceptsPencil`).
    func pencil(_ sample: PencilSample, in window: RemoteWindow)

    /// The display a window is shown on is about to refresh, at `targetTimestamp` (the
    /// CADisplayLink's). Servers that pace on the client's vsync release frames on it.
    func displayWillRefresh(_ display: Int, targetTimestamp: CFTimeInterval)

    /// The shape of the pointer, by name, bumped on every change so a view can tell a fresh
    /// answer from a stale one.
    var cursorSerial: Int { get }
    /// Whether the focused spot takes text: from the app's text-input state where the server
    /// reports it, else from a text cursor. Nil when the server has said nothing.
    var cursorIsText: Bool? { get }
    /// What kind of text the focused field takes ("terminal", "password", "normal", …), when known.
    var textPurpose: String? { get }
    /// The display closed because another device took it over. Reconnecting on its own would
    /// take it back, so the app waits for the person to ask.
    var isReplaced: Bool { get }
}

public extension DisplaySession {
    func configure(_ window: RemoteWindow, frame: CGRect) { configure(window, frame: frame, state: [:]) }
    func pointerMove(in window: RemoteWindow, to point: CGPoint) { pointerMove(in: window, to: point, modifiers: []) }
    func pointerButton(in window: RemoteWindow, button: Int, pressed: Bool, at point: CGPoint) {
        pointerButton(in: window, button: button, pressed: pressed, at: point, modifiers: [])
    }
    func scroll(in window: RemoteWindow, dx: CGFloat, dy: CGFloat, at point: CGPoint) {
        scroll(in: window, dx: dx, dy: dy, at: point, modifiers: [])
    }
    func key(_ stroke: KeyStroke, pressed: Bool, in window: RemoteWindow?) {
        key(stroke, pressed: pressed, in: window, extraModifiers: [])
    }

    /// Edits as keystrokes: BackSpace for each deleted character, then the text typed.
    func edit(_ edits: [TypingBuffer.Edit], in window: RemoteWindow?) {
        for edit in edits {
            switch edit {
            case .backspace(let count):
                guard let stroke = Keysyms.special["BackSpace"] else { continue }
                for _ in 0 ..< count {
                    key(stroke, pressed: true, in: window)
                    key(stroke, pressed: false, in: window)
                }
            case .type(let text):
                type(text, in: window)
            }
        }
    }

    var composesText: Bool { false }
    func compose(_ preedit: String, selection: NSRange, in window: RemoteWindow?) {}
    func touch(_ points: [TouchPoint], in window: RemoteWindow) {}
    func pencil(_ sample: PencilSample, in window: RemoteWindow) {}
    func displayWillRefresh(_ display: Int, targetTimestamp: CFTimeInterval) {}
    var textPurpose: String? { nil }
    var isReplaced: Bool { false }
}
