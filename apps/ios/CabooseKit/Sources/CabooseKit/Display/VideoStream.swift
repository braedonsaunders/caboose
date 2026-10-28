import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// One video playing inside a Linux window (docs/display.md "Video, for every app"): the
/// app's own compressed stream, or a video surface the compositor encodes, shown by an
/// `AVSampleBufferDisplayLayer` layered into the window at `rect`, cut to `clip`, ordered
/// by `z`. Hardware decode, HDR and frame timing are the layer's.
///
/// An app's own stream plays on its own timeline through an `AVSampleBufferRenderSynchronizer`
/// (the clock the stream's sound will share once Caboose Display carries audio); a live
/// stream is shown the moment each picture decodes.
public final class RemoteVideo: @unchecked Sendable {
    public let id: Int
    public let window: Int
    public let codec: DisplayCodec
    public let source: VideoSource
    public let color: VideoColor?
    /// The picture, scaled to `rect`.
    public let layer: AVSampleBufferDisplayLayer
    /// Holds `layer` and cuts it to `clip`; this is what a window view hosts.
    public let container: CALayer

    /// Layout in window-local display pixels; read and written on the main actor only.
    public internal(set) var rect: CGRect
    public internal(set) var clip: CGRect?
    public internal(set) var z: Int

    private let queue: DispatchQueue
    private let send: @Sendable (ClientMessage) -> Void
    private let synchronizer: AVSampleBufferRenderSynchronizer?
    // On `queue`:
    private let bitstream: BitstreamFormatter
    private var timeline = VideoTimeline()
    private var awaitingKeyframe = false
    private var lastKeyframeRequest: UInt64 = 0

    init?(_ fields: VideoStreamFields, send: @escaping @Sendable (ClientMessage) -> Void) {
        guard let window = fields.window, let rect = fields.rect, let codec = fields.codec else { return nil }
        id = fields.id
        self.window = window
        self.codec = codec
        source = fields.source ?? .passthrough
        color = fields.color
        self.send = send
        queue = DispatchQueue(label: "caboose.display.video.\(fields.id)", qos: .userInteractive)
        bitstream = switch codec {
        case .h264: NALFormatter(codec: .h264)
        case .hevc: NALFormatter(codec: .hevc)
        case .av1: OBUFormatter()
        }
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resize
        container = CALayer()
        container.masksToBounds = true
        container.addSublayer(layer)
        if source.isLive {
            synchronizer = nil
        } else {
            let synchronizer = AVSampleBufferRenderSynchronizer()
            synchronizer.addRenderer(layer.sampleBufferRenderer)
            self.synchronizer = synchronizer
        }
        self.rect = rect
        clip = fields.clip
        z = fields.z ?? 0
        if color?.isHDR == true { showHDR() }
    }

    /// PQ or HLG tagged in the stream itself.
    static func isHDR(_ format: CMFormatDescription) -> Bool {
        guard let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return false }
        return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }

    /// An HDR stream is shown with the screen's extended dynamic range rather than tone mapped to SDR.
    private func showHDR() {
        let layer = layer
        DispatchQueue.main.async {
            if #available(iOS 26, macOS 26, *) { layer.preferredDynamicRange = .high }
        }
    }

    /// Stops playback; the window view drops the layer.
    func close() {
        queue.async { [self] in
            synchronizer?.setRate(0, time: .invalid)
            layer.sampleBufferRenderer.flush()
        }
    }

    /// Runs `body` after everything queued so far; for tests.
    func flush() { queue.sync {} }

    func frame(_ frame: VideoFrame) {
        queue.async { [self] in
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                timeline = VideoTimeline()
                awaitingKeyframe = true
            }
            guard frame.keyframe || !awaitingKeyframe else { return requestKeyframe() }
            do {
                let (bytes, formatChanged) = try bitstream.sample(from: frame.data)
                guard let bytes, let format = bitstream.format else { return }
                if formatChanged, color == nil, Self.isHDR(format) { showHDR() }
                let timing = CMSampleTimingInfo(
                    duration: .invalid, presentationTimeStamp: CMTime(value: Int64(frame.ptsMicros), timescale: 1_000_000),
                    decodeTimeStamp: frame.dtsMicros.map { CMTime(value: Int64($0), timescale: 1_000_000) } ?? .invalid)
                let sample = try VideoToolboxSession.sampleBuffer(bytes, format: format, timing: timing)
                schedule(sample, pts: Int64(frame.ptsMicros))
                renderer.enqueue(sample)
                awaitingKeyframe = false
                send(.videoAck(video: id, ptsMicros: frame.ptsMicros))
            } catch {
                awaitingKeyframe = true
                requestKeyframe()
            }
        }
    }

    /// Keeps the clock running with the app's timestamps; a live sample is shown as soon as
    /// it decodes instead.
    private func schedule(_ sample: CMSampleBuffer, pts: Int64) {
        guard let synchronizer else {
            Self.attach(kCMSampleAttachmentKey_DisplayImmediately, to: sample)
            return
        }
        let now = synchronizer.rate == 0 ? nil : CMTimeConvertScale(synchronizer.currentTime(), timescale: 1_000_000, method: .default).value
        switch timeline.place(pts: pts, now: now) {
        case .play:
            break
        case .anchor(let start):
            synchronizer.setRate(1, time: CMTime(value: start, timescale: 1_000_000))
        case .restart(let start):
            layer.sampleBufferRenderer.flush()
            synchronizer.setRate(1, time: CMTime(value: start, timescale: 1_000_000))
        }
    }

    private static func attach(_ key: CFString, to sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    /// At most one request every half second while the stream is broken.
    private func requestKeyframe() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastKeyframeRequest > 500_000_000 else { return }
        lastKeyframeRequest = now
        send(.videoKeyframe(video: id))
    }
}

/// Where an app's own stream sits on the playback clock. The first picture starts the clock a
/// little behind it, so network jitter does not stall playback; a jump of more than a second
/// (a seek, a new item) restarts it there; pictures that keep arriving late move it back.
struct VideoTimeline: Equatable {
    /// How far behind the first picture the clock starts, in microseconds.
    static let preroll: Int64 = 80_000
    static let jump: Int64 = 1_000_000

    enum Placement: Equatable {
        case play
        /// Start (or move) the clock to this time, keeping what is queued.
        case anchor(Int64)
        /// Drop what is queued and start the clock here.
        case restart(Int64)
    }

    private(set) var anchored = false

    /// `now` is the clock's current time, nil while it is stopped.
    mutating func place(pts: Int64, now: Int64?) -> Placement {
        guard anchored, let now else {
            anchored = true
            return .anchor(pts - Self.preroll)
        }
        if abs(pts - now) > Self.jump { return .restart(pts - Self.preroll) }
        if now - pts > Self.preroll { return .anchor(pts - Self.preroll) } // late: fall back behind it
        return .play
    }
}

/// Video id → stream, readable from the socket's queue.
final class VideoRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var videos: [Int: RemoteVideo] = [:]

    subscript(id: Int) -> RemoteVideo? {
        get { lock.lock(); defer { lock.unlock() }; return videos[id] }
        set { lock.lock(); videos[id] = newValue; lock.unlock() }
    }

    @discardableResult func remove(_ id: Int) -> RemoteVideo? {
        lock.lock(); defer { lock.unlock() }
        return videos.removeValue(forKey: id)
    }

    func removeAll() -> [RemoteVideo] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(videos.values)
        videos.removeAll()
        return all
    }
}
