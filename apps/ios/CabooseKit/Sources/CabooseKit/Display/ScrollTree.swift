import CoreGraphics
import Foundation

/// A toolkit reporter's `scroll.tree`: a window's scrollers as one application frame drew
/// them, in window-local display pixels (docs/display.md, "Scroll reports"). The codec reads
/// it; the app does not ask for reports (hello `scroll`), so a session ignores it.
public struct ScrollTree: Equatable, Sendable {
    public struct Scroller: Equatable, Sendable {
        public var id: Int
        public var rect: CGRect
        public var offset: CGPoint
        /// The largest offset; the smallest is 0.
        public var range: CGPoint
        /// Inside `rect`, not moving with the content: fixed and stuck sticky elements, the tag.
        public var fixed: [CGRect]

        public init(id: Int, rect: CGRect, offset: CGPoint, range: CGPoint, fixed: [CGRect] = []) {
            self.id = id; self.rect = rect; self.offset = offset; self.range = range; self.fixed = fixed
        }
    }

    public var window: Int
    /// The 24-bit frame tag in the pictures this report describes, and where it is drawn.
    public var tag: Int?
    public var tagRect: CGRect?
    /// The last `scroll.target` seq the application had applied when it drew the frame.
    public var applied: UInt64
    public var epoch: UInt64
    /// The primary scroller first.
    public var scrollers: [Scroller]
    /// The page's visual scale (a pinch zoom); while it is not 1 the primary scroller's
    /// offset and range are in pixels of the zoomed content.
    public var zoom: Double = 1
    /// The scales the page allows.
    public var zoomRange: ClosedRange<Double>?

    public init(window: Int, tag: Int?, tagRect: CGRect?, applied: UInt64, epoch: UInt64, scrollers: [Scroller]) {
        self.window = window; self.tag = tag; self.tagRect = tagRect; self.applied = applied; self.epoch = epoch
        self.scrollers = scrollers
    }

    init?(_ body: CBOR) {
        guard let window = body["id"]?.int, let applied = body["applied"]?.uint64, let epoch = body["epoch"]?.uint64,
              let list = body["scrollers"]?.array else { return nil }
        func pair(_ value: CBOR?) -> CGPoint? {
            guard let a = value?.array, a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
            return CGPoint(x: x, y: y)
        }
        self.window = window
        tag = body["tag"]?.int
        tagRect = body["tag_rect"].flatMap(WindowFields.rect)
        self.applied = applied
        self.epoch = epoch
        zoom = body["zoom"]?.double ?? 1
        if let r = body["zoom_range"]?.array, r.count == 2, let low = r[0].double, let high = r[1].double, low > 0, low <= high {
            zoomRange = low ... high
        }
        scrollers = list.compactMap { s in
            guard let id = s["id"]?.int, let rect = s["rect"].flatMap(WindowFields.rect),
                  let offset = pair(s["offset"]), let range = pair(s["range"]) else { return nil }
            return Scroller(id: id, rect: rect, offset: offset, range: range,
                            fixed: s["fixed"]?.array?.compactMap(WindowFields.rect) ?? [])
        }
    }
}
