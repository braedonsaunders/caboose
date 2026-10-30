import CoreGraphics

/// Desktop coordinates are in points. A normal window's frame starts at its title bar;
/// its height counts only the remote content below that bar.
public enum DesktopGeometry {
    /// Snapshot this with a gesture's target. A changed snapshot cancels active or
    /// inertial delivery rather than changing its gain/anchor halfway through.
    public struct SurfaceMapping: Equatable {
        public var shown: CGRect
        public var remote: CGSize
        public init(shown: CGRect, remote: CGSize) { self.shown = shown; self.remote = remote }

        public func point(_ point: CGPoint, captured: Bool = false) -> CGPoint? {
            DesktopGeometry.remotePoint(point, shown: shown, remote: remote, captured: captured)
        }

        /// Relative motion has the same scale as positions, without translation.
        public func delta(_ delta: CGPoint) -> CGPoint? {
            guard shown.width > 0, shown.height > 0, remote.width > 0, remote.height > 0,
                  delta.x.isFinite, delta.y.isFinite else { return nil }
            return CGPoint(x: delta.x * remote.width / shown.width, y: delta.y * remote.height / shown.height)
        }
    }

    /// Inverse of the shown surface rectangle, shared by desktop pointer actions.
    /// A new press cannot target letterboxing. An already captured drag can clamp
    /// to the surface edge so its release always reaches the original window.
    public static func remotePoint(_ point: CGPoint, shown: CGRect, remote: CGSize,
                                   captured: Bool = false) -> CGPoint? {
        guard shown.width > 0, shown.height > 0, remote.width > 0, remote.height > 0,
              point.x.isFinite, point.y.isFinite, captured || shown.contains(point) else { return nil }
        return CGPoint(x: min(remote.width, max(0, (point.x - shown.minX) * remote.width / shown.width)),
                       y: min(remote.height, max(0, (point.y - shown.minY) * remote.height / shown.height)))
    }

    /// Keep the external desktop's default render width bounded while respecting the screen scale.
    public static func externalPixelsPerPoint(width: CGFloat, scale: CGFloat, fullResolution: Bool) -> CGFloat {
        let full = max(1, scale)
        guard !fullResolution, width > 0 else { return full }
        return min(full, max(1, 2560 / width))
    }
    public struct WindowGeometry {
        public var frame: CGRect
        public var parent: Int?

        public init(frame: CGRect, parent: Int?) {
            self.frame = frame
            self.parent = parent
        }
    }

    /// Maps auxiliary trees from guest pixels through the actual visible surface of each
    /// parent. Roots are the main windows' displayed content rects, including fit/centering.
    /// Offscreen owners and unrelated full-screen trees do not leave menus on other tiles.
    public static func popupFrames(windows: [Int: WindowGeometry], rootFrames: [Int: CGRect],
                                   viewport: CGRect, pixelsPerPoint: CGFloat,
                                   covering: Int? = nil) -> [Int: CGRect] {
        guard pixelsPerPoint > 0, viewport.width > 0, viewport.height > 0 else { return [:] }
        var result: [Int: CGRect] = [:]

        func visible(_ rect: CGRect) -> Bool {
            let intersection = viewport.intersection(rect)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }

        func fitted(_ rect: CGRect) -> CGRect {
            let factor = min(1, viewport.width / max(1, rect.width), viewport.height / max(1, rect.height))
            let size = CGSize(width: rect.width * factor, height: rect.height * factor)
            return CGRect(x: min(max(viewport.minX, rect.minX), viewport.maxX - size.width),
                          y: min(max(viewport.minY, rect.minY), viewport.maxY - size.height),
                          width: size.width, height: size.height)
        }

        func place(_ id: Int, ancestors: Set<Int>) -> CGRect? {
            guard !ancestors.contains(id), let window = windows[id] else { return nil }
            if let root = rootFrames[id] {
                return (covering == nil || covering == id) && visible(root) ? root : nil
            }
            if let cached = result[id] { return cached }
            var chain = ancestors
            chain.insert(id)
            let mapped: CGRect
            if let parentID = window.parent {
                guard let parent = windows[parentID], parent.frame.width > 0, parent.frame.height > 0,
                      let shown = place(parentID, ancestors: chain) else { return nil }
                let sx = shown.width / parent.frame.width, sy = shown.height / parent.frame.height
                mapped = CGRect(x: shown.minX + (window.frame.minX - parent.frame.minX) * sx,
                                y: shown.minY + (window.frame.minY - parent.frame.minY) * sy,
                                width: window.frame.width * sx, height: window.frame.height * sy)
            } else {
                // An unparented auxiliary has no owner to follow. Never pull an offscreen
                // one onto this desktop, or place it over an unrelated full-screen window.
                guard covering == nil else { return nil }
                mapped = CGRect(x: window.frame.minX / pixelsPerPoint, y: window.frame.minY / pixelsPerPoint,
                                width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
                guard visible(mapped) else { return nil }
            }
            let frame = fitted(mapped)
            result[id] = frame
            return frame
        }

        for id in windows.keys.sorted() where rootFrames[id] == nil {
            _ = place(id, ancestors: [])
        }
        return result
    }

    public static func maximizedFrame(size: CGSize, titleBarHeight: CGFloat,
                                      dockHeight: CGFloat, dockBottomInset: CGFloat,
                                      dockGap: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: max(1, size.width),
               height: max(1, size.height - dockHeight - dockBottomInset - dockGap - titleBarHeight))
    }

    /// Local web content reflows at the viewport size; guest pictures keep their coordinate space.
    public static func surfaceSize(natural: CGSize, available: CGSize, locallyRendered: Bool) -> CGSize {
        if locallyRendered || natural.width <= 0 || natural.height <= 0 { return available }
        return natural
    }

    /// The entire remote picture stays visible, including while a new size is arriving.
    /// During resize ordinary windows stretch to the tile; otherwise minimum-size
    /// windows fit at the top. Fullscreen pictures always keep their aspect and center.
    public static func surfaceFrame(natural: CGSize, available: CGSize, resizing: Bool,
                                    fullscreen: Bool = false) -> CGRect {
        guard natural.width > 0, natural.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        if resizing && !fullscreen { return CGRect(origin: .zero, size: available) }
        let scale = min(1, available.width / natural.width, available.height / natural.height)
        let shown = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: max(0, (available.width - shown.width) / 2),
                      y: !fullscreen && scale < 1 ? 0 : max(0, (available.height - shown.height) / 2),
                      width: shown.width, height: shown.height)
    }
}
