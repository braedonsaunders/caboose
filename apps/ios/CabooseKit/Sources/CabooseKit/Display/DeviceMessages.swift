import Foundation

// The phone's hardware as the computer's devices (docs/devices.md): what the phone offers
// (`devices`), what it captures (`device.*` client messages) and what the computer asks of it
// (`device.*` server messages).

public enum DeviceKind: String, Sendable, CaseIterable {
    case camera, depth, microphone, motion, gamepad, buttons, battery
}

public enum CameraPosition: String, Sendable {
    case back, front, external
}

public enum MotionSensor: String, Sendable, CaseIterable {
    case accelerometer, gyroscope, magnetometer, rotation, pressure
}

public enum DeviceKey: String, Sendable, CaseIterable {
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case camera
    case action
}

public enum ThermalState: String, Sendable {
    case nominal, fair, serious, critical
}

/// One device in `devices`. The kind-specific fields are present for the kinds that have them.
public struct DeviceDescriptor: Equatable, Sendable {
    public var id: String
    public var kind: DeviceKind
    /// What Linux shows, 1–64 characters.
    public var name: String
    public var position: CameraPosition?
    /// The picture size the phone sends, in pixels.
    public var size: (width: Int, height: Int)?
    public var fps: Double?
    public var sensors: [MotionSensor]?
    public var rumble: Bool?
    public var keys: [DeviceKey]?

    public init(id: String, kind: DeviceKind, name: String, position: CameraPosition? = nil, size: (width: Int, height: Int)? = nil,
                fps: Double? = nil, sensors: [MotionSensor]? = nil, rumble: Bool? = nil, keys: [DeviceKey]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.position = position
        self.size = size
        self.fps = fps
        self.sensors = sensors
        self.rumble = rumble
        self.keys = keys
    }

    public static func == (a: DeviceDescriptor, b: DeviceDescriptor) -> Bool {
        a.id == b.id && a.kind == b.kind && a.name == b.name && a.position == b.position
            && a.size?.width == b.size?.width && a.size?.height == b.size?.height && a.fps == b.fps
            && a.sensors == b.sensors && a.rumble == b.rumble && a.keys == b.keys
    }

    /// `^[a-z0-9-]{1,32}$`, the form the contract requires of an id.
    public static func isValidID(_ id: String) -> Bool {
        (1 ... 32).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [("id", CBOR(id)), ("kind", CBOR(kind.rawValue)), ("name", CBOR(name))]
        if let position { pairs.append(("position", CBOR(position.rawValue))) }
        if let size { pairs.append(("size", [CBOR(size.width), CBOR(size.height)])) }
        if let fps { pairs.append(("fps", CBOR(fps))) }
        if let sensors { pairs.append(("sensors", .array(sensors.map { CBOR($0.rawValue) }))) }
        if let rumble { pairs.append(("rumble", CBOR(rumble))) }
        if let keys { pairs.append(("keys", .array(keys.map { CBOR($0.rawValue) }))) }
        return .map(pairs.map { (.text($0.0), $0.1) })
    }

    /// Nil for a malformed device or one of a kind this version does not know; names in
    /// `sensors` and `keys` this version does not know are dropped.
    public init?(_ body: CBOR) {
        guard let id = body["id"]?.string, let kind = body["kind"]?.string.flatMap(DeviceKind.init(rawValue:)),
              let name = body["name"]?.string else { return nil }
        self.init(id: id, kind: kind, name: name)
        position = body["position"]?.string.flatMap(CameraPosition.init(rawValue:))
        size = body["size"]?.ints.flatMap { $0.count == 2 ? (width: $0[0], height: $0[1]) : nil }
        fps = body["fps"]?.double
        sensors = body["sensors"]?.array.map { $0.compactMap { $0.string.flatMap(MotionSensor.init(rawValue:)) } }
        rumble = body["rumble"]?.bool
        keys = body["keys"]?.array.map { $0.compactMap { $0.string.flatMap(DeviceKey.init(rawValue:)) } }
    }
}

/// One reading in `device.motion`, in the phone's portrait axes and Linux's conventions:
/// acceleration in m/s² with gravity (face up reads `z = +9.81`), angular velocity in rad/s,
/// the calibrated field in µT, the attitude quaternion `[x, y, z, w]`, pressure in kPa.
public struct MotionSample: Equatable, Sendable {
    public var micros: UInt64
    public var accel: [Double]?
    public var gyro: [Double]?
    public var magnet: [Double]?
    public var rotation: [Double]?
    public var pressure: Double?

    public init(micros: UInt64, accel: [Double]? = nil, gyro: [Double]? = nil, magnet: [Double]? = nil,
                rotation: [Double]? = nil, pressure: Double? = nil) {
        self.micros = micros
        self.accel = accel
        self.gyro = gyro
        self.magnet = magnet
        self.rotation = rotation
        self.pressure = pressure
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [("t_us", CBOR(micros))]
        if let accel { pairs.append(("accel", .array(accel.map { CBOR($0) }))) }
        if let gyro { pairs.append(("gyro", .array(gyro.map { CBOR($0) }))) }
        if let magnet { pairs.append(("magnet", .array(magnet.map { CBOR($0) }))) }
        if let rotation { pairs.append(("rotation", .array(rotation.map { CBOR($0) }))) }
        if let pressure { pairs.append(("pressure", CBOR(pressure))) }
        return .map(pairs.map { (.text($0.0), $0.1) })
    }
}

/// A gamepad's whole state in `device.gamepad`.
public struct GamepadReport: Equatable, Sendable {
    /// The pressed set, `GamepadReport.Bit`s.
    public var buttons: Int
    /// Left x, left y, right x, right y (−1…1, up and right positive), left and right trigger (0…1).
    public var axes: [Double]

    public enum Bit: Int, CaseIterable, Sendable {
        case south, east, west, north, leftShoulder, rightShoulder, view, menu, home, leftStick, rightStick
        case dpadUp, dpadDown, dpadLeft, dpadRight
        public var mask: Int { 1 << rawValue }
    }

    public init(buttons: Int = 0, axes: [Double] = [0, 0, 0, 0, 0, 0]) {
        self.buttons = buttons
        self.axes = axes
    }
}

/// The phone's battery and how hot it runs, in `device.battery`.
public struct BatteryReport: Equatable, Sendable {
    /// 0…1.
    public var level: Double
    public var charging: Bool
    public var full: Bool
    public var lowPower: Bool
    public var thermal: ThermalState

    public init(level: Double, charging: Bool, full: Bool, lowPower: Bool, thermal: ThermalState) {
        self.level = level
        self.charging = charging
        self.full = full
        self.lowPower = lowPower
        self.thermal = thermal
    }
}

/// What one offered device became in the computer (`device.status`).
public struct DeviceState: Equatable, Sendable {
    public var id: String
    /// The Linux nodes or source it became.
    public var nodes: [String]
    /// Why it could not be created.
    public var error: String?

    public init(id: String, nodes: [String], error: String? = nil) {
        self.id = id
        self.nodes = nodes
        self.error = error
    }

    init?(_ body: CBOR) {
        guard let id = body["id"]?.string else { return nil }
        self.init(id: id, nodes: body["nodes"]?.array?.compactMap(\.string) ?? [], error: body["error"]?.string)
    }
}
