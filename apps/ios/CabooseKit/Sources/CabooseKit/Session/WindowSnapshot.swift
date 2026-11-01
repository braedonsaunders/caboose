import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore

/// The Metal device and queue the phone's own drawing uses: snapshots, thumbnails and covers.
///
/// The main thread draws on `queue`, so nothing here may wait for a GPU that has stopped:
/// after a GPU fault (a live GPU process's command buffer touching a released resource) the
/// system can stop completing this process's command buffers. Metal then blocks
/// `makeCommandBuffer()` once 64 are outstanding and a layer's `nextDrawable()` a second at a
/// time, which would freeze the app. Command buffers come from `makeCommandBuffer()`, which
/// refuses rather than waits once the GPU has stopped, and waits for one go through
/// `commitAndWait(_:timeout:)`.
public final class SharedMetal: @unchecked Sendable {
    public static let shared = SharedMetal()

    public let device: MTLDevice
    public let queue: MTLCommandQueue

    /// Command buffers made and not yet completed (or dropped uncommitted), oldest first.
    private struct Flight { weak var commands: MTLCommandBuffer?; let made: CFTimeInterval }
    private let flightLock = NSLock()
    private var flights: [Flight] = []
    private var refusing = false
    private var errorsLogged = 0
    static let maximumInFlight = 32
    static let stalledAfter: CFTimeInterval = 2

    /// Whether the GPU has stopped completing this queue's work: the oldest command buffer
    /// committed and not yet completed was made 2 s ago, or 32 are outstanding.
    public var isStalled: Bool {
        flightLock.lock(); defer { flightLock.unlock() }
        return stalledLocked(now: CACurrentMediaTime())
    }

    private func stalledLocked(now: CFTimeInterval) -> Bool {
        flights.removeAll { flight in
            guard let commands = flight.commands else { return true }
            return commands.status == .completed || commands.status == .error
        }
        // One made but not yet committed waits for its caller, not for the GPU.
        let running = flights.filter { $0.commands.map { $0.status == .committed || $0.status == .scheduled } == true }
        return running.count >= Self.maximumInFlight || running.first.map { now - $0.made >= Self.stalledAfter } == true
    }

    /// A command buffer on `queue`, or nil without waiting while the GPU is stalled.
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        let now = CACurrentMediaTime()
        flightLock.lock()
        if stalledLocked(now: now) {
            let first = !refusing
            refusing = true
            let count = flights.count, age = flights.first.map { now - $0.made } ?? 0
            flightLock.unlock()
            if first { print("CABOOSE_METAL_STALLED queue=phone outstanding=\(count) oldest_ms=\(Int(age * 1000))") }
            return nil
        }
        let recovered = refusing
        refusing = false
        flightLock.unlock()
        if recovered { print("CABOOSE_METAL_RECOVERED queue=phone") }
        guard let commands = queue.makeCommandBuffer() else { return nil }
        commands.addCompletedHandler { [weak self] commands in
            guard commands.status == .error, let self else { return }
            self.flightLock.lock()
            let report = self.errorsLogged < 16
            self.errorsLogged += 1
            self.flightLock.unlock()
            if report {
                let error = commands.error as NSError?
                print("CABOOSE_METAL_ERROR queue=phone code=\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
            }
        }
        flightLock.lock()
        flights.append(Flight(commands: commands, made: now))
        flightLock.unlock()
        return commands
    }

    /// Commits `commands` and waits up to `timeout` for the GPU to finish them: false when it
    /// did not, or they failed.
    public func commitAndWait(_ commands: MTLCommandBuffer, timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        commands.addCompletedHandler { _ in done.signal() }
        commands.commit()
        return done.wait(timeout: .now() + timeout) == .success && commands.status == .completed
    }

    /// `shared` is the app's; tests make their own, so stalling one disturbs no other.
    init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Caboose requires Metal.")
        }
        self.device = device
        self.queue = queue
    }
}

/// The last picture of one window that the phone holds: a copy of a frame the window's GPU
/// layer presented, or the snapshot of the game the window runs (docs/game-handoff.md).
///
/// A window's picture is its GPU layer (docs/gpu-live.md). Only the one view that hosts the
/// layer shows it; thumbnails, Home and the frames kept through the background show this
/// copy, and the covers over an application's own window controls read their colour from it.
/// A copy is taken at a present, never between them: the window's first present, then one
/// present a second while something shows the copy (`want()`), and otherwise one every five
/// seconds. A window that stops presenting keeps the last copy taken, which can be up to
/// that interval older than its last frame.
///
/// Each copy is a new BGRA texture replacing the previous one under a lock, so a reader
/// never sees a copy half written.
public final class WindowSnapshot: @unchecked Sendable {
    private let metal = SharedMetal.shared
    private let lock = NSLock()
    private var backing: MTLTexture?
    private var counter: UInt64 = 0
    private var storedAt: CFTimeInterval?
    private var wantedAt: CFTimeInterval = -.infinity
    /// Told of every present of the window's GPU layer, on the presenting thread.
    let onPresent: (@Sendable () -> Void)?

    /// How long after a `want()` copies are kept a second apart.
    static let wantedFor: CFTimeInterval = 2
    static let wantedInterval: CFTimeInterval = 1
    static let idleInterval: CFTimeInterval = 5

    public init() { onPresent = nil }
    init(onPresent: @escaping @Sendable () -> Void) { self.onPresent = onPresent }

    public var texture: MTLTexture? { lock.withLock { backing } }

    /// The picture's size in its own pixels; zero before the first.
    public var pixelSize: CGSize {
        lock.withLock { backing.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    }

    /// Incremented by every new picture; a view redraws when it changes.
    public var generation: UInt64 { lock.withLock { counter } }

    /// The texture and its generation, read together.
    public func presentation() -> (texture: MTLTexture, generation: UInt64)? {
        lock.withLock { backing.map { ($0, counter) } }
    }

    /// Something shows this picture: copies are taken a second apart for a while.
    public func want(at now: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock { wantedAt = now }
    }

    /// Before a present of the window's GPU layer: whether to copy the frame it presents.
    func capturesPresent(at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        lock.withLock {
            guard let storedAt else { return true }
            let interval = now - wantedAt <= Self.wantedFor ? Self.wantedInterval : Self.idleInterval
            return now - storedAt >= interval
        }
    }

    /// Copies a presented frame, lent by the presenter: waits for the copy (at most a second),
    /// so the frame can be given back as soon as this returns. 8-bit sRGB frames keep their encoded values;
    /// other formats are converted. False when the frame was not copied.
    @discardableResult
    func store(copyOf source: MTLTexture, at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard source.device === metal.device, source.width > 0, source.height > 0,
              let target = makeTexture(width: source.width, height: source.height),
              let commands = metal.makeCommandBuffer() else { return false }
        let srgb = source.pixelFormat == .bgra8Unorm_srgb || source.pixelFormat == .rgba8Unorm_srgb
        guard let destination = srgb ? target.makeTextureView(pixelFormat: .bgra8Unorm_srgb) : target else { return false }
        if source.pixelFormat == destination.pixelFormat {
            guard let blit = commands.makeBlitCommandEncoder() else { return false }
            blit.copy(from: source, to: destination)
            blit.endEncoding()
        } else {
            guard MPSSupportsMTLDevice(metal.device) else { return false }
            // The same size: the scaler samples pixel centres, so it converts without resampling.
            MPSImageBilinearScale(device: metal.device).encode(commandBuffer: commands, sourceTexture: source,
                                                               destinationTexture: destination)
        }
        // A GPU that has not copied it within a second has stopped: the frame is given back.
        guard metal.commitAndWait(commands, timeout: 1) else { return false }
        replace(with: target, at: now)
        return true
    }

    /// A picture drawn on the phone (a game's snapshot, a frame kept from before a
    /// reconnect) becomes the window's.
    public func store(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let target = makeTexture(width: width, height: height) else { return }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return }
        target.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: rowBytes)
        replace(with: target, at: CACurrentMediaTime())
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .shared
        return metal.device.makeTexture(descriptor: descriptor)
    }

    private func replace(with texture: MTLTexture, at now: CFTimeInterval) {
        lock.withLock {
            backing = texture
            storedAt = now
            counter &+= 1
        }
    }

    // MARK: Reading

    /// The picture as an image, read back at full size on the calling thread.
    public func snapshot() -> CGImage? {
        texture.flatMap(Self.image(of:))
    }

    /// A reduced copy, its long edge at most `longEdge` pixels, delivered off the calling
    /// thread. The reduction is a GPU scale, so the CPU never reads the whole picture. Never
    /// scales up; nil for a window with no picture.
    public func snapshot(longEdgeAtMost longEdge: Int, completion: @escaping @Sendable (CGImage?) -> Void) {
        guard longEdge > 0, let texture, let commands = metal.makeCommandBuffer() else {
            completion(nil)
            return
        }
        let scale = min(1, Double(longEdge) / Double(max(texture.width, texture.height)))
        let width = max(1, Int((Double(texture.width) * scale).rounded()))
        let height = max(1, Int((Double(texture.height) * scale).rounded()))
        guard width != texture.width || height != texture.height else {
            // A picture is never written after it is stored: it is read as it is.
            DispatchQueue.global(qos: .userInitiated).async { completion(Self.image(of: texture)) }
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard MPSSupportsMTLDevice(metal.device), let reduced = metal.device.makeTexture(descriptor: descriptor) else {
            completion(nil)
            return
        }
        // Without a transform the scaler maps the whole source onto the whole destination.
        MPSImageBilinearScale(device: metal.device).encode(commandBuffer: commands, sourceTexture: texture, destinationTexture: reduced)
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

    /// Reduced pictures of several windows, keyed as `snapshots` is, delivered together once
    /// the last has landed. Windows with no picture are left out.
    public static func snapshots(of snapshots: [Int: WindowSnapshot], longEdgeAtMost longEdge: Int,
                                 completion: @escaping @Sendable ([Int: CGImage]) -> Void) {
        let gathering = Gathering(expected: snapshots.count, completion: completion)
        for (key, snapshot) in snapshots {
            snapshot.snapshot(longEdgeAtMost: longEdge) { image in gathering.add(image, for: key) }
        }
    }

    /// A small part of the picture (`PictureTargets` reads around a touch): the BGRA rows of
    /// the region `x, y, width, height`, clamped to the picture, with where it starts.
    public func pixels(x: Int, y: Int, width: Int, height: Int) -> (bytes: [UInt8], x: Int, y: Int, width: Int, height: Int)? {
        guard let texture else { return nil }
        let x0 = max(0, x), y0 = max(0, y), x1 = min(texture.width, x + width), y1 = min(texture.height, y + height)
        guard x1 > x0, y1 > y0 else { return nil }
        let rowBytes = (x1 - x0) * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * (y1 - y0))
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0), mipmapLevel: 0)
        return (bytes, x0, y0, x1 - x0, y1 - y0)
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
}
