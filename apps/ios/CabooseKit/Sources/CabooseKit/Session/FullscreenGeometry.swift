import CoreGraphics

/// A committed window snapshot, observed atomically by presentation code.
public struct WindowGeometryState: Equatable {
    public var frame: CGRect
    public var fullscreen: Bool
    public init(frame: CGRect, fullscreen: Bool) {
        self.frame = frame
        self.fullscreen = fullscreen
    }
}

/// Keeps the last ordinary committed geometry through fullscreen monitor changes.
/// Entry never requests a size. Exit returns one restore request; a window first
/// seen fullscreen has no invented ordinary geometry to restore.
public struct FullscreenGeometry {
    public private(set) var ordinary: CGRect?
    /// True only for the first observed fullscreen state or a false-to-true transition.
    public private(set) var entered = false
    private var fullscreen = false
    public init() {}

    public mutating func observe(_ state: WindowGeometryState) -> CGRect? {
        entered = state.fullscreen && !fullscreen
        if state.fullscreen {
            fullscreen = true
            return nil
        }
        if fullscreen {
            fullscreen = false
            if let ordinary { return ordinary }
        }
        ordinary = state.frame
        return nil
    }
}
