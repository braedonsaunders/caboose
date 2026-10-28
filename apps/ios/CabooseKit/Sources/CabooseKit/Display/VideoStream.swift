import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// One video playing inside a Linux window (docs/display.md "Video streams"): the app's own
/// compressed stream, or a video surface the compositor encodes, shown by an
/// `AVSampleBufferDisplayLayer` layered into the window at `rect`, cut to `clip`, ordered by
/// `z`.
///
/// Frames arrive in decode order and are decoded in hardware as they come, in the decoder's
/// own format so HDR survives. A live stream (`surface`, `motion`) shows each picture as it
/// decodes. An app's own stream (`passthrough`) carries no timestamps: its pictures are kept by
/// `seq` until `video.present` says the app is showing one, and it is shown then, already in
/// step with the app's own sound.
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

    /// Decoded pictures an app's stream may present, most recent last; older ones are dropped.
    static let keptPictures = 32

    private let queue: DispatchQueue
    private let send: @Sendable (ClientMessage) -> Void
    /// The session's playback clock: with the computer's sound playing, pictures are shown at
    /// their own times on it, in step with the sound.
    private let clock: MediaClock?
    // On `queue`:
    private let bitstream: BitstreamFormatter
    private var session: VTDecompressionSession?
    private var kept: [(seq: Int, picture: CVPixelBuffer)] = []
    private var pictureFormat: CMVideoFormatDescription?
    private var awaitingKeyframe = false
    private var lastKeyframeRequest: UInt64 = 0

    init?(_ fields: VideoStreamFields, clock: MediaClock? = nil, send: @escaping @Sendable (ClientMessage) -> Void) {
        guard let window = fields.window, let rect = fields.rect, let codec = fields.codec else { return nil }
        id = fields.id
        self.window = window
        self.codec = codec
        source = fields.source ?? .passthrough
        color = fields.color
        self.send = send
        self.clock = clock
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
        self.rect = rect
        clip = fields.clip
        z = fields.z ?? 0
        if color?.isHDR == true { showHDR() }
        clock?.add(layer.sampleBufferRenderer)
    }

    /// Stops playback; the window view drops the layer.
    func close() {
        queue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            kept.removeAll()
            layer.sampleBufferRenderer.flush()
            clock?.remove(layer.sampleBufferRenderer)
        }
    }

    /// Waits for everything queued so far; for tests.
    func flush() { queue.sync {} }

    func frame(_ frame: VideoFrame) {
        queue.async { [self] in
            guard frame.keyframe || !awaitingKeyframe else { return requestKeyframe() }
            do {
                guard let picture = try decode(frame.data) else { return }
                awaitingKeyframe = false
                if source.isLive {
                    show(picture, at: frame.ptsMicros)
                } else {
                    kept.append((frame.seq, picture))
                    if kept.count > Self.keptPictures { kept.removeFirst(kept.count - Self.keptPictures) }
                }
                send(.videoAck(video: id, seq: frame.seq))
            } catch {
                awaitingKeyframe = true
                kept.removeAll()
                requestKeyframe()
            }
        }
    }

    /// The app is showing frame `seq` at `pts` (server clock); earlier pictures it skipped are dropped.
    func present(seq: Int, at pts: UInt64? = nil) {
        queue.async { [self] in
            guard let index = kept.firstIndex(where: { $0.seq == seq }) else { return }
            let picture = kept[index].picture
            kept.removeFirst(index + 1)
            show(picture, at: pts)
        }
    }

    private func decode(_ accessUnit: Data) throws -> CVPixelBuffer? {
        let (bytes, changed) = try bitstream.sample(from: accessUnit)
        guard let format = bitstream.format else { throw H264DecoderError.noParameterSets }
        if changed || session == nil {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = try VideoToolboxSession.make(format, pixelFormat: nil)
            if color == nil, Self.isHDR(format) { showHDR() }
        }
        guard let bytes, let session else { return nil }
        let sample = try VideoToolboxSession.sampleBuffer(bytes, format: format)
        return try VideoToolboxSession.decode(sample, in: session) { [self] in
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    /// Hands a decoded picture to the layer: at its time on the session's clock while the
    /// computer's sound is playing, otherwise (or when it is already late) at once.
    private func show(_ picture: CVPixelBuffer, at pts: UInt64?) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        if pictureFormat.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: picture) }) ?? true {
            pictureFormat = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: picture, formatDescriptionOut: &pictureFormat)
        }
        guard let pictureFormat else { return }
        let scheduled = pts.flatMap { clock?.time(for: Int64($0)) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: scheduled ?? CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: picture, formatDescription: pictureFormat,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if scheduled == nil { Self.attach(kCMSampleAttachmentKey_DisplayImmediately, to: sample) }
        renderer.enqueue(sample)
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
