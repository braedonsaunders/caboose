import Foundation

/// What the owner lets the computer use, for the computer the phone is paired with now.
public struct DevicePermissions: Equatable, Sendable {
    public var cameras: Bool
    public var microphone: Bool
    public var motion: Bool
    public var controllers: Bool
    public var buttons: Bool
    public var battery: Bool

    public init(cameras: Bool = false, microphone: Bool = false, motion: Bool = true, controllers: Bool = true,
                buttons: Bool = true, battery: Bool = true) {
        self.cameras = cameras
        self.microphone = microphone
        self.motion = motion
        self.controllers = controllers
        self.buttons = buttons
        self.battery = battery
    }

    /// Nothing is offered.
    public static let none = DevicePermissions(cameras: false, microphone: false, motion: false, controllers: false, buttons: false, battery: false)
}

/// The hardware this phone has, as the computer may see it.
public struct PhoneHardware: Equatable, Sendable {
    public enum Lens: String, Sendable {
        case wide, ultraWide, telephoto
    }

    public struct Camera: Equatable, Sendable {
        public var position: CameraPosition
        public var lens: Lens

        public init(position: CameraPosition, lens: Lens) {
            self.position = position
            self.lens = lens
        }

        /// `camera-back`, `camera-back-ultra-wide`, `camera-front` …: the same for the same
        /// camera on every connection.
        public var id: String {
            switch lens {
            case .wide: "camera-\(position.rawValue)"
            case .ultraWide: "camera-\(position.rawValue)-ultra-wide"
            case .telephoto: "camera-\(position.rawValue)-telephoto"
            }
        }

        func name(model: String) -> String {
            switch (position, lens) {
            case (.front, .wide): "\(model) Front Camera"
            case (.front, .ultraWide): "\(model) Front Ultra Wide Camera"
            case (.front, .telephoto): "\(model) Front Telephoto Camera"
            case (_, .wide): "\(model) Back Camera"
            case (_, .ultraWide): "\(model) Ultra Wide Camera"
            case (_, .telephoto): "\(model) Telephoto Camera"
            }
        }
    }

    /// The depth sensor and the picture size it gives.
    public struct Depth: Equatable, Sendable {
        public var position: CameraPosition
        public var width: Int
        public var height: Int
        public var fps: Double

        public init(position: CameraPosition, width: Int, height: Int, fps: Double) {
            self.position = position
            self.width = width
            self.height = height
            self.fps = fps
        }
    }

    /// "iPhone" or "iPad", the start of every device's name.
    public var model: String
    public var cameras: [Camera]
    public var depth: Depth?
    public var microphone: Bool
    public var motion: [MotionSensor]
    public var buttons: [DeviceKey]
    public var battery: Bool

    public init(model: String, cameras: [Camera] = [], depth: Depth? = nil, microphone: Bool = false, motion: [MotionSensor] = [],
                buttons: [DeviceKey] = [], battery: Bool = false) {
        self.model = model
        self.cameras = cameras
        self.depth = depth
        self.microphone = microphone
        self.motion = motion
        self.buttons = buttons
        self.battery = battery
    }
}

/// A game controller the computer sees: one paired with the phone, or the on-screen one.
public struct ConnectedController: Equatable, Sendable {
    public var id: String
    public var name: String
    public var rumble: Bool

    public init(id: String, name: String, rumble: Bool) {
        self.id = id
        self.name = name
        self.rumble = rumble
    }

    /// The on-screen controller's id.
    public static let screenID = "gamepad-screen"
}

/// The `devices` a phone offers: its hardware, as far as the owner allows.
public enum DeviceCatalog {
    /// The picture size and rate cameras are sent at.
    public static let cameraSize = (width: 1280, height: 720)
    public static let cameraFPS = 30.0

    public static func descriptors(hardware: PhoneHardware, permissions: DevicePermissions,
                                   controllers: [ConnectedController]) -> [DeviceDescriptor] {
        let model = hardware.model
        var devices: [DeviceDescriptor] = []
        if permissions.cameras {
            for camera in hardware.cameras {
                devices.append(DeviceDescriptor(id: camera.id, kind: .camera, name: name(camera.name(model: model)),
                                                position: camera.position, size: cameraSize, fps: cameraFPS))
            }
            if let depth = hardware.depth {
                devices.append(DeviceDescriptor(id: "depth", kind: .depth, name: name("\(model) Depth"), position: depth.position,
                                                size: (depth.width, depth.height), fps: depth.fps))
            }
        }
        if permissions.microphone, hardware.microphone {
            devices.append(DeviceDescriptor(id: "microphone", kind: .microphone, name: name("\(model) Microphone")))
        }
        if permissions.motion, !hardware.motion.isEmpty {
            devices.append(DeviceDescriptor(id: "motion", kind: .motion, name: name("\(model) Motion Sensors"), sensors: hardware.motion))
        }
        if permissions.controllers {
            for controller in controllers where DeviceDescriptor.isValidID(controller.id) {
                devices.append(DeviceDescriptor(id: controller.id, kind: .gamepad, name: name(controller.name), rumble: controller.rumble))
            }
        }
        if permissions.buttons, !hardware.buttons.isEmpty {
            devices.append(DeviceDescriptor(id: "buttons", kind: .buttons, name: name("\(model) Buttons"), keys: hardware.buttons))
        }
        if permissions.battery, hardware.battery {
            devices.append(DeviceDescriptor(id: "battery", kind: .battery, name: name("\(model) Battery")))
        }
        return Array(devices.prefix(32))
    }

    /// A name Linux can show: control characters out, 1–64 characters.
    static func name(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Controller" : String(cleaned.prefix(64))
    }
}

/// Keeps a stable `gamepad-N` id for each connected controller: a controller keeps its id
/// while it stays connected, and a new one takes the lowest free number.
public struct ControllerSlots<Key: Hashable>: Sendable where Key: Sendable {
    private var slots: [Key: Int] = [:]

    public init() {}

    public mutating func id(for key: Key) -> String {
        if let slot = slots[key] { return "gamepad-\(slot)" }
        let used = Set(slots.values)
        let slot = (1...).first { !used.contains($0) }!
        slots[key] = slot
        return "gamepad-\(slot)"
    }

    public mutating func remove(_ key: Key) { slots[key] = nil }

    public mutating func keep(only keys: Set<Key>) { slots = slots.filter { keys.contains($0.key) } }
}
