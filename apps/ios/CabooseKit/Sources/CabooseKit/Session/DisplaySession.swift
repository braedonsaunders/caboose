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

/// One connection to a display of the computer: the owner's, or the agent seat's.
/// `CabooseDisplaySession` implements it over the Caboose Display Protocol; the app's window
/// screens, desktop and input work against this, so tests can stand in for a live display.
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
    /// What the connection has measured; empty where an implementation measures nothing.
    var health: DisplayLinkHealth { get }
    /// Why the connection last closed, nil while it has not.
    var closeCause: DisplayCloseCause? { get }
    /// Bumped once the server has announced all its windows after a hello, when the server
    /// guarantees that order (it sends an epoch): `windows` is then exactly the server's.
    var windowsAnnounced: Int { get }
    /// The server process's epoch from its last hello; window ids name the same windows
    /// only within one. Nil for a server that sends none.
    var epoch: String? { get }

    /// The computer's clipboard changed (docs/display.md, Clipboard).
    var onClipboard: ((ClipboardContent) -> Void)? { get set }
    /// The user chose Paste in a window and the phone's pasteboard has no text. Returns
    /// whether it takes the paste; if so it puts the pasteboard's images and files on the
    /// computer's clipboard and then calls `paste`, which pastes them into the window.
    var onPasteItems: ((_ paste: @escaping @MainActor () -> Void) -> Bool)? { get set }
    var onNotification: ((RemoteNotification) -> Void)? { get set }
    var onBell: (() -> Void)? { get set }
    var onRaise: ((Int) -> Void)? { get set }
    var onOpenURL: ((URL) -> Void)? { get set }
    /// A cached last frame for a window id, shown until the server's first picture arrives.
    var cachedFrame: ((Int) -> CGImage?)? { get set }
    var playsAudio: Bool { get set }

    func connect()
    func disconnect()
    /// The network changed: confirm the connection still answers, or close it.
    func probeLiveness()

    // MARK: Windows

    /// Sizes and places a window. `state` changes its window-manager state as well, e.g.
    /// `["fullscreen": false]`.
    func configure(_ window: RemoteWindow, frame: CGRect, state: [String: Bool])
    func focus(_ window: RemoteWindow?)
    /// Asks the app to lay `window` out `size` larger than its geometry (`.zero` ends it).
    func requestOverscan(_ window: RemoteWindow, _ size: CGSize)
    /// Scrolls `window`'s reported scroller by `delta` content pixels through its toolkit
    /// reporter (`scroll.target`); false when the session cannot.
    func scrollTarget(in window: RemoteWindow, scroller: Int, delta: CGPoint) -> Bool
    func close(_ window: RemoteWindow)
    /// Asks for a full repaint.
    func refresh(_ window: RemoteWindow)
    /// Changes the screen the server lays windows out for, on the live connection.
    func reconfigure(_ capabilities: ClientCapabilities)
    /// Puts a copy made on the phone on the computer's clipboard; the same copy again,
    /// or the computer's own coming back, is not sent.
    func offerClipboard(_ content: ClipboardContent)

    // MARK: Drag and drop (docs/display.md, Drag and drop)

    var dropAccepted: Bool? { get }
    var onDropResult: ((Bool, String?) -> Void)? { get set }
    var computerDrag: [String]? { get }
    var dragOutFrame: CGRect? { get set }
    var dragOutHovering: Bool { get }
    var onDragData: ((ClipboardContent) -> Void)? { get set }
    func dropEnter(_ window: RemoteWindow, at point: CGPoint, types: [String])
    func dropMove(_ window: RemoteWindow, at point: CGPoint)
    func dropLeave()
    func dropPerform(_ content: ClipboardContent)
    func trackDragOut(at windowPoint: CGPoint)
    @discardableResult func takeDragIfOver(_ windowPoint: CGPoint) -> Bool

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
    /// CADisplayLink's). Nil selects the announced primary (or retained hello primary
    /// during unselected bootstrap); explicit IDs are never redirected. Servers that
    /// pace on the client's vsync release frames on it.
    func displayWillRefresh(_ display: Int?, targetTimestamp: CFTimeInterval)

    /// The shape of the pointer, by name, bumped on every change so a view can tell a fresh
    /// answer from a stale one.
    var cursorSerial: Int { get }
    /// Whether the focused spot takes text: from the app's text-input state where the server
    /// reports it, else from a text cursor. Nil when the server has said nothing.
    var cursorIsText: Bool? { get }
    /// What kind of text the focused field takes ("terminal", "password", "normal", …), when known.
    var textPurpose: String? { get }
    /// The focused field's text around the caret, where its app reports it, with a serial
    /// bumped on every report.
    var surroundingText: (window: Int, serial: Int, text: SurroundingText)? { get }
    /// The display closed because another device took it over. Reconnecting on its own would
    /// take it back, so the app waits for the person to ask.
    var isReplaced: Bool { get }
}

public extension DisplaySession {
    func requestOverscan(_ window: RemoteWindow, _ size: CGSize) {}
    func scrollTarget(in window: RemoteWindow, scroller: Int, delta: CGPoint) -> Bool { false }
    /// Leave application fullscreen (Escape also exits page/player fullscreen) and restore
    /// the shell's geometry. Available even when fullscreen metadata has not arrived yet.
    func exitFullscreen(_ window: RemoteWindow, frame: CGRect) {
        focus(window)
        if let escape = Keysyms.special["Escape"] {
            key(escape, pressed: true, in: window)
            key(escape, pressed: false, in: window)
        }
        configure(window, frame: frame, state: ["fullscreen": false, "maximized": false])
    }
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
    func displayWillRefresh(_ display: Int?, targetTimestamp: CFTimeInterval) {}
    var textPurpose: String? { nil }
    var surroundingText: (window: Int, serial: Int, text: SurroundingText)? { nil }
    var isReplaced: Bool { false }
    var health: DisplayLinkHealth { .empty }
    var closeCause: DisplayCloseCause? { nil }
    var windowsAnnounced: Int { 0 }
    var epoch: String? { nil }
    func probeLiveness() {}
}

public extension DisplaySession {
    func offerClipboard(_ text: String) {
        if let content = ClipboardPolicy.content(text: text) { offerClipboard(content) }
    }
}
