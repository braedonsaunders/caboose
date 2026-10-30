import Foundation
import Observation

/// How device sources reach the computer: the display connection's send, callable from any
/// queue, and how much is waiting to go out on it.
public struct DeviceOutput: Sendable {
    public let send: @Sendable (ClientMessage) -> Void
    public let backlog: @Sendable () -> SendBacklog?

    public init(send: @escaping @Sendable (ClientMessage) -> Void, backlog: @escaping @Sendable () -> SendBacklog? = { nil }) {
        self.send = send
        self.backlog = backlog
    }
}

/// The phone's hardware itself: what it has, and running each source when the computer
/// opens it. `PhoneDevices` on iOS; tests use their own.
@MainActor public protocol DeviceBackend: AnyObject {
    var hardware: PhoneHardware { get }
    /// Controllers paired with the phone, with their stable ids.
    var controllers: [ConnectedController] { get }
    /// Nil where the phone reports no battery.
    var battery: BatteryReport? { get }
    /// Called when the hardware, the controllers or the battery change.
    var onChange: (() -> Void)? { get set }
    /// A hardware button went down or up (while a camera streams, or the Action button).
    var onButton: ((DeviceKey, Bool) -> Void)? { get set }
    /// Sending may start: controllers report their state to `output` from now on.
    func attach(_ output: DeviceOutput)
    /// The devices offered now; a controller reports its state only while it is offered.
    func offer(_ devices: [DeviceDescriptor])
    /// Start a camera, the depth sensor, the microphone or motion; `failed` says why it could not.
    func open(_ device: DeviceDescriptor, rateHz: Double?, failed: @escaping @MainActor (String) -> Void)
    func close(_ device: DeviceDescriptor)
    func keyframe(_ device: DeviceDescriptor)
    func rumble(_ device: DeviceDescriptor, strong: Double, weak: Double, ms: Int)
    /// Everything stops: the connection is gone.
    func detach()
}

/// The phone's side of docs/devices.md for one display connection at a time: offers the
/// hardware the owner allows (`devices`), runs what the computer opens, sends the battery and
/// the on-screen controller, and keeps what the computer made of each device for the
/// settings and the in-use indicator.
@MainActor @Observable
public final class DeviceCenter {
    /// What the owner allows for the computer paired now. Changing it offers the new set at
    /// once and stops whatever is no longer offered.
    public var permissions: DevicePermissions {
        didSet { if permissions != oldValue { refresh() } }
    }
    /// The devices offered on the connection now.
    public private(set) var offered: [DeviceDescriptor] = []
    /// What the computer made of each offered device, by id.
    public private(set) var status: [String: DeviceState] = [:]
    /// The devices a computer application is using now, by id.
    public private(set) var inUse: [String: DeviceKind] = [:]
    /// Why the phone could not run a device the computer opened, by id.
    public private(set) var failures: [String: String] = [:]
    /// Whether a connection that accepts devices is attached.
    public private(set) var isAttached = false
    /// Whether the on-screen controller is offered as a gamepad (it is showing, set to Linux Controller).
    public private(set) var screenGamepadActive = false

    @ObservationIgnored private let backend: DeviceBackend?
    @ObservationIgnored private var output: DeviceOutput?
    @ObservationIgnored private var lastBattery: BatteryReport?
    @ObservationIgnored private var lastScreenReport: GamepadReport?

    public init(backend: DeviceBackend?, permissions: DevicePermissions = DevicePermissions()) {
        self.backend = backend
        self.permissions = permissions
        backend?.onChange = { [weak self] in self?.refresh() }
        backend?.onButton = { [weak self] key, pressed in self?.button(key, pressed: pressed) }
    }

    /// The hardware this phone has.
    public var hardware: PhoneHardware? { backend?.hardware }

    /// The connection accepts devices: offer them, and the battery.
    public func attach(_ output: DeviceOutput) {
        detach()
        self.output = output
        isAttached = true
        backend?.attach(output)
        refresh()
    }

    /// The connection is gone: every source stops.
    public func detach() {
        guard isAttached else { return }
        backend?.detach()
        output = nil
        isAttached = false
        offered = []
        status = [:]
        inUse = [:]
        failures = [:]
        lastBattery = nil
        lastScreenReport = nil
    }

    public func handle(_ message: ServerMessage) {
        guard isAttached else { return }
        switch message {
        case .deviceStatus(let states):
            status = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        case .deviceOpen(let id, let rate):
            guard let device = offered.first(where: { $0.id == id }), [.camera, .depth, .microphone, .motion].contains(device.kind) else { return }
            inUse[id] = device.kind
            failures[id] = nil
            backend?.open(device, rateHz: rate) { [weak self] reason in self?.failed(id, reason) }
        case .deviceClose(let id):
            guard let device = offered.first(where: { $0.id == id }) else { return }
            inUse[id] = nil
            backend?.close(device)
        case .deviceKeyframe(let id):
            if let device = offered.first(where: { $0.id == id }) { backend?.keyframe(device) }
        case .deviceRumble(let id, let strong, let weak, let ms):
            guard let device = offered.first(where: { $0.id == id && $0.kind == .gamepad }) else { return }
            backend?.rumble(device, strong: min(1, max(0, strong)), weak: min(1, max(0, weak)), ms: max(0, ms))
        default:
            break
        }
    }

    // MARK: On-screen controller

    /// Offers the on-screen controller as a gamepad while it shows with the Linux Controller output.
    public func setScreenGamepad(_ active: Bool) {
        guard active != screenGamepadActive else { return }
        if !active, let output, lastScreenReport != nil {
            // Let go of what it held before the device goes.
            output.send(.deviceGamepad(device: ConnectedController.screenID, GamepadReport()))
        }
        screenGamepadActive = active
        lastScreenReport = nil
        refresh()
    }

    /// Whether the on-screen controller reaches the computer as a gamepad now.
    public var screenGamepadOffered: Bool { offered.contains { $0.id == ConnectedController.screenID } }

    /// The on-screen controller's state, sent when it changes.
    public func screenGamepad(_ state: GameGamepadState) {
        guard let output, screenGamepadOffered else { return }
        let report = GamepadReport(state)
        guard report != lastScreenReport else { return }
        lastScreenReport = report
        output.send(.deviceGamepad(device: ConnectedController.screenID, report))
    }

    // MARK: Buttons

    /// The Action button, through its App Intent: a press and release of `action`. False when
    /// no connected computer takes it.
    @discardableResult
    public func pressAction() -> Bool {
        guard buttonOffered(.action) else { return false }
        button(.action, pressed: true)
        button(.action, pressed: false)
        return true
    }

    private func buttonOffered(_ key: DeviceKey) -> Bool {
        output != nil && offered.contains { $0.kind == .buttons && $0.keys?.contains(key) == true }
    }

    private func button(_ key: DeviceKey, pressed: Bool) {
        guard buttonOffered(key), let output, let device = offered.first(where: { $0.kind == .buttons }) else { return }
        output.send(.deviceButton(device: device.id, key: key, pressed: pressed))
    }

    // MARK: Offering

    private func failed(_ id: String, _ reason: String) {
        guard isAttached, offered.contains(where: { $0.id == id }) else { return }
        failures[id] = reason
        inUse[id] = nil
        output?.send(.deviceError(device: id, reason: reason))
    }

    /// Offers what the owner allows now, if it changed, stops what is no longer offered and
    /// sends the battery when it changed.
    func refresh() {
        guard isAttached, let output, let backend else { return }
        var controllers = backend.controllers
        if screenGamepadActive {
            controllers.insert(ConnectedController(id: ConnectedController.screenID, name: "\(backend.hardware.model) On-Screen Controller",
                                                   rumble: true), at: 0)
        }
        let next = DeviceCatalog.descriptors(hardware: backend.hardware, permissions: permissions, controllers: controllers)
        if next != offered {
            let kept = Set(next.map(\.id))
            for device in offered where !kept.contains(device.id) {
                if inUse[device.id] != nil { backend.close(device) }
                inUse[device.id] = nil
                failures[device.id] = nil
                status[device.id] = nil
            }
            // A device whose description changed is restarted when the computer opens it again.
            for device in offered where kept.contains(device.id) && !next.contains(device) && inUse[device.id] != nil {
                backend.close(device)
                inUse[device.id] = nil
            }
            offered = next
            backend.offer(next)
            output.send(.devices(next))
            lastBattery = nil
        }
        if let battery = offered.first(where: { $0.kind == .battery }), let report = backend.battery, report != lastBattery {
            lastBattery = report
            output.send(.deviceBattery(device: battery.id, report))
        }
    }
}
