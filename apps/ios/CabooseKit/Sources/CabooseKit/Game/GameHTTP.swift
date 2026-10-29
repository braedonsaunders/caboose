import Foundation

/// A game's origin on the device: `http://127.0.0.1:<port>/<token>/`, which `GameServer`
/// serves (docs/game-handoff.md, "Files"). The token is 128 random bits in hex, so only the
/// game's own page knows its URLs.
public struct GameOrigin: Equatable, Sendable {
    public var port: UInt16
    public var token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    /// A new, unguessable token: 16 bytes from the system's cryptographically secure generator.
    static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// The `Host` every request to this origin carries.
    var authority: String { "127.0.0.1:\(port)" }

    /// `http://127.0.0.1:<port>/<token>/<path>`, for a path relative to the game's root.
    public func url(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/\(token)/" + path.split(separator: "/").joined(separator: "/")
        return components.url
    }

    /// Whether `url` is one of this game's: this origin, below the token.
    public func contains(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "http" && components.host == "127.0.0.1" && components.port == Int(port)
            && components.percentEncodedPath.hasPrefix("/\(token)/")
    }
}

/// The HTTP/1.1 a game's page is served over, as pure functions: reading a request head,
/// deciding what it asks for, and writing a response head. Only `GET` and `HEAD` are served,
/// without bodies, one request per connection.
enum GameHTTP {
    /// The most a request head may take, its final blank line included.
    static let maxHeadBytes = 16 * 1024

    struct Request: Equatable {
        var method: String
        /// As sent: origin-form, percent-encoded.
        var target: String
        var version: String
        /// Every field's values by lowercased name, in the order sent.
        var fields: [String: [String]]

        /// A field sent exactly once; nil when absent or repeated.
        func value(_ name: String) -> String? {
            guard let values = fields[name.lowercased()], values.count == 1 else { return nil }
            return values[0]
        }
    }

    enum Parse: Equatable {
        /// The head has not all arrived.
        case incomplete
        case request(Request)
        /// Answered with this status, and the connection closed.
        case reject(Int)
    }

    /// Reads the request head at the start of `buffer`. Anything after it is ignored: a request
    /// has no body here, and the connection closes after the response.
    static func parse(_ buffer: Data, limit: Int = maxHeadBytes) -> Parse {
        let bytes = [UInt8](buffer.prefix(limit + 1))
        guard let end = headEnd(bytes) else { return bytes.count > limit ? .reject(431) : .incomplete }
        guard end + 4 <= limit else { return .reject(431) }
        // Printable ASCII, tabs and line ends only.
        guard bytes[..<end].allSatisfy({ $0 == 0x09 || $0 == 0x0D || $0 == 0x0A || (0x20 ... 0x7E).contains($0) }) else {
            return .reject(400)
        }
        let lines = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
        // A bare CR or LF is not a line end.
        guard !lines.contains(where: { $0.utf8.contains(0x0D) || $0.utf8.contains(0x0A) }), let first = lines.first else {
            return .reject(400)
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(parts[0]), !parts[1].isEmpty else { return .reject(400) }
        let version = String(parts[2])
        guard version.hasPrefix("HTTP/") else { return .reject(400) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .reject(505) }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            // Folded lines and names with space before the colon are refused, as RFC 9112 says.
            guard let colon = line.firstIndex(of: ":"), isToken(line[..<colon]) else { return .reject(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            fields[line[..<colon].lowercased(), default: []].append(value)
        }
        // No request here has a body; one that says it has is refused rather than skipped.
        if fields["transfer-encoding"] != nil { return .reject(400) }
        if let lengths = fields["content-length"], lengths != ["0"] { return .reject(400) }
        return .request(Request(method: String(parts[0]), target: String(parts[1]), version: version, fields: fields))
    }

    /// Where the head's blank line starts, if it has arrived.
    private static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0 ... bytes.count - 4
        where bytes[index] == 0x0D && bytes[index + 1] == 0x0A && bytes[index + 2] == 0x0D && bytes[index + 3] == 0x0A {
            return index
        }
        return nil
    }

    /// An RFC 9110 token: a method or a field name.
    private static func isToken<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte) || tokenSymbols.contains(byte)
        }
    }

    private static let tokenSymbols = Set("!#$%&'*+-.^_`|~".utf8)

    enum Route: Equatable {
        /// A file of the game: its home-relative path, the `Range` asked for, and whether it is a `HEAD`.
        case file(path: String, range: String?, head: Bool)
        /// Answered with this status alone.
        case status(Int)
    }

    /// What `request` asks of the game whose origin is `origin` and whose files are under
    /// `root`. The `Host` must be the origin's exactly (a page elsewhere that renamed its
    /// host to 127.0.0.1 is refused), the first path component the token (compared in
    /// constant time), and the rest a path that stays inside `root`.
    static func route(_ request: Request, origin: GameOrigin, root: String, appPolicy: Bool = false, appEntry: String? = nil) -> Route {
        guard request.value("host") == origin.authority else { return .status(400) }
        guard request.target.hasPrefix("/") else { return .status(400) }
        let path = request.target.prefix { $0 != "?" && $0 != "#" }
        let below = path.dropFirst()
        let token = below.prefix { $0 != "/" }
        guard sameToken(token, origin.token), below.count > token.count else { return .status(404) }
        guard request.method == "GET" || request.method == "HEAD" else { return .status(405) }
        let encoded = String(below.dropFirst(token.count))
        if appPolicy && (encoded.lowercased().contains("%2f") || encoded.lowercased().contains("%5c")) { return .status(403) }
        guard let decoded = encoded.removingPercentEncoding else { return .status(400) }
        var resolved = decoded
        if appPolicy {
            let pieces = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            let interior = decoded.hasSuffix("/") ? pieces.dropLast() : pieces[...]
            if decoded.contains("\\") || interior.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) { return .status(403) }
            if decoded == "/", let appEntry { resolved = "/" + appEntry }
            else if decoded.hasSuffix("/") { resolved += "index.html" }
        }
        switch GameFiles.resolve(resolved, root: root) {
        case .file(let file): return .file(path: file, range: request.value("range"), head: request.method == "HEAD")
        case .forbidden: return .status(403)
        case .notFound: return .status(404)
        }
    }

    /// Compares every byte whatever the first difference, so the time taken says nothing of the token.
    static func sameToken<S: StringProtocol>(_ candidate: S, _ token: String) -> Bool {
        let given = Array(candidate.utf8), wanted = Array(token.utf8)
        guard given.count == wanted.count else { return false }
        var difference: UInt8 = 0
        for index in wanted.indices { difference |= given[index] ^ wanted[index] }
        return difference == 0
    }

    /// The headers of an answer the server gives without the file service: an error.
    static func statusHeaders(_ status: Int) -> [String: String] {
        var headers = GameFiles.responseHeaders(for: "", length: 0)
        headers["Content-Type"] = "text/plain"
        if status == 405 { headers["Allow"] = "GET, HEAD" }
        return headers
    }

    /// A response's status line and headers, each connection's only one (`Connection: close`).
    /// A header whose name or value would break the head is left out.
    static func head(_ status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var headers = headers
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where isToken(name) && !value.utf8.contains(where: { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }) {
            text += "\(name): \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 505: "HTTP Version Not Supported"
        default: "Unknown"
        }
    }
}
