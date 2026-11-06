import Foundation

/// What a saved sign-in is called, what its host's refusals mean, and when its address needs
/// Tailscale on the phone (docs/architecture.md § Phone sign-ins). Foundation only: the app's
/// extensions compile it alongside `Credentials` without linking CabooseKit.
public enum SignInTitle {
    /// A sign-in's title: the name its host gave itself when it last answered, else the
    /// computer's own name for a sign-in to one computer, else the address's host — the
    /// address only when nothing better is known.
    public static func host(learned: String?, address: URL) -> String {
        nonEmpty(learned) ?? address.host ?? "Caboose"
    }

    /// The computer a sign-in opens, by its own name, else its host's.
    public static func computer(name: String?, learned: String?, address: URL) -> String {
        nonEmpty(name) ?? host(learned: learned, address: address)
    }

    /// A name the host sent, trimmed, or nil when it is empty or not a name.
    public static func cleaned(_ name: String?) -> String? {
        guard let name = nonEmpty(name), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return String(name.prefix(80))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The host's answer that a sign-in is gone for good: `401 {"error":"unauthorized","code":
/// "sign-in-revoked"}`, which a host gives only for a bearer token it does not know (a phone
/// signed out from the console, a deleted computer's phone, a replaced owner token). Nothing
/// else removes a sign-in on its own: not a plain 401, another status, a timeout or an
/// unreachable host.
///
/// The answer removes a sign-in only when it came from an address whose identity TLS
/// proved: the sign-in's own address, over https. A LAN or VPN address the app probed, or
/// any plain-http one, could be another machine that has taken that address, which does
/// not know the token either; there the app only says what the host answered.
public enum SignInRefusal {
    public static let revokedCode = "sign-in-revoked"

    /// Whether a revoked answer from `answeredBy` may remove the sign-in saved at `canonical`.
    public static func mayRemove(answeredBy url: URL, canonical: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", canonical.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, host == canonical.host?.lowercased() else { return false }
        return (url.port ?? 443) == (canonical.port ?? 443)
    }

    public static func isRevoked(status: Int, body: Data) -> Bool {
        guard status == 401,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["code"] as? String == revokedCode
    }
}

/// Addresses only a tailnet reaches: MagicDNS names under `ts.net`, Tailscale's IPv4 range
/// 100.64.0.0/10 and its IPv6 prefix fd7a:115c:a1e0::/48. Away from home, the phone reaches
/// them only with its own Tailscale connection on.
public enum TailnetAddress {
    public static func contains(_ url: URL) -> Bool {
        url.host.map(contains(host:)) ?? false
    }

    public static func contains(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".ts.net") { return true }
        if let v4 = ipv4(name) { return v4[0] == 100 && (64...127).contains(v4[1]) }
        if let v6 = ipv6(name) { return v6[0] == 0xfd7a && v6[1] == 0x115c && v6[2] == 0xa1e0 }
        return false
    }

    private static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = Int(part), (0...255).contains(value) else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    /// The first three 16-bit groups of an IPv6 address, which is all the prefix needs.
    private static func ipv6(_ text: String) -> [Int]? {
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard address.contains(":") else { return nil }
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [Int]? {
            if part.isEmpty { return [] }
            var values: [Int] = []
            for group in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(group.count), let value = Int(group, radix: 16) else { return nil }
                values.append(value)
            }
            return values
        }
        guard let head = groups(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }
}

/// Decides when a sign-in that only a tailnet reaches is out of reach because this phone is
/// not on the tailnet: after `threshold` attempts in a row that could not reach any of its
/// addresses. One answer from the host (any answer, even a refusal) clears it.
public struct TailnetAdvice: Equatable, Sendable {
    /// Two attempts: one failure is often a network change; the second is the pattern.
    public static let threshold = 2

    public private(set) var unreachedInARow = 0
    public init() {}

    /// The host could not be reached at any of these addresses.
    public mutating func unreached() { unreachedInARow += 1 }
    /// The host answered.
    public mutating func reached() { unreachedInARow = 0 }

    /// Whether to tell the person to turn Tailscale on: some address of the sign-in is a
    /// tailnet address, and the host has not been reached `threshold` times running.
    public func needsTailscale(addresses: [URL]) -> Bool {
        unreachedInARow >= Self.threshold && addresses.contains(where: TailnetAddress.contains)
    }

    /// What the app says, in its own voice.
    public static func message(name: String) -> String {
        "Turn on Tailscale on this iPhone to reach \(name) away from home."
    }
}
