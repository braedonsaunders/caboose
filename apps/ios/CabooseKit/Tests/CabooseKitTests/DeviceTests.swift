import Foundation
import Testing
@testable import CabooseKit

/// The phone's side of docs/devices.md that does not need the hardware: what is offered,
/// how readings are converted and batched, and how `DeviceCenter` answers the computer.
@Suite struct DeviceTests {
    static let phone = PhoneHardware(
        model: "iPhone",
        cameras: [.init(position: .back, lens: .wide), .init(position: .back, lens: .ultraWide), .init(position: .front, lens: .wide)],
        depth: .init(position: .back, width: 256, height: 192, fps: 15),
        microphone: true, motion: [.accelerometer, .gyroscope, .magnetometer, .rotation, .pressure],
        buttons: [.volumeUp, .camera, .action], battery: true)

    // MARK: What is offered

    @Test func camerasAndMicrophoneNeedConsent() {
        let offered = DeviceCatalog.descriptors(hardware: Self.phone, permissions: DevicePermissions(), controllers: [])
        #expect(offered.map(\.id) == ["motion", "buttons", "battery"])
        #expect(offered[0] == DeviceDescriptor(id: "motion", kind: .motion, name: "iPhone Motion Sensors",
                                               sensors: [.accelerometer, .gyroscope, .magnetometer, .rotation, .pressure]))
        #expect(offered[1].keys == [.volumeUp, .camera, .action])
    }

    @Test func everythingAllowedIsOfferedInOrder() {
        let all = DevicePermissions(cameras: true, microphone: true)
        let pad = ConnectedController(id: "gamepad-1", name: "Xbox Wireless Controller", rumble: true)
        let offered = DeviceCatalog.descriptors(hardware: Self.phone, permissions: all, controllers: [pad])
        #expect(offered.map(\.id) == ["camera-back", "camera-back-ultra-wide", "camera-front", "depth", "microphone", "motion",
                                      "gamepad-1", "buttons", "battery"])
        #expect(offered.map(\.name).prefix(4) == ["iPhone Back Camera", "iPhone Ultra Wide Camera", "iPhone Front Camera", "iPhone Depth"])
        #expect(offered[0].size?.width == 1280 && offered[0].size?.height == 720 && offered[0].fps == 30 && offered[0].position == .back)
        #expect(offered[3].size?.width == 256 && offered[3].fps == 15)
        #expect(offered[6] == DeviceDescriptor(id: "gamepad-1", kind: .gamepad, name: "Xbox Wireless Controller", rumble: true))
        #expect(offered.allSatisfy { DeviceDescriptor.isValidID($0.id) })
    }

    @Test func nothingIsOfferedWithoutPermission() {
        #expect(DeviceCatalog.descriptors(hardware: Self.phone, permissions: .none, controllers: []).isEmpty)
    }

    @Test func namesAreCleaned() {
        #expect(DeviceCatalog.name("  Pad\u{0007}  ") == "Pad")
        #expect(DeviceCatalog.name("") == "Controller")
        #expect(DeviceCatalog.name(String(repeating: "x", count: 80)).count == 64)
    }

    @Test func idsHaveTheContractsForm() {
        #expect(DeviceDescriptor.isValidID("camera-back-ultra-wide"))
        #expect(!DeviceDescriptor.isValidID(""))
        #expect(!DeviceDescriptor.isValidID("Camera"))
        #expect(!DeviceDescriptor.isValidID(String(repeating: "a", count: 33)))
    }

    @Test func controllersKeepTheirSlots() {
        var slots = ControllerSlots<Int>()
        #expect(slots.id(for: 10) == "gamepad-1")
        #expect(slots.id(for: 20) == "gamepad-2")
        #expect(slots.id(for: 10) == "gamepad-1")
        slots.remove(10)
        #expect(slots.id(for: 30) == "gamepad-1")
        slots.keep(only: [30])
        #expect(slots.id(for: 20) == "gamepad-2")
    }

    // MARK: Conversions

    @Test func gamepadStateBecomesAReport() {
        var state = GameGamepadState()
        state[.south] = 1
        state[.start] = 0.9
        state[.up] = 1
        state[.north] = 0.4 // not past half its travel
        state[.leftX] = 0.5
        state[.leftY] = -1 // up, in the standard mapping
        state[.rightY] = 2 // out of range
        state[.leftTrigger] = 0.25
        state[.rightTrigger] = .nan
        let report = GamepadReport(state)
        #expect(report.buttons == GamepadReport.Bit.south.mask | GamepadReport.Bit.menu.mask | GamepadReport.Bit.dpadUp.mask)
        #expect(report.axes == [0.5, 1, 0, -1, 0.25, 0])
        #expect(GamepadReport(GameGamepadState()) == GamepadReport())
    }

    @Test func accelerationFollowsLinux() {
        // Face up, Core Motion reads z = −1 g; Linux reads +9.80665 m/s².
        #expect(MotionUnits.linuxAcceleration(g: (0, 0, -1)) == [0, 0, 9.80665])
        #expect(MotionUnits.linuxAcceleration(g: (0.5, -1, 0)) == [-4.903325, 9.80665, 0])
        #expect(MotionUnits.rate(for: nil) == 100)
        #expect(MotionUnits.rate(for: 400) == 100)
        #expect(MotionUnits.rate(for: 0.2) == 1)
        #expect(MotionUnits.rate(for: 50) == 50)
    }

    @Test func motionIsBatchedEvery20ms() {
        var batcher = MotionBatcher()
        #expect(batcher.add(MotionSample(micros: 1_000_000, accel: [0, 0, 9.8])) == nil)
        batcher.pressure(101.2)
        #expect(batcher.add(MotionSample(micros: 1_010_000)) == nil)
        let batch = batcher.add(MotionSample(micros: 1_020_000))
        #expect(batch?.map(\.micros) == [1_000_000, 1_010_000, 1_020_000])
        #expect(batch?[1].pressure == 101.2 && batch?[2].pressure == nil)
        #expect(batcher.flush().isEmpty)
    }

    @Test func aFullBatchGoesAtOnce() {
        var batcher = MotionBatcher()
        var sent: [[MotionSample]] = []
        for index in 0 ..< MotionBatcher.maxSamples {
            if let batch = batcher.add(MotionSample(micros: UInt64(index))) { sent.append(batch) }
        }
        #expect(sent.count == 1 && sent[0].count == MotionBatcher.maxSamples)
    }

    @Test func lengthPrefixedBecomesAnnexB() {
        let sps = Data([0x67, 0x42]), pps = Data([0x68, 0xCE])
        let avcc = Data([0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 1, 0x06])
        #expect(AnnexB.from(lengthPrefixed: avcc, parameterSets: [sps, pps])
            == Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x06]))
        #expect(AnnexB.from(lengthPrefixed: Data([0, 2, 0x41, 0x9A]), lengthSize: 2) == Data([0, 0, 0, 1, 0x41, 0x9A]))
        #expect(AnnexB.from(lengthPrefixed: Data([0, 0, 0, 9, 0x65])) == nil)
    }

    @Test func pcmIsCutInto20msFrames() {
        var framer = PCMFramer()
        #expect(framer.append([Float](repeating: 0.1, count: 500), at: 1_000_000).isEmpty)
        let frames = framer.append([Float](repeating: 0.2, count: 1500), at: 1_010_416)
        #expect(frames.count == 2)
        #expect(frames[0].micros == 1_000_000 && frames[1].micros == 1_020_000)
        #expect(frames[0].samples.count == 960 && frames[0].samples[499] == 0.1 && frames[0].samples[500] == 0.2)
        // 80 samples wait for the next frame, timed from where they fall.
        #expect(framer.append([Float](repeating: 0, count: 920), at: 0).first?.micros == 1_040_000)
    }

    @Test func depthIsMillimetres() {
        #expect(DepthPicture.millimetres(fromMetres: [1, 1.5, .nan, 4, -1, 100]) == Data([0xE8, 0x03, 0xDC, 0x05, 0, 0, 0xA0, 0x0F, 0, 0, 0xFF, 0xFF]))
    }

    @Test func opusEncodesWhatOpusDecodes() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder(channels: 1)
        let tone = (0 ..< PCMFramer.frameSamples).map { Float(sin(Double($0) * 2 * .pi * 440 / PCMFramer.sampleRate) * 0.5) }
        var heard: Float = 0
        var packets = 0
        for _ in 0 ..< 8 {
            guard let packet = try encoder.encode(tone) else { continue }
            packets += 1
            #expect(!packet.isEmpty && packet.count < 400)
            let pcm = try decoder.decode(packet)
            let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
            heard = max(heard, samples.map(abs).max() ?? 0)
        }
        #expect(packets >= 6)
        #expect(heard > 0.2)
        #expect(throws: OpusEncoder.Failure.self) { _ = try encoder.encode([0, 0]) }
    }

    // MARK: DeviceCenter

    @MainActor final class FakeBackend: DeviceBackend {
        var hardware = DeviceTests.phone
        var controllers: [ConnectedController] = []
        var screenRumble = true
        var battery: BatteryReport? = BatteryReport(level: 0.5, charging: false, full: false, lowPower: false, thermal: .nominal)
        var onChange: (() -> Void)?
        var onButton: ((DeviceKey, Bool) -> Void)?
        var log: [String] = []
        var failOpen: String?
        var failures: [@MainActor (String) -> Void] = []

        func attach(_ output: DeviceOutput) { log.append("attach") }
        func offer(_ devices: [DeviceDescriptor]) { log.append("offer \(devices.count)") }
        func open(_ device: DeviceDescriptor, rateHz: Double?, failed: @escaping @MainActor (String) -> Void) {
            log.append("open \(device.id) \(rateHz.map { "\($0)" } ?? "-")")
            failures.append(failed)
            if let failOpen { failed(failOpen) }
        }
        func close(_ device: DeviceDescriptor) { log.append("close \(device.id)") }
        func keyframe(_ device: DeviceDescriptor) { log.append("keyframe \(device.id)") }
        func rumble(_ device: DeviceDescriptor, strong: Double, weak: Double, ms: Int) { log.append("rumble \(device.id) \(strong) \(weak) \(ms)") }
        func detach() { log.append("detach") }
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DisplayFrame] = []
        func append(_ message: ClientMessage) { lock.withLock { frames.append(message.frame) } }
        var types: [UInt8] { lock.withLock { frames.map(\.type) } }
        var all: [DisplayFrame] { lock.withLock { frames } }
        func clear() { lock.withLock { frames.removeAll() } }
    }

    @MainActor private func attached(_ permissions: DevicePermissions = DevicePermissions()) -> (DeviceCenter, FakeBackend, Sent) {
        let backend = FakeBackend()
        let center = DeviceCenter(backend: backend, permissions: permissions)
        let sent = Sent()
        center.attach(DeviceOutput(send: { sent.append($0) }))
        return (center, backend, sent)
    }

    @MainActor @Test func attachingOffersDevicesThenTheBattery() {
        let (center, backend, sent) = attached()
        #expect(sent.types == [0xB0, 0xB7])
        #expect(center.offered.map(\.id) == ["motion", "buttons", "battery"])
        #expect(backend.log == ["attach", "offer 3"])
        #expect(sent.all[1].body["level"] == .double(0.5) && sent.all[1].body["device"] == "battery")
    }

    @MainActor @Test func theBatteryIsSentOnlyWhenItChanges() {
        let (center, backend, sent) = attached()
        defer { withExtendedLifetime(center) {} }
        sent.clear()
        backend.onChange?()
        #expect(sent.types.isEmpty)
        backend.battery?.charging = true
        backend.onChange?()
        #expect(sent.types == [0xB7])
    }

    @MainActor @Test func openAndCloseReachTheHardware() {
        let (center, backend, _) = attached()
        center.handle(.deviceOpen(device: "motion", rateHz: 60))
        #expect(center.inUse == ["motion": .motion])
        center.handle(.deviceOpen(device: "camera-back", rateHz: nil)) // not offered
        center.handle(.deviceOpen(device: "battery", rateHz: nil)) // nothing to open
        center.handle(.deviceClose(device: "motion"))
        #expect(center.inUse.isEmpty)
        #expect(backend.log.suffix(2) == ["open motion 60.0", "close motion"])
    }

    @MainActor @Test func aRefusalIsSentAsAnError() {
        let (center, backend, sent) = attached(DevicePermissions(cameras: true))
        backend.failOpen = "Camera access is off for Caboose in Settings."
        sent.clear()
        center.handle(.deviceOpen(device: "camera-front", rateHz: nil))
        #expect(sent.types == [0xB8])
        #expect(sent.all[0].body["reason"] == "Camera access is off for Caboose in Settings.")
        #expect(center.failures["camera-front"] != nil && center.inUse.isEmpty)
    }

    @MainActor @Test func withdrawingPermissionStopsWhatRuns() {
        let (center, backend, sent) = attached(DevicePermissions(cameras: true))
        center.handle(.deviceOpen(device: "camera-back", rateHz: nil))
        sent.clear()
        center.permissions.cameras = false
        #expect(backend.log.contains("close camera-back"))
        #expect(center.inUse.isEmpty)
        #expect(sent.types.first == 0xB0)
        #expect(!center.offered.contains { $0.kind == .camera })
    }

    @MainActor @Test func statusAndRumbleAndKeyframes() {
        let (center, backend, _) = attached(DevicePermissions(cameras: true))
        center.handle(.deviceStatus([DeviceState(id: "battery", nodes: [], error: "no UHID")]))
        #expect(center.status["battery"]?.error == "no UHID")
        center.handle(.deviceKeyframe(device: "camera-back"))
        center.setScreenGamepad(true)
        center.handle(.deviceRumble(device: ConnectedController.screenID, strong: 2, weak: 0.5, ms: 100))
        #expect(backend.log.contains("keyframe camera-back"))
        #expect(backend.log.contains("rumble gamepad-screen 1.0 0.5 100"))
    }

    @MainActor @Test func theOnScreenControllerIsAGamepadWhileActive() {
        let (center, _, sent) = attached()
        center.screenGamepad(GameGamepadState())
        #expect(!sent.types.contains(0xB5))
        center.setScreenGamepad(true)
        #expect(center.offered.contains { $0.id == "gamepad-screen" })
        #expect(center.offered.first { $0.id == "gamepad-screen" }?.name == "iPhone On-Screen Controller")
        sent.clear()
        var state = GameGamepadState()
        state[.east] = 1
        center.screenGamepad(state)
        center.screenGamepad(state) // unchanged: not sent again
        #expect(sent.types == [0xB5])
        sent.clear()
        center.setScreenGamepad(false)
        // Released first, then the device goes; the battery follows every new set.
        #expect(sent.types == [0xB5, 0xB0, 0xB7])
        #expect(sent.all[0].body["buttons"] == 0)
    }

    @MainActor @Test func theActionButtonPressesAndReleases() {
        let (center, _, sent) = attached()
        sent.clear()
        #expect(center.pressAction())
        #expect(sent.all.map { $0.body["pressed"] } == [.bool(true), .bool(false)])
        #expect(sent.all.allSatisfy { $0.body["key"] == "action" })
        center.permissions.buttons = false
        sent.clear()
        #expect(!center.pressAction())
        #expect(sent.types == [])
    }

    @MainActor @Test func staleFailuresCannotAffectReopenedDevices() {
        let (center, backend, sent) = attached()
        center.handle(.deviceOpen(device: "motion", rateHz: nil))
        let oldFailure = backend.failures.last!
        center.detach()
        center.attach(DeviceOutput(send: { sent.append($0) }))
        center.handle(.deviceOpen(device: "motion", rateHz: nil))
        sent.clear()
        oldFailure("Old connection failed")
        #expect(center.inUse["motion"] == .motion)
        #expect(center.failures.isEmpty && sent.types.isEmpty)
        center.handle(.deviceClose(device: "motion"))
        backend.failures.last?("Closed capture failed")
        #expect(center.failures.isEmpty && sent.types.isEmpty)
    }

    @MainActor @Test func detachingStopsEverything() {
        let (center, backend, sent) = attached()
        center.handle(.deviceOpen(device: "motion", rateHz: nil))
        center.detach()
        #expect(backend.log.last == "detach")
        #expect(center.offered.isEmpty && center.inUse.isEmpty && !center.isAttached)
        sent.clear()
        center.handle(.deviceOpen(device: "motion", rateHz: nil))
        backend.onChange?()
        #expect(sent.types.isEmpty)
    }
}
