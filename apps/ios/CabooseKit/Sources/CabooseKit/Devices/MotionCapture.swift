#if os(iOS)
import CoreMotion
import Foundation

/// The phone's motion for the computer: Core Motion's device motion (acceleration with
/// gravity, rotation rate, calibrated magnetic field and attitude) at the rate asked, at most
/// 100 Hz, and the barometer, batched every 20 ms into `device.motion`.
@MainActor
final class MotionCapture {
    var output: DeviceOutput?

    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var running: MotionRun?

    func open(_ device: DeviceDescriptor, rateHz: Double?, failed: @escaping @MainActor (String) -> Void) {
        guard let output else { return }
        guard manager.isDeviceMotionAvailable else { return failed("This device has no motion sensors.") }
        close()
        let run = MotionRun(device: device.id, output: output)
        running = run
        manager.deviceMotionUpdateInterval = 1 / MotionUnits.rate(for: rateHz)
        let frame: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryZVertical
        manager.startDeviceMotionUpdates(using: frame, to: run.queue) { motion, _ in
            if let motion { run.add(motion) }
        }
        if device.sensors?.contains(.pressure) == true, CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: run.queue) { data, _ in
                if let data { run.pressure(data.pressure.doubleValue) }
            }
        }
    }

    func close() {
        guard running != nil else { return }
        manager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        running?.finish()
        running = nil
    }
}

/// One motion stream, on its own serial queue.
final class MotionRun: @unchecked Sendable {
    let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let device: String
    private let output: DeviceOutput
    private var batcher = MotionBatcher()
    private var finished = false

    init(device: String, output: DeviceOutput) {
        self.device = device
        self.output = output
    }

    func add(_ motion: CMDeviceMotion) {
        guard !finished else { return }
        let gravity = motion.gravity, user = motion.userAcceleration
        let rate = motion.rotationRate
        let quaternion = motion.attitude.quaternion
        let field = motion.magneticField
        let sample = MotionSample(
            micros: UInt64(motion.timestamp * 1_000_000),
            accel: MotionUnits.linuxAcceleration(g: (gravity.x + user.x, gravity.y + user.y, gravity.z + user.z)),
            gyro: [rate.x, rate.y, rate.z],
            magnet: field.accuracy == .uncalibrated ? nil : [field.field.x, field.field.y, field.field.z],
            rotation: [quaternion.x, quaternion.y, quaternion.z, quaternion.w])
        if let batch = batcher.add(sample) { output.send(.deviceMotion(device: device, samples: batch)) }
    }

    /// Core Motion reports pressure in kPa, the computer's unit.
    func pressure(_ kilopascals: Double) {
        guard !finished else { return }
        batcher.pressure(kilopascals)
    }

    func finish() {
        queue.addOperation { [self] in
            finished = true
            let rest = batcher.flush()
            if !rest.isEmpty { output.send(.deviceMotion(device: device, samples: rest)) }
        }
    }
}
#endif
