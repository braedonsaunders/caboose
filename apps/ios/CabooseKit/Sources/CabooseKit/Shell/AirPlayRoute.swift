import Foundation

/// An AirPlay device the phone played to, as the audio session reports it.
public struct AirPlayRoute: Codable, Equatable, Sendable {
    /// The port's identifier; stable for one device across connections.
    public var uid: String
    /// The device's name, such as "Living Room".
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    /// One output of the current route: its port type (`AVAudioSession.Port` raw value), uid and name.
    public struct Output: Equatable, Sendable {
        public var type: String
        public var uid: String
        public var name: String
        public init(type: String, uid: String, name: String) {
            self.type = type
            self.uid = uid
            self.name = name
        }
    }

    /// The `AVAudioSession.Port.airPlay` raw value.
    public static let portType = "AirPlay"

    /// The AirPlay device among a route's outputs, if the route is playing to one.
    public static func active(in outputs: [Output]) -> AirPlayRoute? {
        outputs.first { $0.type == portType && !$0.uid.isEmpty }.map { AirPlayRoute(uid: $0.uid, name: $0.name) }
    }

    /// The device to remember after a route change: the one playing now, else the one
    /// remembered before. Leaving AirPlay never forgets the last device.
    public static func remembered(after outputs: [Output], previous: AirPlayRoute?) -> AirPlayRoute? {
        active(in: outputs) ?? previous
    }
}
