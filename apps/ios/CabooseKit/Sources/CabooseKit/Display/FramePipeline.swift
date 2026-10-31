import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

/// Decodes and applies one window's Caboose Display pictures, in order, off the main thread.
///
/// Every frame is acknowledged with its decode time (`ack`), and the server keeps at most two
/// frames unacknowledged per window, so acking promptly is what keeps a window moving. A frame
/// that cannot be decoded is acked with −1 and a keyframe is requested; until it arrives the
/// pictures that depend on the lost one are acked as failed without being decoded.
final class FramePipeline: @unchecked Sendable {
    let windowID: Int
    let surface: WindowSurface
    private let queue: DispatchQueue
    private let send: @Sendable (ClientMessage) -> Void
    private let makeDecoder: (DisplayCodec) -> PictureDecoder
    private let metrics: ConnectionMetrics?
    private let atlasRenderer: SurfaceAtlasRenderer
    private let sceneState: WindowSceneState
    /// Set by `close()` at once, so pictures still queued from a closed connection are
    /// dropped instead of painting over what a later connection shows.
    private let retiredLock = NSLock()
    private var retired = false
    // On `queue`:
    private var decoder: (codec: DisplayCodec, decoder: PictureDecoder)?
    private var awaitingKeyframe = false
    private var lastKeyframeRequest: UInt64 = 0
    private var showsLivePicture = false
    /// How the window's picture maps into the window: the last frame's `crop` (picture pixels)
    /// and `rect` (window pixels). Tiles are in picture pixels and go through the same mapping.
    private var placement: (crop: CGRect, rect: CGRect)?

    init(windowID: Int, width: Int, height: Int, metrics: ConnectionMetrics? = nil,
         makeDecoder: @escaping (DisplayCodec) -> PictureDecoder = FramePipeline.hardwareDecoder,
         send: @escaping @Sendable (ClientMessage) -> Void) {
        self.windowID = windowID
        self.send = send
        self.makeDecoder = makeDecoder
        self.metrics = metrics
        atlasRenderer = SurfaceAtlasRenderer()
        sceneState = WindowSceneState(windowID: windowID)
        surface = WindowSurface()
        queue = DispatchQueue(label: "caboose.display.window.\(windowID)", qos: .userInteractive)
        surface.resize(width: width, height: height)
    }

    /// The same window on a new connection to the same server: it paints on into the
    /// closed pipeline's surface, on the closed pipeline's queue, so everything that one
    /// still had queued runs (and is dropped) before the first new picture.
    init(succeeding closed: FramePipeline, width: Int, height: Int, metrics: ConnectionMetrics?,
         makeDecoder: @escaping (DisplayCodec) -> PictureDecoder, send: @escaping @Sendable (ClientMessage) -> Void) {
        windowID = closed.windowID
        surface = closed.surface
        queue = closed.queue
        self.send = send
        self.makeDecoder = makeDecoder
        self.metrics = metrics
        atlasRenderer = closed.atlasRenderer
        sceneState = closed.sceneState
        showsLivePicture = true
        surface.resize(width: width, height: height)
    }

    private var isRetired: Bool { retiredLock.withLock { retired } }

    static func hardwareDecoder(_ codec: DisplayCodec) -> PictureDecoder {
        switch codec {
        case .h264: H264Decoder(codec: .h264)
        case .hevc: H264Decoder(codec: .hevc)
        case .av1: AV1Decoder()
        }
    }

    func resize(width: Int, height: Int) {
        queue.async { [self] in
            // Metadata may precede the replacement picture. Keep the old picture's
            // coordinate space until its successor is decoded, so overlays scale with it.
            // A window shown only as tiles (one with alpha) has no replacement frame to
            // wait for: its next picture is a whole tile at the new size.
            if !showsLivePicture || decoder == nil { surface.resize(width: width, height: height) }
        }
    }

    /// Paints a cached frame over the whole window, unless a live picture has already landed.
    /// The kept picture is reduced, so it is scaled to the window's size rather than placed.
    func seed(_ image: CGImage) {
        queue.async { [self] in
            if !showsLivePicture, !isRetired { surface.upload(image: image, into: CGRect(origin: .zero, size: surface.pixelSize)) }
        }
    }

    func close() {
        retiredLock.withLock { retired = true }
        queue.async { [self] in
            decoder?.decoder.invalidate()
            decoder = nil
        }
    }

    /// Runs `body` after everything queued so far; for tests.
    func flush() { queue.sync {} }

    /// Calls `body` with the surface's generation once every picture queued so far is applied.
    func whenApplied(_ body: @escaping @Sendable (UInt64) -> Void) {
        queue.async { [surface] in body(surface.generation) }
    }

    func frame(_ frame: EncodedFrame) {
        let arrived = CACurrentMediaTime()
        queue.async { [self] in
            guard !isRetired else { return }
            let started = CACurrentMediaTime()
            let start = DispatchTime.now().uptimeNanoseconds
            var decoded = false
            if frame.keyframe || !awaitingKeyframe {
                decoded = apply(frame)
            }
            if decoded {
                awaitingKeyframe = false
            } else {
                awaitingKeyframe = true
                requestKeyframe(now: start)
            }
            DrawStatistics.shared.record(frame.codec.rawValue, failed: !decoded)
            let finished = CACurrentMediaTime()
            metrics?.picture(window: windowID, waited: started - arrived, took: finished - started, failed: !decoded, at: finished)
            let micros = decoded ? Int((DispatchTime.now().uptimeNanoseconds - start) / 1000) : -1
            send(.ack(window: windowID, ptsMicros: frame.ptsMicros, decodedMicros: micros))
        }
    }

    private func apply(_ frame: EncodedFrame) -> Bool {
        if decoder?.codec != frame.codec {
            decoder?.decoder.invalidate()
            decoder = (frame.codec, makeDecoder(frame.codec))
        }
        guard let decoder else { return false }
        do {
            // A picture the decoder holds back (none here: the server sends no B-frames) is not a failure.
            guard let picture = try decoder.decoder.decode(frame.data) else { return true }
            if frame.rect.minX == 0, frame.rect.minY == 0 {
                surface.resize(width: Int(frame.rect.width.rounded(.up)), height: Int(frame.rect.height.rounded(.up)))
            }
            surface.upload(pixelBuffer: picture, crop: frame.crop, into: frame.rect)
            placement = (frame.crop, frame.rect)
            showsLivePicture = true
            return true
        } catch {
            return false
        }
    }

    /// Where a picture-pixel rectangle is shown in the window, through the last frame's
    /// crop → rect mapping (1:1 before the first frame).
    static func window(_ picture: CGRect, placement: (crop: CGRect, rect: CGRect)?) -> CGRect {
        guard let placement, placement.crop.width > 0, placement.crop.height > 0 else { return picture }
        let sx = placement.rect.width / placement.crop.width, sy = placement.rect.height / placement.crop.height
        return CGRect(x: placement.rect.minX + (picture.minX - placement.crop.minX) * sx,
                      y: placement.rect.minY + (picture.minY - placement.crop.minY) * sy,
                      width: picture.width * sx, height: picture.height * sy)
    }

    /// Pictures were dropped (the app was in the background): decoding starts again at a
    /// keyframe, on a fresh decoder, since the system may have invalidated the old one.
    func resumeAfterGap() {
        queue.async { [self] in
            guard !isRetired else { return }
            decoder?.decoder.invalidate()
            decoder = nil
            awaitingKeyframe = true
            lastKeyframeRequest = 0
            requestKeyframe(now: DispatchTime.now().uptimeNanoseconds)
        }
    }

    /// At most one request every half second while the stream is broken.
    private func requestKeyframe(now: UInt64) {
        guard now &- lastKeyframeRequest > 500_000_000 else { return }
        lastKeyframeRequest = now
        send(.requestKeyframe(window: windowID))
    }

    /// A lossless tile (a caret, a typed letter, a small widget): pixels of the window's
    /// picture, in picture pixels, drawn where that part of the picture is shown.
    func tile(_ tile: LosslessTile) {
        queue.async { [self] in
            guard !isRetired else { return }
            guard let source = CGImageSourceCreateWithData(tile.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                DrawStatistics.shared.record("tile-\(tile.format)", failed: true)
                return
            }
            surface.upload(image: image, into: Self.window(tile.rect, placement: placement))
            showsLivePicture = true
            DrawStatistics.shared.record("tile-\(tile.format)", failed: false)
        }
    }

    func surfaceBatch(_ batch: SurfaceBatch, cache: TileAtlasCache) {
        let arrived = CACurrentMediaTime()
        queue.async { [self] in
            guard !isRetired else { return }
            let started = CACurrentMediaTime()
            let start = DispatchTime.now().uptimeNanoseconds
            if !batch.keyframe && awaitingKeyframe {
                requestKeyframe(now: start)
                DrawStatistics.shared.record("atlas", failed: true)
                let finished = CACurrentMediaTime()
                metrics?.picture(window: windowID, waited: started - arrived, took: finished - started, failed: true, at: finished)
                send(.ack(window: windowID, ptsMicros: batch.ptsMicros, decodedMicros: -1))
                return
            }
            if atlasRenderer.applyAndUpload(batch, cache: cache, to: surface) {
                placement = (CGRect(origin: .zero, size: batch.size), batch.rect)
                showsLivePicture = true
                awaitingKeyframe = false
                DrawStatistics.shared.record("atlas", failed: false)
                let finished = CACurrentMediaTime()
                metrics?.picture(window: windowID, waited: started - arrived, took: finished - started, failed: false, at: finished)
                let micros = Int((DispatchTime.now().uptimeNanoseconds - start) / 1000)
                send(.ack(window: windowID, ptsMicros: batch.ptsMicros, decodedMicros: micros))
            } else {
                awaitingKeyframe = true
                requestKeyframe(now: start)
                DrawStatistics.shared.record("atlas", failed: true)
                let finished = CACurrentMediaTime()
                metrics?.picture(window: windowID, waited: started - arrived, took: finished - started, failed: true, at: finished)
                send(.ack(window: windowID, ptsMicros: batch.ptsMicros, decodedMicros: -1))
            }
        }
    }

    func sceneCommit(_ commit: SceneCommit, fontCache: SceneFontCache) {
        queue.async { [self] in
            guard !isRetired else { return }
            sceneState.apply(commit)
            guard let image = sceneState.render(size: surface.pixelSize, scale: 1.0, fontCache: fontCache) else {
                DrawStatistics.shared.record("scene", failed: true)
                return
            }
            surface.upload(image: image, into: CGRect(origin: .zero, size: surface.pixelSize))
            showsLivePicture = true
            DrawStatistics.shared.record("scene", failed: false)
        }
    }
}

/// Window id → frame pipeline, readable from the socket's queue.
final class FramePipelineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pipelines: [Int: FramePipeline] = [:]

    subscript(wid: Int) -> FramePipeline? {
        get { lock.lock(); defer { lock.unlock() }; return pipelines[wid] }
        set { lock.lock(); pipelines[wid] = newValue; lock.unlock() }
    }

    @discardableResult func remove(_ wid: Int) -> FramePipeline? {
        lock.lock(); defer { lock.unlock() }
        return pipelines.removeValue(forKey: wid)
    }

    var all: [FramePipeline] { lock.lock(); defer { lock.unlock() }; return Array(pipelines.values) }

    func removeAll() -> [FramePipeline] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(pipelines.values)
        pipelines.removeAll()
        return all
    }
}

/// Counts of applied pictures by codec, for diagnostics and tests.
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
