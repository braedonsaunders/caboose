import Foundation

/// Where other machines reach a computer, as `GET /v1/computer` carries it in `network`
/// (docs/network.md): its own device on the owner's tailnet, and the servers it runs that
/// another machine can reach there. Apps on the phone connect to them directly, with no
/// Caboose in the path.
public struct ComputerNetwork: Decodable, Equatable, Sendable {
    public struct Tailnet: Decodable, Equatable, Sendable {
        /// `off`, `starting`, `needs-login`, `needs-approval`, `running` or `error`.
        public var state: String
        /// The MagicDNS name, `dev-box.tailnet.ts.net`.
        public var name: String?
        /// Tailnet addresses, IPv4 first.
        public var addresses: [String]?
        /// While it needs sign-in: the link that adds it to the tailnet of whoever opens it.
        public var loginUrl: URL?
        public var error: String?

        public init(state: String, name: String? = nil, addresses: [String]? = nil, loginUrl: URL? = nil, error: String? = nil) {
            self.state = state; self.name = name; self.addresses = addresses; self.loginUrl = loginUrl; self.error = error
        }

        /// The IPv4 address, which is the one that reaches the computer.
        public var ipv4: String? { addresses?.first { !$0.contains(":") } }
    }

    public struct Server: Decodable, Hashable, Sendable, Identifiable {
        public var `protocol`: String
        public var address: String
        public var port: Int
        public var id: String { "\(`protocol`)/\(port)" }

        public init(protocol: String, address: String, port: Int) {
            self.protocol = `protocol`; self.address = address; self.port = port
        }

        /// What usually listens on the port, for a row's title.
        public var label: String {
            if let known = Self.known[port] { return known.name }
            return `protocol` == "udp" ? "UDP server" : "Server"
        }

        /// Whether a browser is the likely client: a known web port, or an unknown TCP one.
        public var opensInBrowser: Bool {
            guard `protocol` == "tcp" else { return false }
            return Self.known[port]?.web ?? true
        }

        /// `http://name:port/` for a browser, when one fits.
        public func url(host: String) -> URL? {
            guard opensInBrowser else { return nil }
            var components = URLComponents()
            components.scheme = port == 443 || port == 8443 ? "https" : "http"
            components.host = host
            if port != 80 && port != 443 { components.port = port }
            components.path = "/"
            return components.url
        }

        /// What to type into another app: `host:port`.
        public func address(host: String) -> String { "\(host):\(port)" }

        private static let known: [Int: (name: String, web: Bool)] = [
            22: ("SSH", false), 80: ("Web server", true), 443: ("Web server", true), 1883: ("MQTT", false),
            2283: ("Immich", true), 3000: ("Web app", true), 3306: ("MySQL", false), 4200: ("Angular", true),
            5000: ("Web app", true), 5173: ("Vite", true), 5432: ("PostgreSQL", false), 6379: ("Redis", false),
            8000: ("Web app", true), 8080: ("Web server", true), 8096: ("Jellyfin", true), 8123: ("Home Assistant", true),
            8443: ("Web server", true), 8888: ("Jupyter", true), 9000: ("Web app", true), 11434: ("Ollama", false),
            25565: ("Minecraft", false), 27017: ("MongoDB", false), 32400: ("Plex", true),
        ]
    }

    /// Its own address on the home network, on a Linux host that shares its Ethernet.
    public struct Lan: Decodable, Equatable, Sendable {
        /// `starting`, `running` or `error`.
        public var state: String
        public var address: String?
        /// Its mDNS name, `dev-box.local`.
        public var name: String?
        public var error: String?

        public init(state: String, address: String? = nil, name: String? = nil, error: String? = nil) {
            self.state = state; self.address = address; self.name = name; self.error = error
        }
    }

    public var tailnet: Tailnet?
    public var lan: Lan?
    public var servers: [Server]?

    public init(tailnet: Tailnet? = nil, lan: Lan? = nil, servers: [Server]? = nil) {
        self.tailnet = tailnet; self.lan = lan; self.servers = servers
    }

    /// The name other devices use: its tailnet name, which works anywhere, else its name at home.
    public var host: String? {
        if let tailnet, tailnet.state == "running", let name = tailnet.name ?? tailnet.ipv4 { return name }
        if let lan, lan.state == "running" { return lan.name ?? lan.address }
        return nil
    }
}
