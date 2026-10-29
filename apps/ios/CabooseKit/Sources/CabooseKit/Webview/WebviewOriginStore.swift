import CryptoKit
import Foundation

/// Reserves a stable loopback origin for each opted-in app and computer on this device.
@MainActor
struct WebviewOriginStore {
    private let defaults: UserDefaults
    private let key = "Caboose.WebviewOrigins.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func origin(computer: String, app: String) -> GameOrigin? {
        let digest = SHA256.hash(data: Data("\(computer)\u{0}\(app)".utf8)).map { String(format: "%02x", $0) }.joined()
        let stored = defaults.object(forKey: key)
        guard stored == nil || stored is [String: [String: Any]] else { return nil }
        var entries = stored as? [String: [String: Any]] ?? [:]
        if let entry = entries[digest] {
            guard let port = entry["port"] as? Int, (20000...60000).contains(port),
                  let token = entry["token"] as? String,
                  token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
            return GameOrigin(port: UInt16(port), token: token)
        }
        let taken = Set(entries.values.compactMap { $0["port"] as? Int })
        let start = Int.random(in: 20000...60000)
        guard let port = (0..<40001).lazy.map({ 20000 + (start - 20000 + $0) % 40001 }).first(where: { !taken.contains($0) }) else { return nil }
        let token = GameOrigin.newToken()
        entries[digest] = ["port": port, "token": token]
        defaults.set(entries, forKey: key)
        return GameOrigin(port: UInt16(port), token: token)
    }
}
