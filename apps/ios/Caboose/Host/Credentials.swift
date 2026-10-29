import Foundation
import Security
import CryptoKit

/// Where your computer lives and the token that opens it, kept in the Keychain in the
/// app's shared access group so the share extension can reach the same computer.
struct Credentials: Equatable, Codable, Identifiable {
    var hostURL: URL
    var token: String
    /// Other addresses of the same host — its Tailscale or other VPN address, say — tried
    /// alongside `hostURL` so the computer is reachable at home and away.
    var alternateURLs: [URL] = []

    var computerID: String?
    var computerName: String?
    private var storedIdentity: String?
    var id: String { fileDomainIdentifier }
    var displayName: String { computerName.flatMap { $0.isEmpty ? nil : $0 } ?? hostURL.host ?? "Caboose" }
    /// Console authentication uses its own browser session; never put a phone token in a URL.
    var consoleURL: URL? { Self.normalizedAddress(hostURL.absoluteString) }

    /// A pairing-specific identifier, so cached Files data is never reused for another computer.
    var fileDomainIdentifier: String {
        if let storedIdentity { return storedIdentity }
        let bytes = SHA256.hash(data: Data((hostURL.absoluteString + "\n" + token).utf8))
        return "computer-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Every address of the host, the preferred one first.
    var candidates: [URL] { [hostURL] + alternateURLs.filter { $0 != hostURL } }

    private static let service = "com.braedonsaunders.caboose.host"
    /// The host's addresses, one per line, preferred first.
    private static let addressesService = "com.braedonsaunders.caboose.host.addresses"
    private static let hostKey = "caboose.hostURL"
    private static let alternatesKey = "caboose.alternateHostURLs"

    private static let collectionService = "com.braedonsaunders.caboose.computers"

    struct Collection: Codable {
        var computers: [Credentials] = []
        var activeID: String?
        var active: Credentials? { computers.first { $0.id == activeID } }

        mutating func select(_ incoming: Credentials) -> Credentials {
            var value = incoming
            // Server ids are scoped to a host; names and tokens are never computer ids.
            let host = Credentials.normalizedAddress(value.hostURL.absoluteString)
            if let index = computers.firstIndex(where: {
                $0.id == value.id || (value.computerID != nil && $0.computerID == value.computerID &&
                    host != nil && Credentials.normalizedAddress($0.hostURL.absoluteString) == host)
            }) {
                let old = computers[index]
                value.storedIdentity = old.id
                if value.computerName == nil { value.computerName = old.computerName }
                computers[index] = value
            } else {
                value.storedIdentity = value.id
                computers.append(value)
            }
            activeID = value.id
            return value
        }
    }

    /// One Keychain item commits credentials and selection together. A failed update leaves
    /// the previous collection intact. Legacy items remain available until migration succeeds.
    static func loadCollection() throws -> Collection {
        if let data = try readData(collectionService) {
            return try JSONDecoder().decode(Collection.self, from: data)
        }
        var collection = Collection()
        var legacy: Credentials?
        if let tokenData = try readData(service), let token = String(data: tokenData, encoding: .utf8), !token.isEmpty {
            let addresses = try readData(addressesService).flatMap { String(data: $0, encoding: .utf8) }
            let urls = addresses?.split(separator: "\n").compactMap { URL(string: String($0)) } ?? []
            if let host = urls.first {
                legacy = Credentials(hostURL: host, token: token, alternateURLs: Array(urls.dropFirst()))
            } else if let text = UserDefaults.standard.string(forKey: hostKey), let host = URL(string: text) {
                legacy = Credentials(hostURL: host, token: token,
                    alternateURLs: (UserDefaults.standard.stringArray(forKey: alternatesKey) ?? []).compactMap(URL.init(string:)))
            }
        }
        if let legacy = legacy ?? developmentDefaults() {
            _ = collection.select(legacy)
            try saveCollection(collection)
        }
        return collection
    }

    static func load() -> Credentials? { try? loadCollection().active }

    @discardableResult
    func save() throws -> Credentials {
        var collection = try Self.loadCollection()
        let saved = collection.select(self)
        try Self.saveCollection(collection)
        return saved
    }

    func saveAddresses() throws { _ = try save() }

    static func saveCollection(_ collection: Collection) throws {
        let data = try JSONEncoder().encode(collection)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: collectionService]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not access saved computers (Keychain error \(status))." }
    }

    static func normalizedAddress(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    mutating func addAlternate(_ url: URL) {
        let known = candidates.compactMap { Self.normalizedAddress($0.absoluteString) }
        if !known.contains(url) { alternateURLs.append(url) }
    }

    /// Forget the selected pairing without deleting any other explicitly paired computer.
    static func clear() throws {
        var collection = try loadCollection()
        // The canonical collection already contains the migrated pairing. Erase the old
        // storage too, so Forget cannot leave its pre-migration bearer behind.
        for service in [service, addressesService] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
        }
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: alternatesKey)
        let removedID = collection.activeID
        collection.computers.removeAll { $0.id == removedID }
        collection.activeID = collection.computers.first?.id
        try saveCollection(collection)
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

    init(hostURL: URL, token: String, alternateURLs: [URL] = [], computerID: String? = nil, computerName: String? = nil) {
        self.computerID = computerID
        self.computerName = computerName
        self.hostURL = hostURL
        self.token = token
        self.alternateURLs = alternateURLs
    }

    /// The first address that answers, tried together: on the home network the LAN address
    /// normally wins, away from it only the VPN address answers. The anonymous health
    /// response filters captive portals, but does not authenticate the host.
    func reachableURL(timeout: TimeInterval = 2.5) async -> URL {
        let candidates = candidates
        guard candidates.count > 1 else { return hostURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: NoProbeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: URL?.self) { group in
            for url in candidates {
                group.addTask {
                    let probe = URLRequest(url: url.appendingPathComponent("v1/health"), timeoutInterval: timeout)
                    guard let (data, response) = try? await session.data(for: probe),
                          let http = response as? HTTPURLResponse,
                          Self.isHealthResponse(status: http.statusCode, data: data) else { return nil }
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

    static func isHealthResponse(status: Int, data: Data) -> Bool {
        guard status == 401,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return object["error"] == "unauthorized"
    }

    private static func readData(_ service: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return data
    }

    /// A developer's own host, injected at build time from the untracked Local.xcconfig.
    /// Debug builds only: a Release archive from the same machine must never sign in to the
    /// developer's computer, and the build settings leave the keys empty there as well.
    private static func developmentDefaults() -> Credentials? {
        #if DEBUG
        guard let host = Bundle.main.object(forInfoDictionaryKey: "CabooseDevelopmentHost") as? String, !host.isEmpty,
              let token = Bundle.main.object(forInfoDictionaryKey: "CabooseDevelopmentToken") as? String, !token.isEmpty,
              let url = URL(string: host) else { return nil }
        return Credentials(hostURL: url, token: token)
        #else
        return nil
        #endif
    }
}

/// Never let a captive portal redirect a health probe to another origin.
private final class NoProbeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
