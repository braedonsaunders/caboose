import CoreGraphics
import CoreText
import Foundation

/// Thread-safe registry of session fonts (`scene.font`) keyed by 64-bit xxhash64 font hash.
public final class SceneFontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [UInt64: SceneFontDescriptor] = [:]
    private var ctDescriptors: [UInt64: CTFontDescriptor] = [:]
    private var cgFonts: [UInt64: CGFont] = [:]

    public init() {}

    public func register(_ descriptor: SceneFontDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptors[descriptor.font] = descriptor

        if let cfArr = CTFontManagerCreateFontDescriptorsFromData(descriptor.data as CFData) as? [CTFontDescriptor],
           !cfArr.isEmpty {
            let idx = min(max(0, descriptor.index), cfArr.count - 1)
            ctDescriptors[descriptor.font] = cfArr[idx]
            return
        }
        if let provider = CGDataProvider(data: descriptor.data as CFData),
           let cgFont = CGFont(provider) {
            cgFonts[descriptor.font] = cgFont
        }
    }

    public func descriptor(for hash: UInt64) -> SceneFontDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[hash]
    }

    public func ctFont(hash: UInt64, size: CGFloat) -> CTFont {
        lock.lock()
        let ctDesc = ctDescriptors[hash]
        let cgFont = cgFonts[hash]
        let family = descriptors[hash]?.family
        lock.unlock()

        let ptSize = max(1, size)
        if let ctDesc {
            return CTFontCreateWithFontDescriptor(ctDesc, ptSize, nil)
        }
        if let cgFont {
            return CTFontCreateWithGraphicsFont(cgFont, ptSize, nil, nil)
        }
        if let family, !family.isEmpty {
            return CTFontCreateWithName(family as CFString, ptSize, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, ptSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, ptSize, nil)
    }
}

/// One positioned glyph in a `SceneNode.glyphs` byte string: 10-byte little-endian `(u16 glyph_id, f32 x, f32 y)`.
public struct PositionedGlyph: Equatable, Sendable {
    public var glyphID: UInt16
    public var x: Float
    public var y: Float

    public init(glyphID: UInt16, x: Float, y: Float) {
        self.glyphID = glyphID
        self.x = x
        self.y = y
    }

    public static func unpack(_ data: Data) -> [PositionedGlyph] {
        let count = data.count / 10
        guard count > 0 else { return [] }
        var result: [PositionedGlyph] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0 ..< count {
                let base = i * 10
                let gid = UInt16(raw[base]) | (UInt16(raw[base + 1]) << 8)
                let xBits = UInt32(raw[base + 2])
                    | (UInt32(raw[base + 3]) << 8)
                    | (UInt32(raw[base + 4]) << 16)
                    | (UInt32(raw[base + 5]) << 24)
                let yBits = UInt32(raw[base + 6])
                    | (UInt32(raw[base + 7]) << 8)
                    | (UInt32(raw[base + 8]) << 16)
                    | (UInt32(raw[base + 9]) << 24)
                result.append(PositionedGlyph(
                    glyphID: gid,
                    x: Float(bitPattern: xBits),
                    y: Float(bitPattern: yBits)
                ))
            }
        }
        return result
    }
}

/// Retained per-window vector & glyph scene graph state (`scene.commit`) with 120 Hz local scroll.
public final class WindowSceneState: @unchecked Sendable {
    private let lock = NSLock()
    public let windowID: Int
    public private(set) var rootID: UInt64 = 0
    public private(set) var lastSeq: UInt64 = 0
    public private(set) var nodes: [UInt64: SceneNode] = [:]
    public private(set) var localScrollOffsets: [UInt64: CGPoint] = [:]

    public init(windowID: Int) {
        self.windowID = windowID
    }

    public func apply(_ commit: SceneCommit) {
        lock.lock()
        defer { lock.unlock() }
        if commit.reset {
            nodes.removeAll(keepingCapacity: false)
            localScrollOffsets.removeAll(keepingCapacity: false)
        }
        for removed in commit.remove {
            nodes.removeValue(forKey: removed)
            localScrollOffsets.removeValue(forKey: removed)
        }
        for node in commit.nodes {
            nodes[node.id] = node
            if node.kind == .scroll, let s = node.scroll {
                if localScrollOffsets[node.id] == nil {
                    localScrollOffsets[node.id] = CGPoint(x: s.minX, y: s.minY)
                }
            }
        }
        rootID = commit.root
        lastSeq = commit.seq
    }

    /// Updates local scroll immediately for 120 Hz display response and returns the `.sceneScroll` client message.
    public func userScrolled(nodeID: UInt64, offset: CGPoint) -> ClientMessage {
        lock.lock()
        localScrollOffsets[nodeID] = offset
        lock.unlock()
        return .sceneScroll(window: windowID, node: Int(nodeID), sx: Double(offset.x), sy: Double(offset.y))
    }

    /// Rasterizes the retained scene graph at `size * scale` (Retina resolution) using CoreGraphics & CoreText.
    public func render(size: CGSize, scale: CGFloat = 1.0, fontCache: SceneFontCache) -> CGImage? {
        let s = max(1.0, scale)
        let pixelW = Int((size.width * s).rounded())
        let pixelH = Int((size.height * s).rounded())
        guard pixelW > 0, pixelH > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pixelW,
                  height: pixelH,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelW * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Flip to top-left origin in logical window coordinates, scaled by Retina factor `s`.
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: s, y: -s)

        lock.lock()
        let root = rootID
        let snapshotNodes = nodes
        let scrollOffsets = localScrollOffsets
        lock.unlock()

        var visited: Set<UInt64> = []
        drawNode(id: root, in: ctx, nodes: snapshotNodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)
        return ctx.makeImage()
    }

    private func drawNode(
        id: UInt64,
        in ctx: CGContext,
        nodes: [UInt64: SceneNode],
        scrollOffsets: [UInt64: CGPoint],
        fontCache: SceneFontCache,
        visited: inout Set<UInt64>
    ) {
        guard !visited.contains(id), let node = nodes[id] else { return }
        visited.insert(id)
        defer { visited.remove(id) }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch node.kind {
        case .group:
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .clip:
            if let r = node.rect {
                ctx.clip(to: r)
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .rclip:
            if let r = node.rect {
                let path = roundedPath(rect: r, radii: node.radius)
                ctx.addPath(path)
                ctx.clip()
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .scroll:
            if let r = node.rect {
                ctx.clip(to: r)
            }
            let offset = scrollOffsets[node.id] ?? CGPoint(x: node.scroll?.minX ?? 0, y: node.scroll?.minY ?? 0)
            ctx.translateBy(x: -offset.x, y: -offset.y)
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .rect:
            if let r = node.rect, let rgba = node.color {
                ctx.setFillColor(cgColor(rgba))
                if let radii = node.radius, radii.contains(where: { $0 > 0 }) {
                    ctx.addPath(roundedPath(rect: r, radii: radii))
                    ctx.fillPath()
                } else {
                    ctx.fill(r)
                }
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .border:
            if let r = node.rect, let rgba = node.color {
                ctx.setStrokeColor(cgColor(rgba))
                ctx.setLineWidth(1.0)
                let path = roundedPath(rect: r.insetBy(dx: 0.5, dy: 0.5), radii: node.radius)
                ctx.addPath(path)
                ctx.strokePath()
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .shadow:
            if let r = node.rect, let rgba = node.color {
                ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: cgColor(rgba))
                ctx.setFillColor(cgColor(rgba))
                ctx.addPath(roundedPath(rect: r, radii: node.radius))
                ctx.fillPath()
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .glyphs:
            if let glyphData = node.glyphs {
                let unpacked = PositionedGlyph.unpack(glyphData)
                if !unpacked.isEmpty {
                    let rgba = node.color ?? 0xFFFF_FFFF
                    ctx.setFillColor(cgColor(rgba))
                    let ptSize = CGFloat(node.size ?? 14.0)
                    let font = fontCache.ctFont(hash: node.font ?? 0, size: ptSize)
                    let originX = node.rect?.minX ?? 0
                    let originY = node.rect?.minY ?? 0

                    var cgGlyphs = unpacked.map { CGGlyph($0.glyphID) }
                    // Because context is y-down (scaled by +x, -y), flip text matrix vertically so glyphs are upright.
                    ctx.saveGState()
                    ctx.translateBy(x: originX, y: originY)
                    ctx.scaleBy(x: 1.0, y: -1.0)
                    var positions = unpacked.map { CGPoint(x: CGFloat($0.x), y: -CGFloat($0.y)) }
                    CTFontDrawGlyphs(font, &cgGlyphs, &positions, unpacked.count, ctx)
                    ctx.restoreGState()
                }
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)

        case .path, .surface:
            if let r = node.rect, let rgba = node.color {
                ctx.setFillColor(cgColor(rgba))
                ctx.fill(r)
            }
            drawChildren(node, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)
        }
    }

    private func drawChildren(
        _ node: SceneNode,
        in ctx: CGContext,
        nodes: [UInt64: SceneNode],
        scrollOffsets: [UInt64: CGPoint],
        fontCache: SceneFontCache,
        visited: inout Set<UInt64>
    ) {
        guard let children = node.children else { return }
        for childID in children {
            drawNode(id: childID, in: ctx, nodes: nodes, scrollOffsets: scrollOffsets, fontCache: fontCache, visited: &visited)
        }
    }

    private func cgColor(_ rgba: UInt32) -> CGColor {
        let r = CGFloat((rgba >> 24) & 0xFF) / 255.0
        let g = CGFloat((rgba >> 16) & 0xFF) / 255.0
        let b = CGFloat((rgba >> 8) & 0xFF) / 255.0
        let a = CGFloat(rgba & 0xFF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private func roundedPath(rect: CGRect, radii: [Int]?) -> CGPath {
        guard let radii, radii.count == 4, radii.contains(where: { $0 > 0 }) else {
            return CGPath(rect: rect, transform: nil)
        }
        let maxR = min(rect.width, rect.height) / 2.0
        let r = min(maxR, CGFloat(radii.max() ?? 0))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}
