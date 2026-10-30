#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import UIKit
import VideoToolbox

/// The phone's cameras and depth sensor for the computer. One capture session runs at a time:
/// the camera opened last. When it closes, the one opened before it, if still open, runs again.
@MainActor
final class CameraCapture {
    var output: DeviceOutput?
    var onButton: ((DeviceKey, Bool) -> Void)?
    var buttonView: () -> UIView? = { nil }

    /// Open devices, the latest last, with what to call when one cannot run.
    private var opened: [(device: DeviceDescriptor, failed: @MainActor (String) -> Void)] = []
    private var running: CaptureRun?
    private var interaction: UIInteraction?
    private var observers: [NSObjectProtocol] = []

    func open(_ device: DeviceDescriptor, failed: @escaping @MainActor (String) -> Void) {
        opened.removeAll { $0.device.id == device.id }
        opened.append((device, failed))
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(device)
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard self.opened.last?.device.id == device.id else { return }
                if granted { self.run(device) } else { self.fail(device.id, "Camera access is off for Caboose in Settings.") }
            }
        default:
            fail(device.id, "Camera access is off for Caboose in Settings.")
        }
    }

    func close(_ id: String) {
        opened.removeAll { $0.device.id == id }
        guard running?.id == id else { return }
        stop()
        if let previous = opened.last?.device { run(previous) }
    }

    func closeAll() {
        opened.removeAll()
        stop()
    }

    func keyframe(_ id: String) {
        guard let running, running.id == id else { return }
        running.requestKeyframe()
    }

    private func fail(_ id: String, _ reason: String) {
        let entry = opened.first { $0.device.id == id }
        opened.removeAll { $0.device.id == id }
        if running?.id == id { stop() }
        entry?.failed(reason)
    }

    private func run(_ device: DeviceDescriptor) {
        guard let output else { return }
        if running?.id == device.id { return }
        stop()
        let run: CaptureRun?
        switch device.kind {
        case .camera:
            guard let capture = Self.captureDevice(for: device.id) else { return fail(device.id, "This camera is not available.") }
            run = CaptureRun(camera: device, capture: capture, output: output)
        case .depth:
            guard let depth = Self.depthDevice() else { return fail(device.id, "The depth sensor is not available.") }
            run = CaptureRun(depth: device, source: depth, output: output)
        default:
            return
        }
        guard let run else { return fail(device.id, "The camera could not start.") }
        running = run
        observe(run)
        run.start()
        if device.kind == .camera { addButtons() }
    }

    private func stop() {
        guard let run = running else { return }
        running = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        removeButtons()
        run.stop()
    }

    /// Another app taking the camera, or the camera failing, ends what the computer opened.
    private func observe(_ run: CaptureRun) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: run.session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
            MainActor.assumeIsolated {
                guard let self, self.running === run else { return }
                switch reason {
                case .videoDeviceInUseByAnotherClient: self.fail(run.id, "Another app is using the camera.")
                case .videoDeviceNotAvailableDueToSystemPressure: self.fail(run.id, "The camera stopped: the iPhone is too hot.")
                default: break // in the background or multitasking; it resumes on its own
                }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: run.session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, self.running === run else { return }
                self.fail(run.id, error?.localizedDescription ?? "The camera stopped.")
            }
        })
    }

    /// Volume up, and the primary button (volume down or Camera Control), while a camera streams.
    private func addButtons() {
        guard interaction == nil, let view = buttonView() else { return }
        func handle(_ key: DeviceKey) -> (AVCaptureEvent) -> Void {
            { [weak self] event in
                let pressed = event.phase == .began
                MainActor.assumeIsolated { self?.onButton?(key, pressed) }
            }
        }
        let interaction = AVCaptureEventInteraction(primary: handle(.camera), secondary: handle(.volumeUp))
        view.addInteraction(interaction)
        self.interaction = interaction
    }

    private func removeButtons() {
        guard let interaction else { return }
        interaction.view?.removeInteraction(interaction)
        self.interaction = nil
    }

    // MARK: Hardware

    static func captureDevice(for id: String) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
        return discovery.devices.first { device in
            let position: CameraPosition? = switch device.position {
            case .back: .back
            case .front: .front
            default: nil
            }
            let lens: PhoneHardware.Lens = switch device.deviceType {
            case .builtInUltraWideCamera: .ultraWide
            case .builtInTelephotoCamera: .telephoto
            default: .wide
            }
            return position.map { PhoneHardware.Camera(position: $0, lens: lens).id } == id
        }
    }

    /// The depth sensor (LiDAR where the phone has it, else TrueDepth) with the format it is
    /// run in: the largest depth map at most 640 pixels wide.
    struct DepthSource {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let depthFormat: AVCaptureDevice.Format
        let position: CameraPosition
        let width: Int
        let height: Int
        let fps: Double
    }

    nonisolated static func depthDevice() -> DepthSource? {
        let candidates: [(AVCaptureDevice?, CameraPosition)] = [
            (AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back), .back),
            (AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front), .front),
        ]
        for case let (device?, position) in candidates {
            var best: DepthSource?
            for format in device.formats {
                for depth in format.supportedDepthDataFormats {
                    let type = CMFormatDescriptionGetMediaSubType(depth.formatDescription)
                    guard type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16 else { continue }
                    let size = CMVideoFormatDescriptionGetDimensions(depth.formatDescription)
                    guard size.width <= 640, size.width % 2 == 0, size.height % 2 == 0 else { continue }
                    if let best, best.width >= Int(size.width) { continue }
                    let rate = depth.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                    best = DepthSource(device: device, format: format, depthFormat: depth, position: position,
                                       width: Int(size.width), height: Int(size.height), fps: min(30, max(1, rate.rounded(.down))))
                }
            }
            if let best { return best }
        }
        return nil
    }
}

/// One running capture session: a camera encoded to H.264, or the depth sensor.
final class CaptureRun: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    let id: String
    let session = AVCaptureSession()
    /// One queue for every run, so a camera being switched away from stops before the next
    /// one starts.
    private static let sharedQueue = DispatchQueue(label: "caboose.devices.capture", qos: .userInteractive)
    private var queue: DispatchQueue { Self.sharedQueue }
    private let output: DeviceOutput
    private var encoder: H264Encoder?
    private var depthSize: (width: Int, height: Int)?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// A frame was dropped for a slow link: the next one goes as a keyframe.
    private var dropped = false

    init?(camera device: DeviceDescriptor, capture: AVCaptureDevice, output: DeviceOutput) {
        id = device.id
        self.output = output
        super.init()
        let size = device.size ?? DeviceCatalog.cameraSize
        let fps = device.fps ?? DeviceCatalog.cameraFPS
        let id = device.id
        encoder = H264Encoder(width: size.width, height: size.height, fps: fps) { data, keyframe, seq, micros in
            output.send(.deviceCamera(device: id, seq: seq, keyframe: keyframe, micros: micros, data: data))
        }
        guard encoder != nil else { return nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        guard let input = try? AVCaptureDeviceInput(device: capture), session.canAddInput(input) else { return nil }
        session.addInput(input)
        if let format = Self.format(of: capture, width: size.width, height: size.height, fps: fps), (try? capture.lockForConfiguration()) != nil {
            capture.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            capture.activeVideoMinFrameDuration = duration
            capture.activeVideoMaxFrameDuration = duration
            capture.unlockForConfiguration()
        }
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(video) else { return nil }
        session.addOutput(video)
        if let connection = video.connection(with: .video) {
            // Linux applications mirror their own self-view; the stream is the scene as it is.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            // Upright for however the phone is held.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: capture, previewLayer: nil)
            rotation = coordinator
            let apply: (CGFloat) -> Void = { angle in
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
            apply(coordinator.videoRotationAngleForHorizonLevelCapture)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [queue] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                queue.async { apply(angle) }
            }
        }
    }

    init?(depth device: DeviceDescriptor, source: CameraCapture.DepthSource, output: DeviceOutput) {
        id = device.id
        self.output = output
        depthSize = (source.width, source.height)
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        guard let input = try? AVCaptureDeviceInput(device: source.device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        let depth = AVCaptureDepthDataOutput()
        depth.isFilteringEnabled = true
        depth.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depth) else { return nil }
        session.addOutput(depth)
        depth.setDelegate(self, callbackQueue: queue)
        guard (try? source.device.lockForConfiguration()) != nil else { return nil }
        source.device.activeFormat = source.format
        source.device.activeDepthDataFormat = source.depthFormat
        source.device.unlockForConfiguration()
    }

    func start() {
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        rotationObservation?.invalidate()
        queue.async { [session, encoder] in
            session.stopRunning()
            encoder?.invalidate()
        }
    }

    func requestKeyframe() {
        queue.async { [encoder] in encoder?.forceKeyframe() }
    }

    /// Whether the link is too far behind for another picture now.
    private var linkIsBehind: Bool {
        guard let backlog = output.backlog() else { return false }
        return backlog.count > 8 || (backlog.oldestMs ?? 0) > 300
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let encoder, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if linkIsBehind {
            dropped = true
            return
        }
        if dropped {
            dropped = false
            encoder.forceKeyframe()
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder.encode(pixels, micros: UInt64(max(0, time.seconds) * 1_000_000), time: time)
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        guard let size = depthSize, !linkIsBehind else { return }
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32 ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        guard CVPixelBufferGetWidth(map) == size.width, CVPixelBufferGetHeight(map) == size.height else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let stride = CVPixelBufferGetBytesPerRow(map)
        var metres = [Float]()
        metres.reserveCapacity(size.width * size.height)
        for row in 0 ..< size.height {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
            metres.append(contentsOf: UnsafeBufferPointer(start: line, count: size.width))
        }
        self.output.send(.deviceDepth(device: id, micros: UInt64(max(0, timestamp.seconds) * 1_000_000),
                                      width: size.width, height: size.height, data: DepthPicture.millimetres(fromMetres: metres)))
    }

    /// The smallest 4:2:0 format at least `width × height` (either way round) that runs at `fps`.
    private static func format(of device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        let long = max(width, height), short = min(width, height)
        return device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                && Int(max(size.width, size.height)) >= long && Int(min(size.width, size.height)) >= short
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }.min { a, b in
            let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription), y = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(x.width) * Int(x.height) < Int(y.width) * Int(y.height)
        }
    }
}

/// Real-time H.264 for one camera: every picture scaled into `width × height` (letterboxed
/// when the phone is held the other way), main profile, no reordering, a keyframe every two
/// seconds or when asked. Output is Annex-B with SPS and PPS on keyframes.
final class H264Encoder: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private let emit: (Data, Bool, UInt64, UInt64) -> Void
    private var seq: UInt64 = 0
    private var keyframeNext = true
    private let lock = NSLock()

    init?(width: Int, height: Int, fps: Double, emit: @escaping (Data, Bool, UInt64, UInt64) -> Void) {
        self.width = width
        self.height = height
        self.emit = emit
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { return nil }
        let bitRate = Int(Double(width * height) * fps * 0.12)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            // Low-latency rate control supports the constrained profiles only.
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
        ]
        for (key, value) in properties {
            guard VTSessionSetProperty(session, key: key, value: value as CFTypeRef) == noErr else {
                VTCompressionSessionInvalidate(session)
                return nil
            }
        }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr, let transfer else { return nil }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        self.session = session
        self.transfer = transfer
    }

    func forceKeyframe() {
        lock.withLock { keyframeNext = true }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        transfer.map(VTPixelTransferSessionInvalidate)
        transfer = nil
    }

    func encode(_ source: CVPixelBuffer, micros: UInt64, time: CMTime) {
        guard let session, let transfer, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var scaled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess, let scaled,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else { return }
        let force = lock.withLock { () -> Bool in
            defer { keyframeNext = false }
            return keyframeNext
        }
        let options = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: scaled, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample, micros: micros)
        }
    }

    private func deliver(_ sample: CMSampleBuffer, micros: UInt64) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var body = Data(count: length)
        let copied = body.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return }
        var count = 0
        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        var sets: [Data] = []
        if keyframe {
            for index in 0 ..< count {
                var set: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let set {
                    sets.append(Data(bytes: set, count: size))
                }
            }
        }
        guard let annexB = AnnexB.from(lengthPrefixed: body, lengthSize: Int(headerLength), parameterSets: sets) else { return }
        let number = lock.withLock { () -> UInt64 in
            defer { seq += 1 }
            return seq
        }
        emit(annexB, keyframe, number, micros)
    }
}
#endif
