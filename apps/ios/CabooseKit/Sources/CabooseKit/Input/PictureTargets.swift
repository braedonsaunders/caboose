import Foundation

/// Targets read from a window's picture, for windows whose accessibility tree lists none:
/// the compact shapes that stand out from the background around a touch (an icon, a check
/// box, a word, a button's face), each as a `TouchTarget` of kind `.other`.
///
/// Around the touch, the commonest colour is the background. Pixels clearly unlike it are
/// shape; shapes a few pixels apart are joined, so a word or an icon's parts make one.
/// Shapes that reach the edge of the area looked at, or fill much of it, are the window's
/// own furniture (a panel, a text body), not a control.
public enum PictureTargets {
    /// A colour channel this far from the background's is a shape's.
    static let contrast = 40
    /// Shapes this many pixels apart are one.
    static let join = 2
    /// Space around a shape that still presses it, in pixels.
    static let margin: CGFloat = 3

    /// Shapes within `radius` pixels of `point` in an RGBA (or BGRA) picture of `width` ×
    /// `height` pixels, `bytesPerRow` apart; rectangles in the picture's pixels.
    public static func find(in pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                            around point: CGPoint, radius: Int) -> [TouchTarget] {
        guard width > 0, height > 0, radius > 2, bytesPerRow >= width * 4, pixels.count >= bytesPerRow * height,
              point.x.isFinite, point.y.isFinite else { return [] }
        let x0 = max(0, Int(point.x) - radius), y0 = max(0, Int(point.y) - radius)
        let x1 = min(width, Int(point.x) + radius), y1 = min(height, Int(point.y) + radius)
        let w = x1 - x0, h = y1 - y0
        guard w > 4, h > 4 else { return [] }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y0 + y) * bytesPerRow + (x0 + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        // The background: the commonest colour, at 5 bits a channel.
        var counts: [Int: Int] = [:]
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let (r, g, b) = pixel(x, y)
                counts[(r >> 3) << 10 | (g >> 3) << 5 | b >> 3, default: 0] += 1
            }
        }
        guard let common = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        let background = (((common >> 10) & 31) << 3 + 4, ((common >> 5) & 31) << 3 + 4, (common & 31) << 3 + 4)
        // Shape pixels, joined across small gaps.
        var shape = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = pixel(x, y)
                if max(abs(r - background.0), abs(g - background.1), abs(b - background.2)) > contrast {
                    for dy in -join...join {
                        let yy = y + dy
                        guard yy >= 0, yy < h else { continue }
                        for dx in -join...join where x + dx >= 0 && x + dx < w {
                            shape[yy * w + x + dx] = true
                        }
                    }
                }
            }
        }
        // Connected shapes and their bounds.
        var label = [Int32](repeating: -1, count: w * h)
        var found: [TouchTarget] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where shape[start] && label[start] < 0 {
            var minX = w, minY = h, maxX = -1, maxY = -1, size = 0
            label[start] = 1
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                size += 1
                for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                where n >= 0 && shape[n] && label[n] < 0 {
                    label[n] = 1
                    stack.append(n)
                }
            }
            // The joining grew every shape by `join`; take that back.
            let bw = maxX - minX + 1 - 2 * join, bh = maxY - minY + 1 - 2 * join
            let edge = (minX == 0 && x0 > 0) || (minY == 0 && y0 > 0) || (maxX == w - 1 && x1 < width) || (maxY == h - 1 && y1 < height)
            guard !edge, bw >= 3, bh >= 3, bw * bh < w * h / 3 else { continue }
            let rect = CGRect(x: CGFloat(x0 + minX + join), y: CGFloat(y0 + minY + join), width: CGFloat(bw), height: CGFloat(bh))
            found.append(TouchTarget(rect: rect.insetBy(dx: -margin, dy: -margin), kind: .other))
        }
        return found
    }
}
