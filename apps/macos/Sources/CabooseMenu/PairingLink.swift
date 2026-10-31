import Foundation

/// Native encoding of the existing Caboose pairing-link contract.
enum PairingLink {
    static func make(addresses: [String], code: String) -> String {
        guard let primary = addresses.first, !primary.isEmpty, !code.isEmpty else { return "" }
        var parts = URLComponents()
        parts.scheme = "caboose"; parts.host = "connect"
        parts.queryItems = [URLQueryItem(name: "host", value: primary.trimmingCharacters(in: CharacterSet(charactersIn: "/")))]
            + addresses.dropFirst().map { URLQueryItem(name: "alt", value: $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            + [URLQueryItem(name: "code", value: code)]
        return parts.url?.absoluteString ?? ""
    }

    static func expiry(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
