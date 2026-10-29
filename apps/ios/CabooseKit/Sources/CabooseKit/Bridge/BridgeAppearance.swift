import Foundation

/// The phone's appearance as the computer applies it (`PUT /v1/bridge/appearance`).
public struct BridgeAppearance: Equatable, Encodable, Sendable {
    public enum Scheme: String, Encodable, Sendable { case light, dark }
    public enum Contrast: String, Encodable, Sendable { case normal, high }

    public let colorScheme: Scheme
    /// `#RRGGBB`.
    public let accent: String
    public let contrast: Contrast
    public let reducedMotion: Bool
    /// The text size relative to the phone's default, 0.75 to 2.
    public let textScale: Double

    public init(dark: Bool, accent red: Double, _ green: Double, _ blue: Double, highContrast: Bool, reducedMotion: Bool, contentSize: String) {
        colorScheme = dark ? .dark : .light
        accent = Self.hex(red, green, blue)
        contrast = highContrast ? .high : .normal
        self.reducedMotion = reducedMotion
        textScale = Self.textScale(contentSize: contentSize)
    }

    /// sRGB components 0–1 as `#RRGGBB`, clamped.
    public static func hex(_ red: Double, _ green: Double, _ blue: Double) -> String {
        let byte = { (value: Double) in Int((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The Dynamic Type size (a `UIContentSizeCategory` raw value) as a text scale, the
    /// default (Large) being 1. Accessibility sizes are capped at 2.
    public static func textScale(contentSize: String) -> Double {
        let scales: [String: Double] = [
            "UICTContentSizeCategoryXS": 0.8, "UICTContentSizeCategoryS": 0.85, "UICTContentSizeCategoryM": 0.92,
            "UICTContentSizeCategoryL": 1.0, "UICTContentSizeCategoryXL": 1.1, "UICTContentSizeCategoryXXL": 1.2,
            "UICTContentSizeCategoryXXXL": 1.3, "UICTContentSizeCategoryAccessibilityM": 1.5,
            "UICTContentSizeCategoryAccessibilityL": 1.65, "UICTContentSizeCategoryAccessibilityXL": 1.8,
            "UICTContentSizeCategoryAccessibilityXXL": 1.9, "UICTContentSizeCategoryAccessibilityXXXL": 2.0,
        ]
        return scales[contentSize] ?? 1.0
    }
}

/// The track shown in the computer's Now Playing (`now-playing.changed`).
public struct BridgeNowPlaying: Equatable, Decodable, Sendable {
    public let id: String
    public let player: String
    public let title: String
    public let artist: String
    public let album: String
    public let artwork: URL?
    public let position: Double
    public let duration: Double?
    public let paused: Bool
    public let rate: Double
    public let canPlay: Bool
    public let canPause: Bool
    public let canNext: Bool
    public let canPrevious: Bool
    public let canSeek: Bool
    /// Milliseconds since the epoch, host clock: when `position` held.
    public let updatedAt: Double

    private enum Keys: String, CodingKey {
        case id, player, title, artist, album, artwork, position, duration, paused, rate, canPlay, canPause, canNext, canPrevious, canSeek, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        player = try c.decode(String.self, forKey: .player)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        let art = try c.decodeIfPresent(String.self, forKey: .artwork)
        artwork = art.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        position = try c.decode(Double.self, forKey: .position)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        paused = try c.decode(Bool.self, forKey: .paused)
        rate = try c.decode(Double.self, forKey: .rate)
        canPlay = try c.decode(Bool.self, forKey: .canPlay)
        canPause = try c.decode(Bool.self, forKey: .canPause)
        canNext = try c.decode(Bool.self, forKey: .canNext)
        canPrevious = try c.decode(Bool.self, forKey: .canPrevious)
        canSeek = try c.decode(Bool.self, forKey: .canSeek)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        let idValid = (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { b in
            (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 46 || b == 95 || b == 45
        }
        guard idValid, position.isFinite, position >= 0, duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              rate.isFinite, (0...16).contains(rate), updatedAt.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid now playing state"))
        }
    }

    /// The position at `now` (ms since the epoch), extrapolated while playing and capped at the duration.
    public func position(at now: Double) -> Double {
        var value = position + (paused ? 0 : rate * max(0, now - updatedAt) / 1000)
        if let duration, duration > 0 { value = min(value, duration) }
        return value
    }

    /// The rate Now Playing shows: 0 while paused.
    public var playbackRate: Double { paused ? 0 : rate }
}

/// When a location is worth sending: at most every 5 seconds (the host's limit), and only
/// when it moved meaningfully or a minute has passed.
public struct LocationThrottle: Sendable {
    public struct Fix: Equatable, Sendable {
        public let latitude: Double, longitude: Double, accuracy: Double
        public init(latitude: Double, longitude: Double, accuracy: Double) {
            self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
        }
    }

    private var last: (fix: Fix, at: Double)?

    public init() {}

    /// Whether to send `fix` at `now` (seconds); records it when so.
    public mutating func admit(_ fix: Fix, at now: Double) -> Bool {
        guard fix.latitude.isFinite, fix.longitude.isFinite, abs(fix.latitude) <= 90, abs(fix.longitude) <= 180,
              fix.accuracy >= 0, fix.accuracy <= 100_000 else { return false }
        if let last {
            let elapsed = now - last.at
            guard elapsed >= 5 else { return false }
            let moved = Self.distance(last.fix, fix)
            let improved = fix.accuracy < last.fix.accuracy * 0.5
            guard moved >= max(10, fix.accuracy / 2) || improved || elapsed >= 60 else { return false }
        }
        last = (fix, now)
        return true
    }

    public mutating func reset() { last = nil }

    /// Great-circle distance in metres.
    public static func distance(_ a: Fix, _ b: Fix) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
