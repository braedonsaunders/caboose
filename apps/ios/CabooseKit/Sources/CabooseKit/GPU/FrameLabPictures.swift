import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// Pictures of live GPU windows for frame lab (guest/framelab), enabled with
/// `CABOOSE_FRAMELAB=1`.
///
/// At most once a second per window, a presented picture is copied off the GPU. When two
/// copies in a row are the same, the window has settled, and that picture is written once to
/// `Documents/framelab/<window>-<serial>.png` (until it changes again), with a
/// `caboose-framelab: picture window=W serial=S file=F now_ns=N` line on standard output,
/// N being the phone's uptime clock. Frame lab's driver copies the directory out and
/// compares each app's settled picture with the same scene drawn on the computer's CPU.
/// Animations never settle, so they are never written.
final class FrameLabPictures: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["CABOOSE_FRAMELAB"] == "1"
    static let shared = FrameLabPictures()

    private struct Seen {
        var time: CFTimeInterval
        var hash: Int
        var written: Bool
    }

    private let lock = NSLock()
    private var seen: [UInt64: Seen] = [:]
    private var queues: [ObjectIdentifier: MTLCommandQueue] = [:]
    private let writer = DispatchQueue(label: "org.caboose.framelab", qos: .utility)
    private lazy var directory: URL? = {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = documents.appendingPathComponent("framelab", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Frame worker, while `texture` is lent: copies it when this window is due, waiting
    /// for the copy so the picture can be released as soon as this returns.
    func consider(window: UInt64, serial: UInt64, texture: MTLTexture) {
        let now = CACurrentMediaTime()
        let due = lock.withLock { () -> Bool in
            if let last = seen[window], now - last.time < 1 { return false }
            seen[window, default: Seen(time: now, hash: 0, written: false)].time = now
            return true
        }
        guard due, let bgra = Self.isBGRA(texture.pixelFormat) else { return }
        let rowBytes = texture.width * 4
        let device = texture.device
        guard let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared),
              let commands = queue(for: device).makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return }
        let (width, height) = (texture.width, texture.height)
        let data = Data(bytes: buffer.contents(), count: buffer.length)
        writer.async { [self] in
            var hasher = Hasher()
            hasher.combine(width)
            hasher.combine(data)
            let hash = hasher.finalize()
            let write = lock.withLock { () -> Bool in
                guard var entry = seen[window] else { return false }
                defer { seen[window] = entry }
                if entry.hash != hash {
                    entry.hash = hash
                    entry.written = false
                    return false
                }
                if entry.written { return false }
                entry.written = true
                return true
            }
            guard write, let directory else { return }
            let name = "\(window)-\(serial).png"
            guard Self.writePNG(data, width: width, height: height, rowBytes: rowBytes, bgra: bgra,
                                to: directory.appendingPathComponent(name)) else { return }
            print("caboose-framelab: picture window=\(window) serial=\(serial) file=\(name) now_ns=\(DispatchTime.now().uptimeNanoseconds)")
            fflush(stdout)
        }
    }

    /// Whether 8-bit pixels are stored blue first (true) or red first (false); nil for any
    /// other format, which is not written.
    private static func isBGRA(_ format: MTLPixelFormat) -> Bool? {
        switch format {
        case .bgra8Unorm, .bgra8Unorm_srgb: return true
        case .rgba8Unorm, .rgba8Unorm_srgb: return false
        default: return nil
        }
    }

    private func queue(for device: MTLDevice) -> MTLCommandQueue {
        lock.withLock {
            let key = ObjectIdentifier(device)
            if let queue = queues[key] { return queue }
            let queue = device.makeCommandQueue()!
            queues[key] = queue
            return queue
        }
    }

    private static func writePNG(_ data: Data, width: Int, height: Int, rowBytes: Int, bgra: Bool, to url: URL) -> Bool {
        // Opaque pictures: the window's alpha is not part of what is shown.
        let info = bgra
            ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
