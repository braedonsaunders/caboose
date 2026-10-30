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
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
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

    /// Converts RGBA8888 pixel bytes to BGRA8888 pixel bytes.
    public static func rgbaToBgra(_ rgba: Data) -> Data {
        let count = rgba.count
        guard count > 0, count % 4 == 0 else { return rgba }
        var bgra = Data(count: count)
        rgba.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            bgra.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var i = 0
                while i < count {
                    dst[i] = src[i + 2]
                    dst[i + 1] = src[i + 1]
                    dst[i + 2] = src[i]
                    dst[i + 3] = src[i + 3]
                    i += 4
                }
            }
        }
        return bgra
    }

    /// Decodes a 4-byte little-endian uncompressed size prefix followed by an LZ4 block stream
    /// (matching `lz4_flex::compress_prepend_size`).
    public static func lz4DecompressPrependSize(_ data: Data, maxOutputBytes: Int = 16 * 1024 * 1024) -> Data? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            let b0 = Int(raw[0])
            let b1 = Int(raw[1]) << 8
            let b2 = Int(raw[2]) << 16
            let b3 = Int(raw[3]) << 24
            let expectedLen = b0 | b1 | b2 | b3
            guard expectedLen >= 0, expectedLen <= maxOutputBytes else { return nil }
            if expectedLen == 0 {
                return data.count == 4 ? Data() : nil
            }
            var out = Data(count: expectedLen)
            let ok = out.withUnsafeMutableBytes { (dstBuf: UnsafeMutableRawBufferPointer) -> Bool in
                guard let dst = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                var ip = 4
                let iend = raw.count
                var op = 0

                while ip < iend {
                    let token = Int(src[ip])
                    ip += 1

                    var litLen = token >> 4
                    if litLen == 15 {
                        while true {
                            guard ip < iend else { return false }
                            let s = Int(src[ip])
                            ip += 1
                            litLen += s
                            if s != 255 { break }
                        }
                    }

                    guard ip + litLen <= iend, op + litLen <= expectedLen else { return false }
                    if litLen > 0 {
                        dst.advanced(by: op).update(from: src.advanced(by: ip), count: litLen)
                        ip += litLen
                        op += litLen
                    }

                    if ip == iend { break }
                    guard ip + 2 <= iend else { return false }
                    let offset = Int(src[ip]) | (Int(src[ip + 1]) << 8)
                    ip += 2
                    guard offset > 0, offset <= op else { return false }

                    var matchLen = (token & 0x0F) + 4
                    if (token & 0x0F) == 15 {
                        while true {
                            guard ip < iend else { return false }
                            let s = Int(src[ip])
                            ip += 1
                            matchLen += s
                            if s != 255 { break }
                        }
                    }

                    guard op + matchLen <= expectedLen else { return false }
                    let matchPos = op - offset
                    if offset >= matchLen {
                        dst.advanced(by: op).update(from: dst.advanced(by: matchPos), count: matchLen)
                    } else {
                        for i in 0 ..< matchLen {
                            dst[op + i] = dst[matchPos + i]
                        }
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
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
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
            let ok = raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Bool in
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
            let ok = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Bool in
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

/// Thread-safe LRU cache of up to `capacity` decoded 64×64 tiles (`16_384` bytes each, cached as both RGBA8888 and BGRA8888).
public final class TileAtlasCache: @unchecked Sendable {
    public static let tileByteSize = 64 * 64 * 4

    private struct CachedTile {
        let rgba: Data
        let bgra: Data
    }

    private let lock = NSLock()
    public let capacity: Int
    private var currentEpoch: UInt64 = 0
    private var entries: [UInt64: CachedTile] = [:]
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
        let bgra = SurfaceAtlasCodec.rgbaToBgra(rgba)
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
        entries[hash] = CachedTile(rgba: rgba, bgra: bgra)
        order.append(hash)
    }

    public func get(hash: UInt64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[hash] else { return nil }
        if order.last != hash, let idx = order.firstIndex(of: hash) {
            order.remove(at: idx)
            order.append(hash)
        }
        return entry.rgba
    }

    public func getPair(hash: UInt64) -> (rgba: Data, bgra: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[hash] else { return nil }
        if order.last != hash, let idx = order.firstIndex(of: hash) {
            order.remove(at: idx)
            order.append(hash)
        }
        return (entry.rgba, entry.bgra)
    }
}

/// Per-window RGBA8888 / BGRA8888 backing buffer & compositor for `surface.batch` frames.
public final class SurfaceAtlasRenderer: @unchecked Sendable {
    private struct WindowBuffer {
        var width: Int
        var height: Int
        var bytes: Data
        var bgraBytes: Data
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

    /// Applies `batch` in exact protocol order (`copies` -> `fills` -> `refs` -> `tiles`) and uploads
    /// only the dirty BGRA region directly to `surface` without intermediate `CGContext` allocations.
    public func applyAndUpload(_ batch: SurfaceBatch, cache: TileAtlasCache, to surface: WindowSurface) -> Bool {
        let w = Int(batch.size.width)
        let h = Int(batch.size.height)
        guard w > 0, h > 0 else { return false }

        let targetW = Int(batch.rect.width.rounded(.up))
        let targetH = Int(batch.rect.height.rounded(.up))
        let isOneToOne = batch.rect.minX == 0 && batch.rect.minY == 0 && targetW == w && targetH == h
        if !isOneToOne {
            guard let image = apply(batch, cache: cache) else { return false }
            if batch.rect.minX == 0 && batch.rect.minY == 0 {
                surface.resize(width: targetW, height: targetH)
            }
            surface.upload(image: image, into: batch.rect)
            return true
        }

        let totalBytes = w * h * 4
        lock.lock()
        let existing = windows.removeValue(forKey: batch.window)
        var buf: WindowBuffer
        let isNewBuf: Bool
        if let existing, existing.width == w, existing.height == h, !batch.keyframe {
            buf = existing
            isNewBuf = false
        } else {
            buf = WindowBuffer(
                width: w,
                height: h,
                bytes: Data(count: totalBytes),
                bgraBytes: Data(count: totalBytes)
            )
            isNewBuf = true
        }

        let surfaceNeedsResize = surface.pixelSize != CGSize(width: w, height: h)
        guard let dirty = applyToBuffer(
            batch,
            cache: cache,
            buf: &buf,
            fullSurfaceDirty: isNewBuf || batch.keyframe || surfaceNeedsResize
        ) else {
            if let existing {
                windows[batch.window] = existing
            }
            lock.unlock()
            return false
        }

        if surfaceNeedsResize {
            surface.resize(width: w, height: h)
        }
        if dirty.width > 0 && dirty.height > 0 {
            buf.bgraBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress {
                    let offset = (dirty.y * w + dirty.x) * 4
                    surface.upload(
                        bgra: base.advanced(by: offset),
                        rowBytes: w * 4,
                        x: dirty.x,
                        y: dirty.y,
                        width: dirty.width,
                        height: dirty.height
                    )
                }
            }
        }

        windows[batch.window] = buf
        lock.unlock()
        return true
    }

    /// Applies `batch` in exact protocol order (`copies` -> `fills` -> `refs` -> `tiles`) and returns a `CGImage`.
    public func apply(_ batch: SurfaceBatch, cache: TileAtlasCache) -> CGImage? {
        let w = Int(batch.size.width)
        let h = Int(batch.size.height)
        guard w > 0, h > 0 else { return nil }
        let totalBytes = w * h * 4

        lock.lock()
        let existing = windows.removeValue(forKey: batch.window)
        var buf: WindowBuffer
        let isNewBuf: Bool
        if let existing, existing.width == w, existing.height == h, !batch.keyframe {
            buf = existing
            isNewBuf = false
        } else {
            buf = WindowBuffer(
                width: w,
                height: h,
                bytes: Data(count: totalBytes),
                bgraBytes: Data(count: totalBytes)
            )
            isNewBuf = true
        }

        guard applyToBuffer(batch, cache: cache, buf: &buf, fullSurfaceDirty: isNewBuf || batch.keyframe) != nil else {
            if let existing {
                windows[batch.window] = existing
            }
            lock.unlock()
            return nil
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

    private func applyToBuffer(
        _ batch: SurfaceBatch,
        cache: TileAtlasCache,
        buf: inout WindowBuffer,
        fullSurfaceDirty: Bool
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        let w = buf.width
        let h = buf.height

        var resolvedRefs: [(x: Int, y: Int, rgba: Data, bgra: Data)] = []
        resolvedRefs.reserveCapacity(batch.refs.count)
        for ref in batch.refs {
            guard let pair = cache.getPair(hash: ref.hash) else { return nil }
            resolvedRefs.append((x: ref.x, y: ref.y, rgba: pair.rgba, bgra: pair.bgra))
        }

        var decodedTiles: [(x: Int, y: Int, w: Int, h: Int, rgba: Data, bgra: Data)] = []
        decodedTiles.reserveCapacity(batch.tiles.count)
        for tile in batch.tiles {
            guard let rgba = SurfaceAtlasCodec.decodeTile(tile) else { return nil }
            let tw = Int(tile.rect.width)
            let th = Int(tile.rect.height)
            let bgra: Data
            if let hash = tile.hash, tw == 64, th == 64 {
                cache.insert(hash: hash, rgba: rgba)
                bgra = cache.getPair(hash: hash)?.bgra ?? SurfaceAtlasCodec.rgbaToBgra(rgba)
            } else {
                bgra = SurfaceAtlasCodec.rgbaToBgra(rgba)
            }
            decodedTiles.append((x: Int(tile.rect.minX), y: Int(tile.rect.minY), w: tw, h: th, rgba: rgba, bgra: bgra))
        }

        var dirtyX0 = fullSurfaceDirty ? 0 : w
        var dirtyY0 = fullSurfaceDirty ? 0 : h
        var dirtyX1 = fullSurfaceDirty ? w : 0
        var dirtyY1 = fullSurfaceDirty ? h : 0

        @inline(__always)
        func markDirty(x0: Int, y0: Int, x1: Int, y1: Int) {
            guard x0 < x1, y0 < y1 else { return }
            if x0 < dirtyX0 { dirtyX0 = x0 }
            if y0 < dirtyY0 { dirtyY0 = y0 }
            if x1 > dirtyX1 { dirtyX1 = x1 }
            if y1 > dirtyY1 { dirtyY1 = y1 }
        }

        // 1. Copies
        if !batch.copies.isEmpty {
            if batch.copies.count == 1, let copy = batch.copies.first {
                let dstX0 = Int(copy.rect.minX)
                let dstY0 = Int(copy.rect.minY)
                let cw = Int(copy.rect.width)
                let ch = Int(copy.rect.height)
                let colStart = max(0, max(-dstX0, copy.dx - dstX0))
                let colEnd = min(cw, min(w - dstX0, w + copy.dx - dstX0))
                let rowStart = max(0, max(-dstY0, copy.dy - dstY0))
                let rowEnd = min(ch, min(h - dstY0, h + copy.dy - dstY0))
                if colStart < colEnd && rowStart < rowEnd {
                    let dx0 = dstX0 + colStart
                    let sx0 = dx0 - copy.dx
                    let copyByteCount = (colEnd - colStart) * 4
                    buf.bytes.withUnsafeMutableBytes { (rgbaRaw: UnsafeMutableRawBufferPointer) in
                        buf.bgraBytes.withUnsafeMutableBytes { (bgraRaw: UnsafeMutableRawBufferPointer) in
                            guard let rgbaBase = rgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                  let bgraBase = bgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                            if copy.dy > 0 {
                                for row in (rowStart ..< rowEnd).reversed() {
                                    let dy = dstY0 + row
                                    let sy = dy - copy.dy
                                    let sOff = (sy * w + sx0) * 4
                                    let dOff = (dy * w + dx0) * 4
                                    memmove(rgbaBase.advanced(by: dOff), rgbaBase.advanced(by: sOff), copyByteCount)
                                    memmove(bgraBase.advanced(by: dOff), bgraBase.advanced(by: sOff), copyByteCount)
                                }
                            } else {
                                for row in rowStart ..< rowEnd {
                                    let dy = dstY0 + row
                                    let sy = dy - copy.dy
                                    let sOff = (sy * w + sx0) * 4
                                    let dOff = (dy * w + dx0) * 4
                                    memmove(rgbaBase.advanced(by: dOff), rgbaBase.advanced(by: sOff), copyByteCount)
                                    memmove(bgraBase.advanced(by: dOff), bgraBase.advanced(by: sOff), copyByteCount)
                                }
                            }
                        }
                    }
                    markDirty(x0: dx0, y0: dstY0 + rowStart, x1: dstX0 + colEnd, y1: dstY0 + rowEnd)
                }
            } else {
                let prevRgba = buf.bytes
                let prevBgra = buf.bgraBytes
                prevRgba.withUnsafeBytes { (srcRgbaRaw: UnsafeRawBufferPointer) in
                    prevBgra.withUnsafeBytes { (srcBgraRaw: UnsafeRawBufferPointer) in
                        buf.bytes.withUnsafeMutableBytes { (dstRgbaRaw: UnsafeMutableRawBufferPointer) in
                            buf.bgraBytes.withUnsafeMutableBytes { (dstBgraRaw: UnsafeMutableRawBufferPointer) in
                                guard let srcRgba = srcRgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                      let srcBgra = srcBgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                      let dstRgba = dstRgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                      let dstBgra = dstBgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                                for copy in batch.copies {
                                    let dstX0 = Int(copy.rect.minX)
                                    let dstY0 = Int(copy.rect.minY)
                                    let cw = Int(copy.rect.width)
                                    let ch = Int(copy.rect.height)
                                    let colStart = max(0, max(-dstX0, copy.dx - dstX0))
                                    let colEnd = min(cw, min(w - dstX0, w + copy.dx - dstX0))
                                    let rowStart = max(0, max(-dstY0, copy.dy - dstY0))
                                    let rowEnd = min(ch, min(h - dstY0, h + copy.dy - dstY0))
                                    guard colStart < colEnd, rowStart < rowEnd else { continue }
                                    let dx0 = dstX0 + colStart
                                    let sx0 = dx0 - copy.dx
                                    let copyByteCount = (colEnd - colStart) * 4
                                    for row in rowStart ..< rowEnd {
                                        let dy = dstY0 + row
                                        let sy = dy - copy.dy
                                        let sOff = (sy * w + sx0) * 4
                                        let dOff = (dy * w + dx0) * 4
                                        dstRgba.advanced(by: dOff).update(from: srcRgba.advanced(by: sOff), count: copyByteCount)
                                        dstBgra.advanced(by: dOff).update(from: srcBgra.advanced(by: sOff), count: copyByteCount)
                                    }
                                    markDirty(x0: dx0, y0: dstY0 + rowStart, x1: dstX0 + colEnd, y1: dstY0 + rowEnd)
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. Fills
        if !batch.fills.isEmpty {
            buf.bytes.withUnsafeMutableBytes { (rgbaRaw: UnsafeMutableRawBufferPointer) in
                buf.bgraBytes.withUnsafeMutableBytes { (bgraRaw: UnsafeMutableRawBufferPointer) in
                    guard let rgbaBase = rgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let bgraBase = bgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
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
                        var rgbaPattern = UInt32(littleEndian: UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24))
                        var bgraPattern = UInt32(littleEndian: UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16) | (UInt32(a) << 24))
                        let rowByteCount = (x1 - x0) * 4
                        for y in y0 ..< y1 {
                            let rowOff = (y * w + x0) * 4
                            memset_pattern4(rgbaBase.advanced(by: rowOff), &rgbaPattern, rowByteCount)
                            memset_pattern4(bgraBase.advanced(by: rowOff), &bgraPattern, rowByteCount)
                        }
                        markDirty(x0: x0, y0: y0, x1: x1, y1: y1)
                    }
                }
            }
        }

        // 3. Refs (64x64 cached tiles)
        if !resolvedRefs.isEmpty {
            for ref in resolvedRefs {
                blitTilePair(
                    rgbaTile: ref.rgba,
                    bgraTile: ref.bgra,
                    tileX: ref.x,
                    tileY: ref.y,
                    tileW: 64,
                    tileH: 64,
                    intoRgba: &buf.bytes,
                    intoBgra: &buf.bgraBytes,
                    surfaceW: w,
                    surfaceH: h
                )
                markDirty(x0: max(0, ref.x), y0: max(0, ref.y), x1: min(w, ref.x + 64), y1: min(h, ref.y + 64))
            }
        }

        // 4. New tiles
        if !decodedTiles.isEmpty {
            for tile in decodedTiles {
                blitTilePair(
                    rgbaTile: tile.rgba,
                    bgraTile: tile.bgra,
                    tileX: tile.x,
                    tileY: tile.y,
                    tileW: tile.w,
                    tileH: tile.h,
                    intoRgba: &buf.bytes,
                    intoBgra: &buf.bgraBytes,
                    surfaceW: w,
                    surfaceH: h
                )
                markDirty(x0: max(0, tile.x), y0: max(0, tile.y), x1: min(w, tile.x + tile.w), y1: min(h, tile.y + tile.h))
            }
        }

        if dirtyX0 < dirtyX1 && dirtyY0 < dirtyY1 {
            return (x: dirtyX0, y: dirtyY0, width: dirtyX1 - dirtyX0, height: dirtyY1 - dirtyY0)
        }
        return (x: 0, y: 0, width: 0, height: 0)
    }

    private func blitTilePair(
        rgbaTile: Data,
        bgraTile: Data,
        tileX: Int,
        tileY: Int,
        tileW: Int,
        tileH: Int,
        intoRgba surfaceRgba: inout Data,
        intoBgra surfaceBgra: inout Data,
        surfaceW: Int,
        surfaceH: Int
    ) {
        let x0 = max(0, tileX)
        let y0 = max(0, tileY)
        let x1 = min(surfaceW, tileX + tileW)
        let y1 = min(surfaceH, tileY + tileH)
        guard x0 < x1, y0 < y1 else { return }
        let count = (x1 - x0) * 4
        rgbaTile.withUnsafeBytes { (srcRgbaRaw: UnsafeRawBufferPointer) in
            bgraTile.withUnsafeBytes { (srcBgraRaw: UnsafeRawBufferPointer) in
                surfaceRgba.withUnsafeMutableBytes { (dstRgbaRaw: UnsafeMutableRawBufferPointer) in
                    surfaceBgra.withUnsafeMutableBytes { (dstBgraRaw: UnsafeMutableRawBufferPointer) in
                        guard let srcRgba = srcRgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let srcBgra = srcBgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let dstRgba = dstRgbaRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let dstBgra = dstBgraRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        for y in y0 ..< y1 {
                            let ty = y - tileY
                            let tx = x0 - tileX
                            let sOff = (ty * tileW + tx) * 4
                            let dOff = (y * surfaceW + x0) * 4
                            dstRgba.advanced(by: dOff).update(from: srcRgba.advanced(by: sOff), count: count)
                            dstBgra.advanced(by: dOff).update(from: srcBgra.advanced(by: sOff), count: count)
                        }
                    }
                }
            }
        }
    }
}
