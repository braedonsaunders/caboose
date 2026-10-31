import CoreGraphics
import Foundation

/// A toolkit reporter's `scroll.tree`: a window's scrollers as one application frame drew
/// them, in window-local display pixels (docs/display.md, "Scroll reports").
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
        scrollers = list.compactMap { s in
            guard let id = s["id"]?.int, let rect = s["rect"].flatMap(WindowFields.rect),
                  let offset = pair(s["offset"]), let range = pair(s["range"]) else { return nil }
            return Scroller(id: id, rect: rect, offset: offset, range: range,
                            fixed: s["fixed"]?.array?.compactMap(WindowFields.rect) ?? [])
        }
    }
}

/// The frame tag a reporter draws in a window's bottom overscan: 32 blocks, the sync
/// pattern 1010, the 24-bit value and the XOR of its nibbles (docs/display.md, "Frame tag").
public enum ScrollTag {
    public static let blocks = 32

    /// The value of 32 block luma samples (0–255), or nil when they are not a tag.
    public static func decode(_ luma: [Float]) -> Int? {
        guard luma.count == blocks else { return nil }
        let bits = luma.map { $0 >= 128 }
        guard Array(bits[0 ..< 4]) == [true, false, true, false] else { return nil }
        let value = bits[4 ..< 28].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        let check = bits[28 ..< 32].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        let expected = (0 ..< 6).reduce(0) { $0 ^ ((value >> (4 * $1)) & 0xF) }
        return check == expected ? value : nil
    }
}

/// A window's toolkit scroll reports: the recent ones by frame tag, for the pictures that
/// name them, and the scroll it has been driven with since, for its eventual position.
public final class ScrollReports {
    /// Reports kept to look tags up in: more than the pictures in flight between them.
    static let kept = 128

    public private(set) var latest: ScrollTree?
    private var tagged: [ScrollTree] = []
    /// `scroll.target`s sent and not yet applied in the latest report: seq and delta.
    private(set) var pending: [(seq: UInt64, delta: CGPoint)] = []

    /// Views waiting on reports for their pictures, called after every report.
    private var observers: [(owner: () -> AnyObject?, updated: () -> Void)] = []

    public init() {}

    /// Calls `updated` after every report while `owner` lives (a picture whose tag is valid
    /// may wait for the report it names).
    public func observe(_ owner: AnyObject, _ updated: @escaping () -> Void) {
        observers.removeAll { $0.owner() == nil || $0.owner() === owner }
        observers.append(({ [weak owner] in owner }, updated))
    }

    public func stopObserving(_ owner: AnyObject) { observers.removeAll { $0.owner() == nil || $0.owner() === owner } }

    public func record(_ tree: ScrollTree) {
        defer { for o in observers where o.owner() != nil { o.updated() } }
        latest = tree
        pending.removeAll { $0.seq <= tree.applied }
        guard tree.tag != nil else { return }
        tagged.append(tree)
        if tagged.count > Self.kept { tagged.removeFirst(tagged.count - Self.kept) }
    }

    public func sent(seq: UInt64, delta: CGPoint) { pending.append((seq, delta)) }

    /// A reporter draws tags for this window now.
    public var drawsTags: Bool { latest?.tag != nil && latest?.tagRect != nil }

    public func report(tag: Int) -> ScrollTree? { tagged.last { $0.tag == tag } }

    /// The primary scroller's offset once every target sent so far is applied.
    public var eventualOffset: CGPoint? {
        guard let primary = latest?.scrollers.first else { return nil }
        return pending.reduce(primary.offset) { CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y) }
    }

    public func forget() {
        latest = nil
        tagged.removeAll()
        pending.removeAll()
    }

    /// Picture pixels per window pixel: a picture covers the shown window and its overscan,
    /// which extends only one axis, so the other axis gives the scale.
    static func scale(picture: CGSize, shown: CGSize) -> CGFloat? {
        guard picture.width > 0, picture.height > 0, shown.width > 0, shown.height > 0 else { return nil }
        return min(picture.width / shown.width, picture.height / shown.height)
    }

    /// Where the newest report's tag is in a picture of `picture` size, picture pixels.
    public func tagRect(picture: CGSize, shown: CGSize) -> CGRect? {
        guard let rect = latest?.tagRect, latest?.tag != nil, let s = Self.scale(picture: picture, shown: shown) else { return nil }
        return CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
    }

    /// The observation for a picture whose tag read `luma`: its report's primary scroller in
    /// picture pixels along `axis`, or nil to measure the picture instead.
    public func observation(luma: [Float]?, picture: CGSize, shown: CGSize, axis: ScrollAxis) -> ScrollObservation? {
        guard let luma, let tag = ScrollTag.decode(luma), let tree = report(tag: tag), let primary = tree.scrollers.first,
              let s = Self.scale(picture: picture, shown: shown) else { return nil }
        func along(_ r: CGRect) -> Range<Int> {
            let (a, b) = axis == .vertical ? (r.minY, r.maxY) : (r.minX, r.maxX)
            return Int((a * s).rounded()) ..< max(Int((a * s).rounded()), Int((b * s).rounded()))
        }
        func across(_ r: CGRect) -> Range<Int> {
            along(CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width))
        }
        func region(_ r: CGRect) -> ScrollRegion { ScrollRegion(along: along(r), across: across(r)) }
        let offset = Double(axis.component(primary.offset) * s)
        let range = Double(axis.component(primary.range) * s)
        let stationary = primary.fixed.compactMap { f -> ScrollRegion? in
            let r = f.intersection(primary.rect)
            return r.isNull || r.isEmpty ? nil : region(r)
        }
        return .reported(offset: offset, region: region(primary.rect), bounds: 0 ... max(0, range), stationary: stationary,
                         epoch: tree.epoch)
    }
}
