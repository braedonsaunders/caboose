import Foundation
import Security

/// Where your computer lives and the token that opens it. The token is kept in the Keychain.
struct Credentials: Equatable {
    var hostURL: URL
    var token: String
    /// Other addresses of the same host — its Tailscale or other VPN address, say — tried
    /// alongside `hostURL` so the computer is reachable at home and away.
    var alternateURLs: [URL] = []

    /// Every address of the host, the preferred one first.
    var candidates: [URL] { [hostURL] + alternateURLs.filter { $0 != hostURL } }

    private static let service = "com.braedonsaunders.caboose.host"
    private static let hostKey = "caboose.hostURL"
    private static let alternatesKey = "caboose.alternateHostURLs"

    static func load() -> Credentials? {
        if let text = UserDefaults.standard.string(forKey: hostKey), let url = URL(string: text),
           let token = readToken(), !token.isEmpty {
            let alternates = (UserDefaults.standard.stringArray(forKey: alternatesKey) ?? []).compactMap(URL.init(string:))
            return Credentials(hostURL: url, token: token, alternateURLs: alternates)
        }
        return developmentDefaults()
    }

    func save() {
        UserDefaults.standard.set(hostURL.absoluteString, forKey: Self.hostKey)
        UserDefaults.standard.set(alternateURLs.map(\.absoluteString), forKey: Self.alternatesKey)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: alternatesKey)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }

    /// Parses `caboose://connect?host=<url>&token=<token>[&alt=<url>…]`.
    init?(link: URL) {
        guard link.scheme == "caboose", link.host == "connect",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, let url = URL(string: host),
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        let alternates = items.filter { $0.name == "alt" }.compactMap { $0.value.flatMap(URL.init(string:)) }
        self.init(hostURL: url, token: token, alternateURLs: alternates)
    }

    init(hostURL: URL, token: String, alternateURLs: [URL] = []) {
        self.hostURL = hostURL
        self.token = token
        self.alternateURLs = alternateURLs
    }

    /// The first address that answers, tried together: on the home network the LAN address
    /// normally wins, away from it only the VPN address answers. Any HTTP response counts.
    func reachableURL(timeout: TimeInterval = 2.5) async -> URL {
        let candidates = candidates
        guard candidates.count > 1 else { return hostURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: URL?.self) { group in
            for url in candidates {
                group.addTask {
                    let probe = URLRequest(url: url.appendingPathComponent("v1/health"), timeoutInterval: timeout)
                    guard let (_, response) = try? await session.data(for: probe), response is HTTPURLResponse else { return nil }
                    return url
                }
            }
            for await url in group {
                if let url {
                    group.cancelAll()
                    return url
                }
            }
            return hostURL
        }
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
