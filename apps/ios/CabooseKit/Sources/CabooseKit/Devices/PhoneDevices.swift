#if os(iOS)
import AVFoundation
import CoreHaptics
import CoreMotion
import GameController
import UIKit

/// The phone's own hardware for `DeviceCenter`: its cameras and depth sensor
/// (`CameraCapture`), microphone (`MicrophoneCapture`), Core Motion (`MotionCapture`), the
/// controllers paired with it, its hardware buttons and its battery.
@MainActor
public final class PhoneDevices: DeviceBackend {
    public private(set) var hardware: PhoneHardware
    public var onChange: (() -> Void)?
    public var onButton: ((DeviceKey, Bool) -> Void)?
    /// The view the hardware-button interaction is added to while a camera streams: the app's
    /// main window. Without one the buttons are not captured.
    public var buttonView: () -> UIView? = { nil } {
        didSet { camera.buttonView = buttonView }
    }

    private let camera = CameraCapture()
    private let microphone = MicrophoneCapture()
    private let motion = MotionCapture()
    private let controllerBridge = ControllerBridge()
    private let screenRumbler = Rumbler {
        let engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        return engine
    }
    public let screenRumble = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var observers: [NSObjectProtocol] = []

    public init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        hardware = Self.probe()
        camera.onButton = { [weak self] key, pressed in self?.onButton?(key, pressed) }
        controllerBridge.onChange = { [weak self] in self?.onChange?() }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public var controllers: [ConnectedController] { controllerBridge.controllers }

    public var battery: BatteryReport? {
        let device = UIDevice.current
        guard device.batteryLevel >= 0 else { return nil }
        let thermal: ThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        // iOS reports the level in 5% steps; rounding keeps a report from changing on noise.
        let level = (Double(device.batteryLevel) * 100).rounded() / 100
        return BatteryReport(level: level, charging: device.batteryState == .charging, full: device.batteryState == .full,
                             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: thermal)
    }

    public func attach(_ output: DeviceOutput) {
        controllerBridge.attach(output)
        camera.output = output
        microphone.output = output
        motion.output = output
    }

    public func offer(_ devices: [DeviceDescriptor]) {
        controllerBridge.offer(Set(devices.filter { $0.kind == .gamepad }.map(\.id)))
    }

    public func open(_ device: DeviceDescriptor, rateHz: Double?, failed: @escaping @MainActor (String) -> Void) {
        switch device.kind {
        case .camera, .depth: camera.open(device, failed: failed)
        case .microphone: microphone.open(device, failed: failed)
        case .motion: motion.open(device, rateHz: rateHz, failed: failed)
        default: break
        }
    }

    public func close(_ device: DeviceDescriptor) {
        switch device.kind {
        case .camera, .depth: camera.close(device.id)
        case .microphone: microphone.close()
        case .motion: motion.close()
        default: break
        }
    }

    public func keyframe(_ device: DeviceDescriptor) {
        if device.kind == .camera { camera.keyframe(device.id) }
    }

    public func rumble(_ device: DeviceDescriptor, strong: Double, weak: Double, ms: Int) {
        if device.id == ConnectedController.screenID {
            playScreenRumble(strong: strong, weak: weak, ms: ms)
        } else {
            controllerBridge.rumble(device.id, strong: strong, weak: weak, ms: ms)
        }
    }

    public func detach() {
        camera.closeAll()
        microphone.close()
        motion.close()
        controllerBridge.detach()
        camera.output = nil
        microphone.output = nil
        motion.output = nil
        screenRumbler.stop()
    }

    /// The on-screen controller rumbles the phone itself.
    private func playScreenRumble(strong: Double, weak: Double, ms: Int) {
        guard screenRumble else { return }
        screenRumbler.play(strong: strong, weak: weak, ms: ms)
    }

    /// What this phone has, read once: the hardware does not change while the app runs.
    static func probe() -> PhoneHardware {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
        var cameras: [PhoneHardware.Camera] = []
        for device in discovery.devices {
            let position: CameraPosition
            switch device.position {
            case .back: position = .back
            case .front: position = .front
            default: continue
            }
            let lens: PhoneHardware.Lens = switch device.deviceType {
            case .builtInUltraWideCamera: .ultraWide
            case .builtInTelephotoCamera: .telephoto
            default: .wide
            }
            let camera = PhoneHardware.Camera(position: position, lens: lens)
            if !cameras.contains(camera) { cameras.append(camera) }
        }
        // Back cameras first, wide first, as Linux lists them.
        cameras.sort { ($0.position == .back ? 0 : 1, $0.lens.order) < ($1.position == .back ? 0 : 1, $1.lens.order) }
        let depth = CameraCapture.depthDevice().map { PhoneHardware.Depth(position: $0.position, width: $0.width, height: $0.height, fps: $0.fps) }
        let manager = CMMotionManager()
        var motion: [MotionSensor] = []
        if manager.isDeviceMotionAvailable {
            if manager.isAccelerometerAvailable { motion.append(.accelerometer) }
            if manager.isGyroAvailable { motion.append(.gyroscope) }
            if manager.isMagnetometerAvailable { motion.append(.magnetometer) }
            motion.append(.rotation)
            if CMAltimeter.isRelativeAltitudeAvailable() { motion.append(.pressure) }
        }
        // Volume up and the primary button (volume down, or Camera Control) while a camera
        // streams; the Action button through its App Intent.
        var buttons: [DeviceKey] = []
        if !cameras.isEmpty { buttons += [.volumeUp, .camera] }
        buttons.append(.action)
        return PhoneHardware(model: UIDevice.current.model, cameras: cameras, depth: depth,
                             microphone: AVAudioSession.sharedInstance().isInputAvailable, motion: motion,
                             buttons: buttons, battery: UIDevice.current.batteryLevel >= 0)
    }
}

private extension PhoneHardware.Lens {
    var order: Int {
        switch self {
        case .wide: 0
        case .ultraWide: 1
        case .telephoto: 2
        }
    }
}

/// A rumble as a haptic pattern: the strong motor's share as intensity, the weak one's as sharpness.
enum Rumble {
    static func pattern(strong: Double, weak: Double, ms: Int) -> CHHapticPattern? {
        let intensity = Float(max(strong, weak))
        guard intensity > 0 else { return nil }
        let sharpness = Float(strong + weak > 0 ? weak / (strong + weak) : 0.5)
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0, duration: Double(min(ms, 10_000)) / 1000)
        return try? CHHapticPattern(events: [event], parameters: [])
    }
}

/// The controllers paired with the phone, each a gamepad with a stable id while it stays
/// connected, reporting its state to the computer while it is offered.
@MainActor
final class ControllerBridge {
    var onChange: (() -> Void)?
    private(set) var controllers: [ConnectedController] = []
    private var slots = ControllerSlots<ObjectIdentifier>()
    private var byID: [String: GCController] = [:]
    private var output: DeviceOutput?
    private var offered = Set<String>()
    private var last: [String: GamepadReport] = [:]
    private var rumblers: [String: Rumbler] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        reload()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(_ output: DeviceOutput) {
        self.output = output
        last.removeAll()
    }

    func offer(_ ids: Set<String>) {
        offered = ids
        // A controller newly offered reports where it is now.
        for (id, controller) in byID where ids.contains(id) && last[id] == nil { report(controller, id: id) }
    }

    func detach() {
        output = nil
        offered = []
        last.removeAll()
        for rumbler in rumblers.values { rumbler.stop() }
        rumblers.removeAll()
    }

    func rumble(_ id: String, strong: Double, weak: Double, ms: Int) {
        guard let controller = byID[id], let haptics = controller.haptics else { return }
        if rumblers[id] == nil { rumblers[id] = Rumbler { [weak haptics] in haptics?.createEngine(withLocality: .default) } }
        rumblers[id]?.play(strong: strong, weak: weak, ms: ms)
    }

    private func reload() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
        slots.keep(only: Set(connected.map(ObjectIdentifier.init)))
        var next: [ConnectedController] = []
        var map: [String: GCController] = [:]
        for controller in connected {
            let id = slots.id(for: ObjectIdentifier(controller))
            map[id] = controller
            next.append(ConnectedController(id: id, name: controller.vendorName ?? "Game Controller", rumble: controller.haptics != nil))
            controller.extendedGamepad?.valueChangedHandler = { [weak self, weak controller] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let controller else { return }
                    self.report(controller, id: id)
                }
            }
        }
        for id in byID.keys where map[id] == nil {
            rumblers[id]?.stop()
            rumblers[id] = nil
            last[id] = nil
        }
        byID = map
        next.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        if next != controllers {
            controllers = next
            onChange?()
        }
    }

    private func report(_ controller: GCController, id: String) {
        guard let output, offered.contains(id), let pad = controller.extendedGamepad else { return }
        let report = GamepadReport(Self.state(pad))
        guard report != last[id] else { return }
        last[id] = report
        output.send(.deviceGamepad(device: id, report))
    }

    /// A controller's state in the standard mapping (y down-positive), as the on-screen one reports it.
    static func state(_ pad: GCExtendedGamepad) -> GameGamepadState {
        var state = GameGamepadState()
        state[.south] = Double(pad.buttonA.value)
        state[.east] = Double(pad.buttonB.value)
        state[.west] = Double(pad.buttonX.value)
        state[.north] = Double(pad.buttonY.value)
        state[.leftShoulder] = Double(pad.leftShoulder.value)
        state[.rightShoulder] = Double(pad.rightShoulder.value)
        state[.leftTrigger] = Double(pad.leftTrigger.value)
        state[.rightTrigger] = Double(pad.rightTrigger.value)
        state[.select] = Double(pad.buttonOptions?.value ?? 0)
        state[.start] = Double(pad.buttonMenu.value)
        state[.home] = Double(pad.buttonHome?.value ?? 0)
        state[.leftStick] = Double(pad.leftThumbstickButton?.value ?? 0)
        state[.rightStick] = Double(pad.rightThumbstickButton?.value ?? 0)
        state[.up] = pad.dpad.up.isPressed ? 1 : 0
        state[.down] = pad.dpad.down.isPressed ? 1 : 0
        state[.left] = pad.dpad.left.isPressed ? 1 : 0
        state[.right] = pad.dpad.right.isPressed ? 1 : 0
        state[.leftX] = Double(pad.leftThumbstick.xAxis.value)
        state[.leftY] = -Double(pad.leftThumbstick.yAxis.value)
        state[.rightX] = Double(pad.rightThumbstick.xAxis.value)
        state[.rightY] = -Double(pad.rightThumbstick.yAxis.value)
        return state
    }
}
/// Plays rumbles on one haptic engine, kept running between them: each replaces the one
/// playing, and a rumble of 0 ms only stops it.
@MainActor
final class Rumbler {
    private let make: () -> CHHapticEngine?
    private var engine: CHHapticEngine?
    private var running = false
    private var player: CHHapticPatternPlayer?

    init(make: @escaping () -> CHHapticEngine?) {
        self.make = make
    }

    func play(strong: Double, weak: Double, ms: Int) {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        guard ms > 0, let pattern = Rumble.pattern(strong: strong, weak: weak, ms: ms) else { return }
        if engine == nil {
            guard let made = make() else { return }
            // The system stops an engine (audio interruptions, the app in the background);
            // the next rumble starts it again.
            made.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.running = false } }
            made.resetHandler = { [weak self] in Task { @MainActor in self?.running = false } }
            engine = made
        }
        guard let engine else { return }
        do {
            if !running {
                try engine.start()
                running = true
            }
            let next = try engine.makePlayer(with: pattern)
            try next.start(atTime: CHHapticTimeImmediate)
            player = next
        } catch {
            self.engine = nil
            running = false
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        running = false
    }
}
#endif
