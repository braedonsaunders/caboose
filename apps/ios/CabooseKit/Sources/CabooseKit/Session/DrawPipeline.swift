import CoreGraphics
import Foundation
import ImageIO

/// Decodes and applies one window's draws, in order, off the main thread.
///
/// Every draw is acknowledged with `window-draw-ack` carrying the decode time in
/// microseconds (or -1 on failure). The server's flow control runs on those acks:
/// it will not send more than a few frames ahead of them, so acking promptly is
/// what keeps the stream smooth.
/// Counts of applied draws by encoding, for diagnostics and tests.
public final class DrawStatistics: @unchecked Sendable {
    public static let shared = DrawStatistics()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failures: [String: Int] = [:]

    func record(_ coding: String, failed: Bool) {
        lock.lock()
        if failed { failures[coding, default: 0] += 1 } else { counts[coding, default: 0] += 1 }
        lock.unlock()
    }

    public var snapshot: (applied: [String: Int], failed: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (counts, failures)
    }
}

final class DrawPipeline: @unchecked Sendable {
    let windowID: Int
    let surface = WindowSurface()
    private let queue: DispatchQueue
    private let decoder = H264Decoder()
    private let send: @Sendable (XpraPacket) -> Void

    init(windowID: Int, width: Int, height: Int, send: @escaping @Sendable (XpraPacket) -> Void) {
        self.windowID = windowID
        self.send = send
        queue = DispatchQueue(label: "caboose.window.\(windowID)", qos: .userInteractive)
        surface.resize(width: width, height: height)
    }

    func resize(width: Int, height: Int) {
        queue.async { [surface] in surface.resize(width: width, height: height) }
    }

    func close() {
        queue.async { [decoder] in decoder.invalidate() }
    }

    /// `window-draw`: wid, x, y, width, height, coding, data, sequence, rowstride, options.
    func draw(_ packet: XpraPacket) {
        queue.async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let width = packet[3]?.int ?? 0, height = packet[4]?.int ?? 0
            let sequence = packet[7]?.int ?? 0
            var failure = ""
            do {
                try apply(packet)
            } catch {
                failure = String(describing: error)
            }
            DrawStatistics.shared.record(packet[5]?.string ?? "?", failed: !failure.isEmpty)
            let micros = failure.isEmpty ? Int64((DispatchTime.now().uptimeNanoseconds - start) / 1000) : -1
            // window-draw-ack: sequence, wid, width, height, decode time (µs, -1 on failure), message.
            send(XpraPacket("window-draw-ack", [
                .int(Int64(sequence)), .int(Int64(windowID)), .int(Int64(width)), .int(Int64(height)),
                .int(micros), RValue(failure),
            ]))
        }
    }

    private func apply(_ packet: XpraPacket) throws {
        let x = packet[1]?.int ?? 0, y = packet[2]?.int ?? 0
        let width = packet[3]?.int ?? 0, height = packet[4]?.int ?? 0
        let coding = packet[5]?.string ?? ""
        let data = packet[6]?.data ?? Data()
        let rowstride = packet[8]?.int ?? 0
        let options = packet[9] ?? .dict([])
        switch coding {
        case "void":
            return
        case "h264":
            if let picture = try decoder.decode(data) {
                surface.upload(pixelBuffer: picture, x: x, y: y, width: width, height: height)
            }
        case "jpeg", "webp", "png", "png/P", "png/L":
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DrawError.undecodable(coding) }
            surface.upload(image: image, x: x, y: y)
        case "rgb32", "rgb24":
            if options["lz4"]?.int ?? 0 > 0 || options["zlib"]?.int ?? 0 > 0 { throw DrawError.compressed }
            let format = options["rgb_format"]?.string ?? (coding == "rgb32" ? "BGRX" : "BGR")
            let pixels = try RGBConversion.bgra(from: data, format: format, width: width, height: height, rowstride: rowstride)
            pixels.withUnsafeBytes {
                surface.upload(bgra: $0.baseAddress!, rowBytes: width * 4, x: x, y: y, width: width, height: height)
            }
        case "scroll":
            let moves = (options["scroll"]?.list ?? []).compactMap { item -> (Int, Int, Int, Int, Int, Int)? in
                guard let v = item.list, v.count >= 6 else { return nil }
                return (v[0].int ?? 0, v[1].int ?? 0, v[2].int ?? 0, v[3].int ?? 0, v[4].int ?? 0, v[5].int ?? 0)
            }
            surface.scroll(moves.map { (x: $0.0, y: $0.1, width: $0.2, height: $0.3, dx: $0.4, dy: $0.5) })
        default:
            throw DrawError.unsupported(coding)
        }
    }
}

enum DrawError: Error, CustomStringConvertible {
    case unsupported(String)
    case undecodable(String)
    case compressed
    case badPixels

    var description: String {
        switch self {
        case .unsupported(let coding): "unsupported encoding \(coding)"
        case .undecodable(let coding): "could not decode \(coding)"
        case .compressed: "compressed rgb was not requested"
        case .badPixels: "pixel data shorter than its geometry"
        }
    }
}

/// Repacks Xpra's raw pixel formats into tightly packed BGRA.
enum RGBConversion {
    static func bgra(from data: Data, format: String, width: Int, height: Int, rowstride: Int) throws -> [UInt8] {
        let bytesPerPixel = format.count == 3 ? 3 : 4
        let stride = rowstride > 0 ? rowstride : width * bytesPerPixel
        guard width > 0, height > 0, data.count >= stride * (height - 1) + width * bytesPerPixel else {
            throw DrawError.badPixels
        }
        let order = Array(format.uppercased())
        guard let r = order.firstIndex(of: "R"), let g = order.firstIndex(of: "G"), let b = order.firstIndex(of: "B") else {
            throw DrawError.unsupported(format)
        }
        let a = order.firstIndex(of: "A")
        var out = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let src = source.bindMemory(to: UInt8.self)
            for row in 0 ..< height {
                var s = row * stride
                var d = row * width * 4
                for _ in 0 ..< width {
                    out[d] = src[s + b]
                    out[d + 1] = src[s + g]
                    out[d + 2] = src[s + r]
                    out[d + 3] = a.map { src[s + $0] } ?? 255
                    s += bytesPerPixel
                    d += 4
                }
            }
        }
        return out
    }
}
