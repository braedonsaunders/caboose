import CoreGraphics
import Foundation
import Observation

/// A Linux window as Caboose knows it.
@MainActor @Observable
public final class RemoteWindow: Identifiable {
    public nonisolated let id: Int
    public internal(set) var title: String = ""
    /// WM_CLASS instance and class, e.g. ("xfce4-terminal", "Xfce4-terminal").
    public internal(set) var appClass: (instance: String, name: String)?
    /// The desktop entry the computer launched this window's process from, when it knows:
    /// it names the app even when the window's class does not (a wrapper script, a game).
    public internal(set) var desktopID: String?
    /// The process that owns the window, as the computer sees it, when it says.
    public internal(set) var pid: Int?
    public internal(set) var isOverrideRedirect: Bool
    public internal(set) var transientFor: Int?
    public internal(set) var windowTypes: [String] = []
    /// The app asked to cover the whole screen (a video player, a game, a slideshow).
    public internal(set) var isFullscreen = false
    public internal(set) var hasAlpha = false
    /// The app holds an idle inhibitor on the window: the screen stays awake while it is shown.
    public internal(set) var inhibitsIdle = false
    /// What the app says the window shows; sets how fast it is refreshed (`FrameRatePolicy`).
    public internal(set) var contentType: WindowContentType = .none
    /// The app holds the keyboard: Caboose's own shortcuts step aside while it is focused.
    public internal(set) var grabsKeys = false
    /// Position and size in the server's pixel space. Position may follow an in-flight
    /// placement request; size remains the size reported by the server. The window's GPU
    /// layer is fitted to it.
    public internal(set) var frame: CGRect

    public internal(set) var minimumSize: CGSize?
    public internal(set) var maximumSize: CGSize?
    public internal(set) var icon: CGImage?
    public internal(set) var raisedAt = Date()
    /// The window takes touch itself (a native Wayland app): fingers go to it as touch
    /// points instead of being turned into pointer gestures.
    public internal(set) var acceptsTouch = false
    /// The controls a finger may mean, from the window's accessibility tree, in window
    /// pixels (`TouchAim`); empty when the computer lists none.
    public internal(set) var touchTargets: [TouchTarget] = []
    /// The window controls the application draws itself (an Electron app's HTML minimize,
    /// maximize and close), in window pixels: covered on screen and never clicked, since
    /// Caboose's own controls are on every window.
    public internal(set) var drawnControls: [CGRect] = []

    /// Whether `point`, in window pixels, is on a control the application draws itself.
    public func isOnDrawnControl(_ point: CGPoint) -> Bool {
        drawnControls.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }
    /// The window takes Apple Pencil as a tablet, with pressure and tilt.
    public internal(set) var acceptsPencil = false
    /// The game this device runs in the window instead of showing the computer's picture
    /// (docs/game-handoff.md); nil for every other window.
    public internal(set) var game: RemoteGame?
    #if canImport(UIKit)
    /// Where the window's GPU layer is placed: set by the owner's GPU executor
    /// (`LiveGPUOwnerSession`), never by an agent or thumbnail session.
    @ObservationIgnored weak var liveGPUPresentation: LiveGPUPresentationOwners?
    #endif
    /// The window's last picture held on the phone, for thumbnails and Home.
    public nonisolated let snapshot: WindowSnapshot

    init(id: Int, frame: CGRect, overrideRedirect: Bool, snapshot: WindowSnapshot = WindowSnapshot()) {
        self.id = id
        self.frame = frame
        self.isOverrideRedirect = overrideRedirect
        self.snapshot = snapshot
    }

    /// Popups, menus, tooltips and dialogs belong to a parent window rather than standing alone.
    public var isAuxiliary: Bool {
        isOverrideRedirect || transientFor != nil
            || windowTypes.contains { ["DIALOG", "MENU", "POPUP_MENU", "DROPDOWN_MENU", "TOOLTIP", "UTILITY", "NOTIFICATION", "SPLASH", "COMBO"].contains($0) }
    }
}

/// A `child` window (docs/display.md, "Child windows"): a region of its parent where one of
/// the parent application's own GPU surfaces presents. It is part of its parent, never a
/// window of its own: it is not in a session's `windows`, takes no input, and shows only as
/// a GPU layer inside the view showing its parent.
@MainActor
public final class RemoteChildWindow: Identifiable {
    public nonisolated let id: Int
    /// The window it is inset in.
    public internal(set) var parent: Int
    /// Its place relative to the parent's geometry, in display pixels.
    public internal(set) var geometry: CGRect
    /// The part of it the parent shows, in the same coordinates as `geometry`.
    public internal(set) var clip: CGRect
    /// Its place among the parent's children, lowest first.
    public internal(set) var stack: Int

    init(id: Int, parent: Int, geometry: CGRect, clip: CGRect, stack: Int) {
        self.id = id
        self.parent = parent
        self.geometry = geometry
        self.clip = clip
        self.stack = stack
    }
}

public struct RemoteNotification: Sendable, Identifiable {
    public var id: Int
    public var appName: String
    public var summary: String
    public var body: String
}

/// Times key presses to the next present of the same window's GPU layer, from any thread.
final class EchoMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (wid: Int, at: UInt64)?
    private var samples: [Int] = []

    func keySent(_ wid: Int) {
        lock.lock(); defer { lock.unlock() }
        if pending == nil { pending = (wid, DispatchTime.now().uptimeNanoseconds) }
    }

    func drew(_ wid: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let key = pending, key.wid == wid else { return }
        pending = nil
        let ms = Int((DispatchTime.now().uptimeNanoseconds - key.at) / 1_000_000)
        guard ms < 3000 else { return }
        samples.append(ms)
        if samples.count > 20 { samples.removeFirst() }
    }

    var median: Int? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }

    /// Seconds since a key press whose window has not drawn since.
    var pendingSeconds: Double? {
        lock.lock(); defer { lock.unlock() }
        return pending.map { Double(DispatchTime.now().uptimeNanoseconds - $0.at) / 1_000_000_000 }
    }

    /// The connection closed: a key pressed before it can no longer be matched to a picture.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}
