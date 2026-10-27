import Foundation
import Security

/// Where your computer lives and the token that opens it. The token is kept in the Keychain.
struct Credentials: Equatable {
    var hostURL: URL
    var token: String

    private static let service = "com.braedonsaunders.caboose.host"
    private static let hostKey = "caboose.hostURL"

    static func load() -> Credentials? {
        if let text = UserDefaults.standard.string(forKey: hostKey), let url = URL(string: text),
           let token = readToken(), !token.isEmpty {
            return Credentials(hostURL: url, token: token)
        }
        return developmentDefaults()
    }

    func save() {
        UserDefaults.standard.set(hostURL.absoluteString, forKey: Self.hostKey)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }

    /// Parses `caboose://connect?host=<url>&token=<token>`.
    init?(link: URL) {
        guard link.scheme == "caboose", link.host == "connect",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, let url = URL(string: host),
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        self.init(hostURL: url, token: token)
    }

    init(hostURL: URL, token: String) {
        self.hostURL = hostURL
        self.token = token
    }

    private static func readToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A developer's own host, injected at build time from the untracked Local.xcconfig.
    private static func developmentDefaults() -> Credentials? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "CabooseDevelopmentHost") as? String, !host.isEmpty,
              let token = Bundle.main.object(forInfoDictionaryKey: "CabooseDevelopmentToken") as? String, !token.isEmpty,
              let url = URL(string: host) else { return nil }
        return Credentials(hostURL: url, token: token)
    }
}
