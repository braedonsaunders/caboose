import CoreGraphics

/// Desktop coordinates are in points. A normal window's frame starts at its title bar;
/// its height counts only the remote content below that bar.
public enum DesktopGeometry {
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

    /// The entire remote picture stays visible, including while a new size is arriving.
    /// During resize it stretches to the tile; otherwise minimum-size windows fit inside it.
    public static func surfaceFrame(natural: CGSize, available: CGSize, resizing: Bool) -> CGRect {
        guard natural.width > 0, natural.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        if resizing { return CGRect(origin: .zero, size: available) }
        let scale = min(1, available.width / natural.width, available.height / natural.height)
        let shown = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: max(0, (available.width - shown.width) / 2),
                      y: scale < 1 ? 0 : max(0, (available.height - shown.height) / 2),
                      width: shown.width, height: shown.height)
    }
}
