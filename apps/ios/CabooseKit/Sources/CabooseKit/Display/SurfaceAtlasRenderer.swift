import CoreGraphics
import Foundation
import ImageIO

/// Byte-perfect codec for Caboose Surface & Tile Atlas (`surface.batch` / `surface.reset`).
public enum SurfaceAtlasCodec {
    private static let prime1: UInt64 = 11_400_714_785_074_694_791
    private static let prime2: UInt64 = 14_029_467_366_897_019_727
    private static let prime3: UInt64 = 1_609_587_929_392_839_161
    private static let prime4: UInt64 = 9_650_029_242_287_828_579
    private static let prime5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always)
    private static func rotl64(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always)
    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* prime2)
        a = rotl64(a, 31)
        return a &* prime1
    }

    @inline(__always)
    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        var a = acc ^ round(0, val)
        a = (a &* prime1) &+ prime4
        return a
    }

    @inline(__always)
    private static func readU64LE(_ ptr: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(start: ptr.advanced(by: offset), count: 8))
        }
        return UInt64(littleEndian: v)
    }

    @inline(__always)
    private static func readU32LE(_ ptr: UnsafeRawPointer, _ offset: Int) -> UInt64 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(start: ptr.advanced(by: offset), count: 4))
        }
        return UInt64(UInt32(littleEndian: v))
    }

    /// Exact XXHash64 matching Rust's `xxhash_rust::xxh64::xxh64(data, seed)`.
    public static func xxh64(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { raw in
            let len = raw.count
            guard let base = raw.baseAddress else {
                var h = seed &+ prime5
                h ^= h >> 33
                h &*= prime2
                h ^= h >> 29
                h &*= prime3
                h ^= h >> 32
                return h
            }

            var p = 0
            var h64: UInt64
            if len >= 32 {
                let limit = len - 32
                var v1 = seed &+ prime1 &+ prime2
                var v2 = seed &+ prime2
                var v3 = seed
                var v4 = seed &- prime1
                repeat {
                    v1 = round(v1, readU64LE(base, p)); p += 8
                    v2 = round(v2, readU64LE(base, p)); p += 8
                    v3 = round(v3, readU64LE(base, p)); p += 8
                    v4 = round(v4, readU64LE(base, p)); p += 8
                } while p <= limit

                h64 = rotl64(v1, 1) &+ rotl64(v2, 7) &+ rotl64(v3, 12) &+ rotl64(v4, 18)
                h64 = mergeRound(h64, v1)
                h64 = mergeRound(h64, v2)
                h64 = mergeRound(h64, v3)
                h64 = mergeRound(h64, v4)
            } else {
                h64 = seed &+ prime5
            }

            h64 &+= UInt64(len)

            while p + 8 <= len {
                let k1 = round(0, readU64LE(base, p))
                h64 ^= k1
                h64 = (rotl64(h64, 27) &* prime1) &+ prime4
                p += 8
            }

            if p + 4 <= len {
                h64 ^= readU32LE(base, p) &* prime1
                h64 = (rotl64(h64, 23) &* prime2) &+ prime3
                p += 4
            }

            while p < len {
                let byte = UInt64(raw[p])
                h64 ^= byte &* prime5
                h64 = rotl64(h64, 11) &* prime1
                p += 1
            }

            h64 ^= h64 >> 33
            h64 &*= prime2
            h64 ^= h64 >> 29
            h64 &*= prime3
            h64 ^= h64 >> 32
            return h64
        }
    }

    /// Decodes a 4-byte little-endian uncompressed size prefix followed by an LZ4 block stream
    /// (matching `lz4_flex::compress_prepend_size`).
    public static func lz4DecompressPrependSize(_ data: Data, maxOutputBytes: Int = 16 * 1024 * 1024) -> Data? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { raw -> Data? in
            let expectedLen = Int(raw[0]) | (Int(raw[1]) << 8) | (Int(raw[2]) << 16) | (Int(raw[3]) << 24)
            guard expectedLen >= 0, expectedLen <= maxOutputBytes else { return nil }
            if expectedLen == 0 {
                return data.count == 4 ? Data() : nil
            }
            var out = Data(count: expectedLen)
            let ok = out.withUnsafeMutableBytes { dstBuf -> Bool in
                guard let dst = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                var ip = 4
                let iend = raw.count
                var op = 0

                while ip < iend {
                    let token = Int(raw[ip])
                    ip += 1

                    var litLen = token >> 4
                    if litLen == 15 {
                        while true {
                            guard ip < iend else { return false }
                            let s = Int(raw[ip])
                            ip += 1
                            litLen += s
                            if s != 255 { break }
                        }
                    }

                    guard ip + litLen <= iend, op + litLen <= expectedLen else { return false }
                    if litLen > 0 {
                        for i in 0 ..< litLen {
                            dst[op + i] = raw[ip + i]
                        }
                        ip += litLen
                        op += litLen
                    }

                    if ip == iend { break }
                    guard ip + 2 <= iend else { return false }
                    let offset = Int(raw[ip]) | (Int(raw[ip + 1]) << 8)
                    ip += 2
                    guard offset > 0, offset <= op else { return false }

                    var matchLen = (token & 0x0F) + 4
                    if (token & 0x0F) == 15 {
                        while true {
                            guard ip < iend else { return false }
                            let s = Int(raw[ip])
                            ip += 1
                            matchLen += s
                            if s != 255 { break }
                        }
                    }

                    guard op + matchLen <= expectedLen else { return false }
                    let matchPos = op - offset
                    for i in 0 ..< matchLen {
                        dst[op + i] = dst[matchPos + i]
                    }
                    op += matchLen
                }

                return op == expectedLen
            }
            return ok ? out : nil
        }
    }

    /// Decodes a `SurfaceTile` (`pal2-lz4`, `pal16-lz4`, `rgba-lz4`, or `png`) into `w * h * 4` RGBA8888 bytes.
    public static func decodeTile(_ tile: SurfaceTile) -> Data? {
        let w = Int(tile.rect.width)
        let h = Int(tile.rect.height)
        guard w > 0, h > 0 else { return nil }
        let pixelCount = w * h
        let byteCount = pixelCount * 4

        switch tile.format {
        case .rgbaLz4:
            guard let decoded = lz4DecompressPrependSize(tile.data, maxOutputBytes: byteCount),
                  decoded.count == byteCount else { return nil }
            return decoded

        case .pal2Lz4:
            let packedBytes = (pixelCount + 7) / 8
            let expectedRaw = 8 + packedBytes
            guard let raw = lz4DecompressPrependSize(tile.data, maxOutputBytes: expectedRaw),
                  raw.count == expectedRaw else { return nil }
            var out = Data(count: byteCount)
            raw.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    let c0r = src[0], c0g = src[1], c0b = src[2], c0a = src[3]
                    let c1r = src[4], c1g = src[5], c1b = src[6], c1a = src[7]
                    for i in 0 ..< pixelCount {
                        let byte = src[8 + (i / 8)]
                        let bit = (byte >> (i & 7)) & 1
                        let o = i * 4
                        if bit == 0 {
                            dst[o] = c0r; dst[o + 1] = c0g; dst[o + 2] = c0b; dst[o + 3] = c0a
                        } else {
                            dst[o] = c1r; dst[o + 1] = c1g; dst[o + 2] = c1b; dst[o + 3] = c1a
                        }
                    }
                }
            }
            return out

        case .pal16Lz4:
            guard let raw = lz4DecompressPrependSize(tile.data, maxOutputBytes: 1 + 16 * 4 + (pixelCount + 1) / 2),
                  !raw.isEmpty else { return nil }
            let count = Int(raw[0])
            guard count >= 1, count <= 16 else { return nil }
            let packedBytes = (pixelCount + 1) / 2
            guard raw.count == 1 + count * 4 + packedBytes else { return nil }
            var out = Data(count: byteCount)
            let ok = raw.withUnsafeBytes { src -> Bool in
                out.withUnsafeMutableBytes { dst -> Bool in
                    let palStart = 1
                    let idxStart = 1 + count * 4
                    for i in 0 ..< pixelCount {
                        let byte = src[idxStart + (i / 2)]
                        let idx = Int((i & 1) == 0 ? (byte & 0x0F) : (byte >> 4))
                        guard idx < count else { return false }
                        let p = palStart + idx * 4
                        let o = i * 4
                        dst[o] = src[p]
                        dst[o + 1] = src[p + 1]
                        dst[o + 2] = src[p + 2]
                        dst[o + 3] = src[p + 3]
                    }
                    return true
                }
            }
            return ok ? out : nil

        case .png:
            guard let source = CGImageSourceCreateWithData(tile.data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  cgImage.width == w, cgImage.height == h else { return nil }
            var out = Data(count: byteCount)
            let ok = out.withUnsafeMutableBytes { dst -> Bool in
                guard let base = dst.baseAddress,
                      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(
                          data: base,
                          width: w,
                          height: h,
                          bitsPerComponent: 8,
                          bytesPerRow: w * 4,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return false }
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? out : nil
        }
    }
}

/// Thread-safe LRU cache of up to `capacity` decoded 64×64 RGBA8888 tiles (`16_384` bytes each).
public final class TileAtlasCache: @unchecked Sendable {
    public static let tileByteSize = 64 * 64 * 4

    private let lock = NSLock()
    public let capacity: Int
    private var currentEpoch: UInt64 = 0
    private var entries: [UInt64: Data] = [:]
    private var order: [UInt64] = []

    public init(capacity: Int = 32_768) {
        self.capacity = max(1, capacity)
    }

    public var epoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentEpoch
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func reset(epoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        currentEpoch = epoch
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    public func insert(hash: UInt64, rgba: Data) {
        guard rgba.count == Self.tileByteSize else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries[hash] != nil {
            if let idx = order.firstIndex(of: hash) {
                order.remove(at: idx)
            }
        } else if entries.count >= capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[hash] = rgba
        order.append(hash)
    }

    public func get(hash: UInt64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = entries[hash] else { return nil }
        if order.last != hash, let idx = order.firstIndex(of: hash) {
            order.remove(at: idx)
            order.append(hash)
        }
        return data
    }
}

/// Per-window RGBA8888 backing buffer & compositor for `surface.batch` frames.
public final class SurfaceAtlasRenderer: @unchecked Sendable {
    private struct WindowBuffer {
        var width: Int
        var height: Int
        var bytes: Data
    }

    private let lock = NSLock()
    private var windows: [Int: WindowBuffer] = [:]

    public init() {}

    public func removeWindow(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        windows.removeValue(forKey: id)
    }

    public func rgbaBytes(forWindow id: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return windows[id]?.bytes
    }

    /// Applies `batch` in exact protocol order (`copies` -> `fills` -> `refs` -> `tiles`) and returns a `CGImage`.
    public func apply(_ batch: SurfaceBatch, cache: TileAtlasCache) -> CGImage? {
        let w = Int(batch.size.width)
        let h = Int(batch.size.height)
        guard w > 0, h > 0 else { return nil }
        let totalBytes = w * h * 4

        lock.lock()
        var buf: WindowBuffer
        if let existing = windows[batch.window], existing.width == w, existing.height == h, !batch.keyframe {
            buf = existing
        } else {
            buf = WindowBuffer(width: w, height: h, bytes: Data(count: totalBytes))
        }

        // 1. Copies (using snapshot of previous buffer so overlapping shifts never clobber source pixels).
        if !batch.copies.isEmpty {
            let prev = buf.bytes
            prev.withUnsafeBytes { src in
                buf.bytes.withUnsafeMutableBytes { dst in
                    for copy in batch.copies {
                        let dstX0 = Int(copy.rect.minX)
                        let dstY0 = Int(copy.rect.minY)
                        let cw = Int(copy.rect.width)
                        let ch = Int(copy.rect.height)
                        guard cw > 0, ch > 0 else { continue }
                        for row in 0 ..< ch {
                            let dy = dstY0 + row
                            let sy = dy - copy.dy
                            guard dy >= 0, dy < h, sy >= 0, sy < h else { continue }
                            for col in 0 ..< cw {
                                let dx = dstX0 + col
                                let sx = dx - copy.dx
                                guard dx >= 0, dx < w, sx >= 0, sx < w else { continue }
                                let sOff = (sy * w + sx) * 4
                                let dOff = (dy * w + dx) * 4
                                dst[dOff] = src[sOff]
                                dst[dOff + 1] = src[sOff + 1]
                                dst[dOff + 2] = src[sOff + 2]
                                dst[dOff + 3] = src[sOff + 3]
                            }
                        }
                    }
                }
            }
        }

        // 2. Fills
        if !batch.fills.isEmpty {
            buf.bytes.withUnsafeMutableBytes { dst in
                for fill in batch.fills {
                    let x0 = max(0, Int(fill.rect.minX))
                    let y0 = max(0, Int(fill.rect.minY))
                    let x1 = min(w, Int(fill.rect.minX) + Int(fill.rect.width))
                    let y1 = min(h, Int(fill.rect.minY) + Int(fill.rect.height))
                    guard x0 < x1, y0 < y1 else { continue }
                    let r = UInt8((fill.rgba >> 24) & 0xFF)
                    let g = UInt8((fill.rgba >> 16) & 0xFF)
                    let b = UInt8((fill.rgba >> 8) & 0xFF)
                    let a = UInt8(fill.rgba & 0xFF)
                    for y in y0 ..< y1 {
                        let rowBase = y * w * 4
                        for x in x0 ..< x1 {
                            let off = rowBase + x * 4
                            dst[off] = r
                            dst[off + 1] = g
                            dst[off + 2] = b
                            dst[off + 3] = a
                        }
                    }
                }
            }
        }

        // 3. Refs (64x64 cached tiles)
        if !batch.refs.isEmpty {
            for ref in batch.refs {
                guard let tileData = cache.get(hash: ref.hash) else { continue }
                blitTile(tileData, tileX: ref.x, tileY: ref.y, tileW: 64, tileH: 64, into: &buf.bytes, surfaceW: w, surfaceH: h)
            }
        }

        // 4. New tiles
        if !batch.tiles.isEmpty {
            for tile in batch.tiles {
                guard let decoded = SurfaceAtlasCodec.decodeTile(tile) else { continue }
                let tw = Int(tile.rect.width)
                let th = Int(tile.rect.height)
                if let hash = tile.hash, tw == 64, th == 64 {
                    cache.insert(hash: hash, rgba: decoded)
                }
                blitTile(decoded, tileX: Int(tile.rect.minX), tileY: Int(tile.rect.minY), tileW: tw, tileH: th, into: &buf.bytes, surfaceW: w, surfaceH: h)
            }
        }

        windows[batch.window] = buf
        let snapshot = buf.bytes
        lock.unlock()

        guard let provider = CGDataProvider(data: snapshot as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func blitTile(_ tileData: Data, tileX: Int, tileY: Int, tileW: Int, tileH: Int, into surface: inout Data, surfaceW: Int, surfaceH: Int) {
        let x0 = max(0, tileX)
        let y0 = max(0, tileY)
        let x1 = min(surfaceW, tileX + tileW)
        let y1 = min(surfaceH, tileY + tileH)
        guard x0 < x1, y0 < y1 else { return }
        let copyCols = x1 - x0
        tileData.withUnsafeBytes { src in
            surface.withUnsafeMutableBytes { dst in
                for y in y0 ..< y1 {
                    let ty = y - tileY
                    let tx = x0 - tileX
                    let sOff = (ty * tileW + tx) * 4
                    let dOff = (y * surfaceW + x0) * 4
                    let count = copyCols * 4
                    for i in 0 ..< count {
                        dst[dOff + i] = src[sOff + i]
                    }
                }
            }
        }
    }
}
