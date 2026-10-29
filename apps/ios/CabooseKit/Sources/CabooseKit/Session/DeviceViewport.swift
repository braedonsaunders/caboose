import CoreGraphics

/// The device desktop and app card report their own laid-out content sizes. A hidden
/// desktop can keep its measurement current without taking geometry back from a card.
public struct DeviceViewport {
    public enum Owner { case desktop, card }
    public private(set) var owner: Owner = .desktop
    public private(set) var desktopSize: CGSize = .zero
    public private(set) var cardSize: CGSize = .zero

    public init() {}

    public mutating func presentCard() {
        owner = .card
        cardSize = .zero
    }

    public mutating func dismissCard() { owner = .desktop }

    /// Returns whether the active desktop viewport changed; this is not a monitor mode.
    @discardableResult public mutating func updateDesktop(_ size: CGSize) -> Bool {
        guard Self.valid(size) else { return false }
        let changed = size != desktopSize
        desktopSize = size
        return owner == .desktop && changed
    }

    @discardableResult public mutating func updateCard(_ size: CGSize) -> Bool {
        guard owner == .card, Self.valid(size), size != cardSize else { return false }
        cardSize = size
        return true
    }

    /// The viewport's local content bounds become guest pixels exactly once.
    public static func guestFrame(size: CGSize, pixelsPerPoint: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width * pixelsPerPoint,
               height: size.height * pixelsPerPoint).integral
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
