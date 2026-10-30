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
    public internal(set) var isOverrideRedirect: Bool
    public internal(set) var transientFor: Int?
    public internal(set) var windowTypes: [String] = []
    /// The app asked to cover the whole screen (a video player, a game, a slideshow).
    public internal(set) var isFullscreen = false
    public internal(set) var hasAlpha = false
    /// Position and size in the server's pixel space. Position may follow an in-flight
    /// placement request; size remains the size reported by the server.
    public internal(set) var frame: CGRect
    /// The last drawable's coordinate space, independent of configure metadata.
    /// Observed by content, drop targets and popup roots as one presentation size.
    private var retainedPictureSize: CGSize?
    public var presentationSize: CGSize { retainedPictureSize ?? frame.size }

    func adoptPictureSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, retainedPictureSize != size else { return }
        retainedPictureSize = size
    }

    public internal(set) var minimumSize: CGSize?
    public internal(set) var maximumSize: CGSize?
    public internal(set) var icon: CGImage?
    public internal(set) var raisedAt = Date()
    /// The window takes touch itself (a native Wayland app): fingers go to it as touch
    /// points instead of being turned into pointer gestures.
    public internal(set) var acceptsTouch = false
    /// The window takes Apple Pencil as a tablet, with pressure and tilt.
    public internal(set) var acceptsPencil = false
    /// Videos playing in the window, lowest `z` first, drawn over its picture.
    public internal(set) var videos: [RemoteVideo] = []
    /// Bumped whenever a video comes, goes or moves, so a view knows to lay them out again.
    public internal(set) var videoLayout = 0
    /// Ended videos whose region the window's own picture has not repainted on screen yet, by
    /// their container: the surface generation that repaints it. A view keeps showing each
    /// such video until it has presented that generation, so the stale pixels under it never show.
    public internal(set) var retiringVideos: [ObjectIdentifier: UInt64] = [:]
    /// The game this device runs in the window instead of showing the computer's picture
    /// (docs/game-handoff.md); nil for every other window.
    public internal(set) var game: RemoteGame?
    /// The GPU stream this device draws the window from instead of the computer's picture
    /// (docs/gpu-stream.md); nil for every other window.
    public internal(set) var gpuStream: RemoteGPUStream?
    public nonisolated let surface: WindowSurface

    init(id: Int, frame: CGRect, overrideRedirect: Bool, surface: WindowSurface) {
        self.id = id
        self.frame = frame
        self.isOverrideRedirect = overrideRedirect
        self.surface = surface
        if let texture = surface.texture {
            retainedPictureSize = CGSize(width: texture.width, height: texture.height)
        }
    }

    /// Popups, menus, tooltips and dialogs belong to a parent window rather than standing alone.
    public var isAuxiliary: Bool {
        isOverrideRedirect || transientFor != nil
            || windowTypes.contains { ["DIALOG", "MENU", "POPUP_MENU", "DROPDOWN_MENU", "TOOLTIP", "UTILITY", "NOTIFICATION", "SPLASH", "COMBO"].contains($0) }
    }
}

public struct RemoteNotification: Sendable, Identifiable {
    public var id: Int
    public var appName: String
    public var summary: String
    public var body: String
}

/// Times key presses to the next draw of the same window, from any thread.
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
