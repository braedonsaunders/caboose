import CoreGraphics
import CoreVideo
import Foundation
import Metal

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
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let next = renderer.device.makeTexture(descriptor: descriptor) else { return }
        if let old = backing, let commands = renderer.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            let copyWidth = min(old.width, width), copyHeight = min(old.height, height)
            blit.copy(from: old, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                      to: next, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        backing = next
        pixelSize = CGSize(width: width, height: height)
        generation &+= 1
    }

    /// Uploads tightly or loosely packed BGRA pixels into a region.
    public func upload(bgra bytes: UnsafeRawPointer, rowBytes: Int, x: Int, y: Int, width: Int, height: Int) {
        guard let texture, let region = clamp(x: x, y: y, width: width, height: height, in: texture) else { return }
        let offset = (region.origin.y - y) * rowBytes + (region.origin.x - x) * 4
        texture.replace(region: region, mipmapLevel: 0, withBytes: bytes.advanced(by: offset), bytesPerRow: rowBytes)
        bump()
    }

    /// Draws a decoded image (png/jpeg/webp) into a region.
    public func upload(image: CGImage, x: Int, y: Int) {
        let width = image.width, height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return }
        pixels.withUnsafeBytes { upload(bgra: $0.baseAddress!, rowBytes: rowBytes, x: x, y: y, width: width, height: height) }
    }

    /// Copies a decoded video picture into a region on the GPU, without touching its pixels on the CPU.
    public func upload(pixelBuffer: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) {
        guard let texture else { return }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer), sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, renderer.textureCache, pixelBuffer, nil, .bgra8Unorm, sourceWidth, sourceHeight, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture),
              let region = clamp(x: x, y: y, width: min(width, sourceWidth), height: min(height, sourceHeight), in: texture),
              let commands = renderer.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: region.origin.x - x, y: region.origin.y - y, z: 0), sourceSize: region.size,
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.endEncoding()
        commands.addCompletedHandler { _ in _ = cvTexture } // keep the CVMetalTexture alive until the copy lands
        commands.commit()
        // CPU uploads write the same texture; finish the GPU copy before the next draw lands.
        commands.waitUntilCompleted()
        bump()
    }

    /// Applies Xpra "scroll" draws: each rectangle moves by (dx, dy) within the window.
    public func scroll(_ moves: [(x: Int, y: Int, width: Int, height: Int, dx: Int, dy: Int)]) {
        guard let texture, !moves.isEmpty, let commands = renderer.queue.makeCommandBuffer() else { return }
        for move in moves {
            guard let source = clamp(x: move.x, y: move.y, width: move.width, height: move.height, in: texture),
                  let destination = clamp(x: source.origin.x + move.dx, y: source.origin.y + move.dy,
                                          width: source.size.width, height: source.size.height, in: texture)
            else { continue }
            let sourceOrigin = MTLOrigin(x: destination.origin.x - move.dx, y: destination.origin.y - move.dy, z: 0)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: destination.size.width, height: destination.size.height, mipmapped: false)
            descriptor.storageMode = .private
            guard let scratch = renderer.device.makeTexture(descriptor: descriptor),
                  let blit = commands.makeBlitCommandEncoder() else { continue }
            // Source and destination overlap, so stage through a scratch texture.
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: sourceOrigin,
                      sourceSize: destination.size, to: scratch, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin())
            blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: destination.size, to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: destination.origin)
            blit.endEncoding()
        }
        commands.commit()
        // CPU uploads write the same texture; finish the GPU copy before the next draw lands.
        commands.waitUntilCompleted()
        bump()
    }

    /// The current pixels as an image, for showing a window instantly before its stream resumes.
    public func snapshot() -> CGImage? {
        guard let texture else { return nil }
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
