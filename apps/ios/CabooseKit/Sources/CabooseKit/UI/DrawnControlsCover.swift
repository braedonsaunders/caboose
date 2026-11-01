import CoreGraphics
import Metal
import QuartzCore

/// Covers the window controls an application draws in its own page (an Electron app's
/// HTML minimize, maximize and close; `RemoteWindow.drawnControls`). Caboose's own are on
/// every window, so the app's are hidden under a patch of the colour just beside them, the
/// title bar's own, and never receive a click.
///
/// The colour is read from the window's snapshot (`WindowSnapshot`, a copy of a frame its GPU
/// layer presented), one pixel beside each row, on the GPU:
/// a row against the right side samples left of it, one against the left side right of it.
/// A colour is adopted only when two readings agree, so a picture caught mid-change never
/// flashes a wrong patch.
@MainActor
final class DrawnControlsCover {
    private var layers: [CALayer] = []
    private var rows: [CGRect] = []
    private var colours: [CGColor?] = []
    private var pending: [UInt32?] = []
    private var sampledAt: CFTimeInterval = 0
    private var sampling = false
    /// How often the colour is read again, in seconds.
    private static let interval: CFTimeInterval = 0.5

    /// The rows the controls form, in window pixels: neighbours less than a control apart
    /// join one row, so a cover spans the gaps between them too.
    static func rows(_ controls: [CGRect]) -> [CGRect] {
        var rows: [CGRect] = []
        for rect in controls.sorted(by: { $0.minX < $1.minX }) {
            if let last = rows.last, rect.minX - last.maxX <= max(12, rect.width), abs(rect.midY - last.midY) < rect.height {
                rows[rows.count - 1] = last.union(rect)
            } else {
                rows.append(rect)
            }
        }
        return rows
    }

    /// Where a row's colour is read, in window pixels: beside it, toward the window's middle.
    static func samplePoint(of row: CGRect, windowWidth: CGFloat) -> CGPoint {
        let towardMiddle = row.midX > windowWidth / 2
        let x = towardMiddle ? row.minX - 3 : row.maxX + 3
        return CGPoint(x: min(max(0, x), max(0, windowWidth - 1)), y: row.midY)
    }

    /// Lays the covers out over `host`, whose bounds show a window `frame` pixels in size.
    func layout(in host: CALayer, controls: [CGRect], frame: CGSize) {
        let rows = Self.rows(controls)
        if rows != self.rows {
            self.rows = rows
            colours = Array(repeating: nil, count: rows.count)
            pending = Array(repeating: nil, count: rows.count)
            sampledAt = 0
        }
        while layers.count < rows.count {
            let cover = CALayer()
            cover.zPosition = 50
            cover.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
            host.addSublayer(cover)
            layers.append(cover)
        }
        while layers.count > rows.count { layers.removeLast().removeFromSuperlayer() }
        guard frame.width > 0, frame.height > 0 else { return }
        let sx = host.bounds.width / frame.width, sy = host.bounds.height / frame.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, row) in rows.enumerated() {
            let cover = layers[index]
            if cover.superlayer !== host { host.addSublayer(cover) }
            cover.frame = CGRect(x: row.minX * sx, y: row.minY * sy, width: row.width * sx, height: row.height * sy)
            cover.backgroundColor = colours[index]
            // Until its colour is known, the app's own controls show rather than a guess.
            cover.isHidden = colours[index] == nil
        }
        CATransaction.commit()
    }

    func removeAll() {
        layers.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
        rows.removeAll()
        colours.removeAll()
        pending.removeAll()
    }

    /// Reads each row's colour from `texture`, a picture of a window `frame` pixels in size,
    /// at most every half second. The texture must stay valid until its GPU work completes.
    func sample(_ texture: MTLTexture, frame: CGSize, apply: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        guard !rows.isEmpty, !sampling, now - sampledAt >= Self.interval, frame.width > 0, frame.height > 0 else { return }
        let bgra: Bool
        switch texture.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb: bgra = true
        case .rgba8Unorm, .rgba8Unorm_srgb: bgra = false
        default: return
        }
        let renderer = SharedMetal.shared
        guard let buffer = renderer.device.makeBuffer(length: 4 * rows.count, options: .storageModeShared),
              let commands = renderer.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        // Pixels are square: a picture of another height than the window keeps its scale.
        let sx = CGFloat(texture.width) / frame.width, sy = sx
        for (index, row) in rows.enumerated() {
            let point = Self.samplePoint(of: row, windowWidth: frame.width)
            let x = min(texture.width - 1, max(0, Int(point.x * sx))), y = min(texture.height - 1, max(0, Int(point.y * sy)))
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer,
                      destinationOffset: 4 * index, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        }
        blit.endEncoding()
        sampling = true
        sampledAt = now
        let count = rows.count, sampledRows = rows
        commands.addCompletedHandler { [weak self] _ in
            let bytes = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
            let pixels = (0..<count).map { bytes[$0] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampling = false
                    guard self.rows == sampledRows else { return }
                    for (index, pixel) in pixels.enumerated() {
                        // Adopted when two readings agree.
                        if self.pending[index] == pixel { self.colours[index] = Self.colour(pixel, bgra: bgra) }
                        self.pending[index] = pixel
                    }
                    apply()
                }
            }
        }
        commands.commit()
    }

    static func colour(_ pixel: UInt32, bgra: Bool) -> CGColor {
        // Little-endian: the first byte in memory is the lowest.
        let first = CGFloat(pixel & 0xFF) / 255, second = CGFloat((pixel >> 8) & 0xFF) / 255, third = CGFloat((pixel >> 16) & 0xFF) / 255
        return bgra ? CGColor(red: third, green: second, blue: first, alpha: 1) : CGColor(red: first, green: second, blue: third, alpha: 1)
    }
}
