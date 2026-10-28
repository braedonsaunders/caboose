import CryptoKit
import Foundation

/// What Caboose tells the Xpra server about itself in `hello`.
public struct ClientCapabilities: Sendable {
    public var desktopWidth: Int
    public var desktopHeight: Int
    public var dpi: Int
    public var refreshRate: Int
    public var uuid: String
    public var version: String
    public var keyboardLayout: String
    /// Xpra's authenticators identify the connecting user by name; the guest's user is `caboose`.
    public var username: String
    /// The encoding the server should prefer; "auto" lets it choose per region.
    public var preferredEncoding = "auto"

    public init(desktopWidth: Int, desktopHeight: Int, dpi: Int, refreshRate: Int = 60,
                uuid: String = UUID().uuidString, version: String = "6.5.5", keyboardLayout: String = "us",
                username: String = "caboose") {
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.dpi = dpi
        self.refreshRate = refreshRate
        self.uuid = uuid
        self.version = version
        self.keyboardLayout = keyboardLayout
        self.username = username
    }

    /// Encodings Caboose decodes natively: H.264 through VideoToolbox, stills through ImageIO.
    /// No "scroll": Xpra 6.5.5's scroll encoder calls queue_damage_packet without its options
    /// argument and raises, so every scroll it tried to send as a copy was lost instead.
    public static let encodings: [RValue] = ["h264", "jpeg", "png", "png/P", "png/L", "webp", "rgb32", "rgb24", "void"]

    static let metadataSupported: [RValue] = [
        "fullscreen", "maximized", "iconic", "above", "below", "title", "size-hints", "class-instance",
        "transient-for", "window-type", "has-alpha", "decorations", "override-redirect", "modal", "opacity",
        "icon-title", "command", "pid", "role",
    ]

    /// The `hello` capability dictionary. `challenge` marks a partial hello sent when the
    /// server is expected to ask for credentials first.
    public func hello(challengeResponse: String? = nil, clientSalt: String? = nil) -> RValue {
        let widthMM = desktopWidth * 254 / (dpi * 10), heightMM = desktopHeight * 254 / (dpi * 10)
        var caps: [RPair] = [
            pair("version", RValue(version)),
            pair("protocol-version", [7, 0]),
            pair("client_type", "Caboose"),
            pair("uuid", RValue(uuid)),
            pair("username", RValue(username)),
            pair("platform", ["": "ios", "name": "iOS"]),
            pair("session-type", "Caboose"),
            pair("display", [
                "refresh-rate": .int(Int64(refreshRate * 1000)),
                "desktop_size": [.int(Int64(desktopWidth)), .int(Int64(desktopHeight))],
                "dpi": ["x": .int(Int64(dpi)), "y": .int(Int64(dpi))],
                "monitors": .dict([RPair(0, [
                    "geometry": [0, 0, .int(Int64(desktopWidth)), .int(Int64(desktopHeight))],
                    "primary": true,
                    "refresh-rate": .int(Int64(refreshRate * 1000)),
                    "width-mm": .int(Int64(widthMM)), "height-mm": .int(Int64(heightMM)),
                    "manufacturer": "Apple", "model": "iPhone", "name": "Caboose",
                    "workarea": [0, 0, .int(Int64(desktopWidth)), .int(Int64(desktopHeight))],
                ])]),
            ]),
            // Xpra 6.5 sets Xft.dpi and XSETTINGS Xft/DPI from the scalar top-level dpi (the
            // "" key of the dict); newer servers read display.dpi. Send both so text follows the phone.
            pair("dpi", ["": .int(Int64(dpi)), "x": .int(Int64(dpi)), "y": .int(Int64(dpi))]),
            pair("digest", ["hmac+sha256"]),
            pair("salt-digest", ["hmac+sha256", "xor"]),
            // Packets are never compressed: everything that matters is already a codec.
            pair("compression_level", 0),
            pair("encoders", ["rencodeplus"]),
            pair("compressors", []),
            pair("bandwidth", ["enabled": true]),
            pair("network", ["pings": 5]),
            pair("share", false),
            pair("steal", true),
        ]
        if let challengeResponse {
            caps.append(pair("challenge_response", RValue(challengeResponse)))
            if let clientSalt { caps.append(pair("challenge_client_salt", RValue(clientSalt))) }
        }
        caps += [
            pair("auto_refresh_delay", 250),
            pair("vrefresh", .int(Int64(refreshRate))),
            pair("metadata.supported", .list(Self.metadataSupported)),
            pair("encoding", [
                "": RValue(preferredEncoding),
                "options": .list(Self.encodings),
                "core": .list(Self.encodings),
                "rgb_formats": ["BGRX", "BGRA", "RGBX", "RGBA"],
                "window-icon": ["png"],
                "icons": ["max_size": [128, 128], "greedy": true],
                "transparency": true,
                "rgb_lz4": false,
                // Video only (never text): the server may encode a video smaller to keep its
                // frame rate, and the client scales it back up on the GPU.
                "video_scaling": true,
                // Typing and pointer feedback: let the server's adaptive batching go as low as a
                // phone frame and no higher than 150 ms, instead of the 500 ms default ceiling.
                "batch": ["min_delay": .int(Int64(max(4, 1000 / max(30, refreshRate)))), "max_delay": 150, "delay": 16],
                "full_csc_modes": ["h264": ["YUV420P"], "jpeg": ["BGRX", "BGRA", "YUV420P"], "webp": ["BGRX", "BGRA"]],
                "h264": [
                    "score-delta": 80,
                    "fast-decode": false,
                    "deblocking-filter": true,
                    "cabac": true,
                    "b-frames": false,
                    "YUV420P": ["profile": "high", "level": "5.1"],
                ],
            ]),
            pair("clipboard", [
                "enabled": true, "want_targets": true, "greedy": true, "selections": ["CLIPBOARD"],
                "preferred-targets": ["UTF8_STRING", "text/plain;charset=utf-8", "TEXT", "STRING", "text/plain", "image/png"],
            ]),
            pair("pointer", ["double_click": [:]]),
            pair("file", ["enabled": true, "chunks": .int(256 * 1024), "open-url": true, "size-limit": .int(512 * 1024 * 1024)]),
            pair("audio", ["async": true, "signal": false]),
            pair("printer", ["printing": false]),
            pair("wants", ["features", "packet-types"]),
            pair("server-features", true),
            pair("window", ["enabled": true, "pre-map": true, "restack": true]),
            pair("keyboard", true),
            pair("notification", ["enabled": true]),
            pair("cursor", ["enabled": true, "encodings": ["png"]]),
            pair("bell", true),
            pair("system_tray", false),
        ]
        return .dict(caps)
    }

    private func pair(_ key: String, _ value: RValue) -> RPair { RPair(RValue(key), value) }
}

/// Xpra's challenge/response: the server sends a salt and the digests to use; the
/// client mixes in its own salt and answers with HMAC(password, hex(salt)).
public enum XpraChallenge {
    public enum Failure: Error { case unsupportedDigest(String), badSalt }

    public static func respond(password: String, serverSalt: Data, digest: String, saltDigest: String) throws
        -> (response: String, clientSalt: String) {
        guard digest == "hmac+sha256" else { throw Failure.unsupportedDigest(digest) }
        let clientSalt = randomSalt(length: saltDigest == "xor" ? serverSalt.count : 32)
        let mixed: Data
        switch saltDigest {
        case "xor":
            guard serverSalt.count >= 16 else { throw Failure.badSalt }
            let client = Data(clientSalt.utf8)
            mixed = Data(zip(client, serverSalt.prefix(client.count)).map { $0 ^ $1 })
        case "hmac+sha256":
            mixed = Data(HMAC<SHA256>.authenticationCode(for: serverSalt, using: SymmetricKey(data: Data(clientSalt.utf8))))
        default:
            throw Failure.unsupportedDigest(saltDigest)
        }
        let hexSalt = mixed.map { String(format: "%02x", $0) }.joined()
        let code = HMAC<SHA256>.authenticationCode(for: Data(hexSalt.utf8), using: SymmetricKey(data: Data(password.utf8)))
        return (Data(code).map { String(format: "%02x", $0) }.joined(), clientSalt)
    }

    static func randomSalt(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] })
    }
}
