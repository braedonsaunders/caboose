import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

/// Shared Metal objects for every window surface.
public final class SurfaceRenderer: @unchecked Sendable {
    public static let shared = SurfaceRenderer()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Caboose requires Metal.")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.device = device
        self.queue = queue
        self.textureCache = cache!
    }
}

/// The pixels of one remote window: a BGRA texture that draws are applied to in place.
///
/// Draws arrive on the window's decode queue; presentation reads `texture` on the main
/// thread. The lock guards replacement of the texture on resize, never the GPU work.
///
/// Every write — CPU pixels, decoded video, scrolls, resizes — is a GPU command on the one
/// shared queue, which runs command buffers in the order they are committed. A write
/// therefore never races the presenter's read or the next write, and no draw waits for
/// the GPU to finish before the decode queue takes the next one.
public final class WindowSurface: @unchecked Sendable {
    private let renderer = SurfaceRenderer.shared
    private let lock = NSLock()
    private var backing: MTLTexture?
    public private(set) var pixelSize: CGSize = .zero
    /// Incremented by every applied draw; presenters redraw when it changes.
    public private(set) var generation: UInt64 = 0

    public init() {}

    public var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return backing
    }

    /// Resizes the backing store, preserving the overlapping top-left content.
    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let backing, backing.width == width, backing.height == height { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        guard let next = renderer.device.makeTexture(descriptor: descriptor) else { return }
        if let old = backing, let commands = renderer.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            let copyWidth = min(old.width, width), copyHeight = min(old.height, height)
            blit.copy(from: old, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                      to: next, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
            commands.commit()
        }
        backing = next
        pixelSize = CGSize(width: width, height: height)
        generation &+= 1
    }

    /// Uploads tightly or loosely packed BGRA pixels into a region, staged through a buffer
    /// so the copy is queued behind the GPU writes before it.
    public func upload(bgra bytes: UnsafeRawPointer, rowBytes: Int, x: Int, y: Int, width: Int, height: Int) {
        guard let texture, let region = clamp(x: x, y: y, width: width, height: height, in: texture) else { return }
        let offset = (region.origin.y - y) * rowBytes + (region.origin.x - x) * 4
        let length = (region.size.height - 1) * rowBytes + region.size.width * 4
        guard let staging = renderer.device.makeBuffer(bytes: bytes.advanced(by: offset), length: length, options: .storageModeShared),
              let commands = renderer.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                  sourceBytesPerImage: rowBytes * region.size.height, sourceSize: region.size,
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.endEncoding()
        commands.commit()
        bump()
    }

    /// Draws a decoded image (png/jpeg/webp) into a region.
    public func upload(image: CGImage, x: Int, y: Int) {
        upload(image: image, into: CGRect(x: x, y: y, width: image.width, height: image.height))
    }

    /// The image's own RGB space, so its pixel values land unchanged (lossless tiles stay
    /// lossless, and match decoded video, which is not colour-managed either).
    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Draws an image scaled to fill `rect` (a whole number of pixels), e.g. a lossless tile
    /// of a window whose picture is shown at another size.
    public func upload(image: CGImage, into rect: CGRect) {
        let rect = rect.integral
        let x = Int(rect.minX), y = Int(rect.minY), width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: Self.rgbSpace(of: image),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = width == image.width && height == image.height ? .none : .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return }
        pixels.withUnsafeBytes { upload(bgra: $0.baseAddress!, rowBytes: rowBytes, x: x, y: y, width: width, height: height) }
    }

    /// Draws the `crop` of a decoded picture — its visible part, without the encoder's padding
    /// (NVENC codes 2160 lines as 2176) — into `rect` of the window: copied 1:1 when the sizes
    /// match, scaled on the GPU when they do not.
    public func upload(pixelBuffer: CVPixelBuffer, crop: CGRect, into rect: CGRect) {
        guard let texture else { return }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer), sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        let rect = rect.integral
        guard !crop.isEmpty, !rect.isEmpty else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, renderer.textureCache, pixelBuffer, nil, .bgra8Unorm, sourceWidth, sourceHeight, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture) else { return }
        guard crop.size == rect.size else {
            scale(source, from: crop, into: rect, keeping: cvTexture)
            return
        }
        guard let region = clamp(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height), in: texture),
              let commands = renderer.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return }
        let origin = MTLOrigin(x: Int(crop.minX) + region.origin.x - Int(rect.minX), y: Int(crop.minY) + region.origin.y - Int(rect.minY), z: 0)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: region.size,
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.endEncoding()
        commands.addCompletedHandler { _ in _ = cvTexture } // keep the CVMetalTexture alive until the copy lands
        commands.commit()
        bump()
    }

    private func scale(_ source: MTLTexture, from crop: CGRect, into rect: CGRect, keeping cvTexture: CVMetalTexture) {
        guard let texture, let commands = renderer.queue.makeCommandBuffer(),
              let region = clamp(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height), in: texture)
        else { return }
        let scaler = MPSImageBilinearScale(device: renderer.device)
        // Map `crop` of the decoded buffer (which may be padded) onto `rect`, and write only inside it.
        let scaleX = Double(rect.width) / Double(crop.width), scaleY = Double(rect.height) / Double(crop.height)
        var transform = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY,
                                          translateX: Double(rect.minX) - Double(crop.minX) * scaleX,
                                          translateY: Double(rect.minY) - Double(crop.minY) * scaleY)
        scaler.clipRect = MTLRegion(origin: region.origin, size: region.size)
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: commands, sourceTexture: source, destinationTexture: texture)
        }
        commands.addCompletedHandler { _ in _ = cvTexture }
        commands.commit()
        bump()
    }

    /// The current pixels as an image, for showing a window instantly before its stream resumes.
    ///
    /// Waits for the GPU and reads the whole window back on the calling thread; for one
    /// window on demand. Pictures of every window at once go through
    /// `snapshot(longEdgeAtMost:completion:)`, which neither blocks nor reads at full size.
    public func snapshot() -> CGImage? {
        guard let texture else { return nil }
        // Reading on the CPU needs every queued write to have landed.
        if let fence = renderer.queue.makeCommandBuffer() {
            fence.commit()
            fence.waitUntilCompleted()
        }
        return Self.image(of: texture)
    }

    /// A reduced copy of the current pixels, its long edge at most `longEdge` pixels, delivered
    /// off the calling thread once every write queued before it has landed. The reduction is
    /// a GPU scale into a small texture, so the CPU never touches the full window: the last
    /// pictures of a 4K desktop's windows, kept while the app is in the background, would
    /// otherwise cost hundreds of megabytes and a stalled main thread at the moment the
    /// system gives the app the least of both. Never scales up; nil for an empty window.
    public func snapshot(longEdgeAtMost longEdge: Int, completion: @escaping @Sendable (CGImage?) -> Void) {
        guard longEdge > 0, let texture, let commands = renderer.queue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        let scale = min(1, Double(longEdge) / Double(max(texture.width, texture.height)))
        let width = max(1, Int((Double(texture.width) * scale).rounded()))
        let height = max(1, Int((Double(texture.height) * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let reduced = renderer.device.makeTexture(descriptor: descriptor) else {
            completion(nil)
            return
        }
        if width == texture.width, height == texture.height {
            guard let blit = commands.makeBlitCommandEncoder() else {
                completion(nil)
                return
            }
            blit.copy(from: texture, to: reduced)
            blit.endEncoding()
        } else {
            // Without a transform the scaler maps the whole source onto the whole destination.
            MPSImageBilinearScale(device: renderer.device).encode(commandBuffer: commands, sourceTexture: texture, destinationTexture: reduced)
        }
        commands.addCompletedHandler { _ in
            // Metal's completion thread is for bookkeeping; the readback goes elsewhere.
            DispatchQueue.global(qos: .userInitiated).async { completion(Self.image(of: reduced)) }
        }
        commands.commit()
    }

    /// `snapshot(longEdgeAtMost:completion:)` awaited.
    public func snapshot(longEdgeAtMost longEdge: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            snapshot(longEdgeAtMost: longEdge) { continuation.resume(returning: $0) }
        }
    }

    /// Reduced pictures of several windows at once, keyed as `surfaces` is, all delivered
    /// together when the last has landed. Windows with nothing to show are left out.
    public static func snapshots(of surfaces: [Int: WindowSurface], longEdgeAtMost longEdge: Int,
                                 completion: @escaping @Sendable ([Int: CGImage]) -> Void) {
        let gathering = Gathering(expected: surfaces.count, completion: completion)
        for (key, surface) in surfaces {
            surface.snapshot(longEdgeAtMost: longEdge) { image in gathering.add(image, for: key) }
        }
    }

    /// Collects pictures arriving on background threads and reports once, when all are in.
    private final class Gathering: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var images: [Int: CGImage] = [:]
        private let completion: @Sendable ([Int: CGImage]) -> Void

        init(expected: Int, completion: @escaping @Sendable ([Int: CGImage]) -> Void) {
            remaining = expected
            self.completion = completion
            if expected == 0 { completion([:]) }
        }

        func add(_ image: CGImage?, for key: Int) {
            lock.lock()
            if let image { images[key] = image }
            remaining -= 1
            let done = remaining == 0 ? images : nil
            lock.unlock()
            if let done { completion(done) }
        }
    }

    /// Reads a shared-storage texture whose writes have all landed into an opaque BGRA image.
    private static func image(of texture: MTLTexture) -> CGImage? {
        let rowBytes = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * texture.height)
        texture.getBytes(&pixels, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func bump() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func clamp(x: Int, y: Int, width: Int, height: Int, in texture: MTLTexture) -> MTLRegion? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(texture.width, x + width), y1 = min(texture.height, y + height)
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0)
    }
}
