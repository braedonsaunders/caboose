import Foundation
import Network

/// The network origin of an agent app that declares `net`, on the device: the same contract as
/// the computer's (`guest/apps/net.py`). A request to
/// `http://127.0.0.1:<port>/<token>/<scheme>/<authority><path>?<query>` is made from this
/// device to `<scheme>://<authority><path>?<query>` with the page's method, headers and body,
/// and the answer streams back with its status and headers and CORS headers that admit the
/// app's page. It is not the app's origin, so nothing fetched through it runs as the app's
/// own script.
enum AgentAppNet {
    static let maxBody = 64 * 1024 * 1024
    static let maxTarget = 16 * 1024
    /// The prefix under which `caboose.fetch` sends a header the page's script may not set.
    static let override = "x-caboose-header-"

    static let dropRequest: Set<String> = [
        "host", "origin", "referer", "cookie", "cookie2", "connection", "keep-alive", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "accept-encoding", "expect", "dnt",
        "proxy-authorization", "proxy-connection", "priority",
    ]
    static let dropRequestPrefixes = ["sec-", "access-control-request-", "proxy-"]
    static let dropResponse: Set<String> = [
        "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade", "proxy-authenticate",
        "strict-transport-security", "alt-svc", "set-cookie", "set-cookie2", "public-key-pins", "clear-site-data",
        "content-security-policy", "content-security-policy-report-only", "cross-origin-opener-policy",
        "cross-origin-embedder-policy", "cross-origin-resource-policy", "timing-allow-origin", "vary",
        "server-timing", "nel", "report-to",
    ]

    struct Refusal: Error, Equatable {
        var status: Int
        var message: String
    }

    /// The upstream URL a request target names.
    static func target(_ requestTarget: String, token: String) -> Result<URL, Refusal> {
        guard requestTarget.hasPrefix("/"), requestTarget.utf8.count <= maxTarget else {
            return .failure(Refusal(status: 400, message: "Malformed request"))
        }
        let pathEnd = requestTarget.firstIndex(of: "?") ?? requestTarget.endIndex
        let raw = requestTarget[..<pathEnd]
        let query = pathEnd < requestTarget.endIndex ? String(requestTarget[requestTarget.index(after: pathEnd)...]) : ""
        let parts = raw.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, GameHTTP.sameToken(parts[1], token) else { return .failure(Refusal(status: 404, message: "Not found")) }
        let scheme = parts[2].lowercased()
        guard scheme == "http" || scheme == "https" else {
            return .failure(Refusal(status: 400, message: "The network origin reaches http and https URLs"))
        }
        let invalidHost = Refusal(status: 400, message: "The URL has no valid host")
        guard let authority = String(parts[3]).removingPercentEncoding, !authority.isEmpty,
              !authority.contains(where: { "@/\\?#".contains($0) }),
              authority.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return .failure(invalidHost) }
        let rest = parts.count == 5 ? "/" + parts[4] : "/"
        guard (rest + query).unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else {
            return .failure(Refusal(status: 400, message: "Malformed request"))
        }
        let text = "\(scheme)://\(authority)\(rest)" + (query.isEmpty ? "" : "?\(query)")
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              let url = components.url else { return .failure(invalidHost) }
        return .success(url)
    }

    /// The headers sent upstream, from the request's fields in order.
    static func upstreamHeaders(_ fields: [(String, String)]) -> [(String, String)] {
        var sent: [(String, String)] = []
        var overrides: [(String, String)] = []
        for (name, value) in fields {
            let lower = name.lowercased()
            guard !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { continue }
            if lower.hasPrefix(override) {
                let real = String(name.dropFirst(override.count))
                if !real.isEmpty, !["host", "content-length", "transfer-encoding", "connection"].contains(real.lowercased()) {
                    overrides.append((real, value))
                }
                continue
            }
            if dropRequest.contains(lower) || dropRequestPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            sent.append((name, value))
        }
        let replaced = Set(overrides.map { $0.0.lowercased() })
        return sent.filter { !replaced.contains($0.0.lowercased()) } + overrides
    }

    /// `Access-Control-Allow-Origin` for a request's `Origin`, or nil to refuse it. A request
    /// without one (a media element, an image) is the token's to admit.
    static func allowedOrigin(_ origin: String?, appOrigin: String) -> String? {
        guard let origin else { return "*" }
        return origin == appOrigin || origin == "null" ? origin : nil
    }

    /// The headers sent to the page. A compressed body arrives decoded, so its encoding and
    /// length no longer apply.
    static func responseHeaders(_ fields: [(String, String)], origin: String, finalURL: String) -> [(String, String)] {
        let decoded = fields.contains { $0.0.lowercased() == "content-encoding" }
        var sent: [(String, String)] = []
        for (name, value) in fields {
            let lower = name.lowercased()
            if lower == "set-cookie" || lower == "set-cookie2" { sent.append(("X-Caboose-Set-Cookie", value)); continue }
            if lower.hasPrefix("access-control-") || dropResponse.contains(lower)
                || (decoded && (lower == "content-encoding" || lower == "content-length")) { continue }
            sent.append((name, value))
        }
        return sent + [("Access-Control-Allow-Origin", origin), ("Access-Control-Expose-Headers", "*"),
                       ("Vary", "Origin"), ("X-Caboose-Url", finalURL)]
    }

    static func preflight(_ request: GameHTTP.Request, origin: String) -> [(String, String)] {
        [("Access-Control-Allow-Origin", origin),
         ("Access-Control-Allow-Methods", request.value("access-control-request-method") ?? "GET"),
         ("Access-Control-Allow-Headers", request.value("access-control-request-headers") ?? "*"),
         ("Access-Control-Max-Age", "600"), ("Vary", "Origin"), ("Content-Length", "0")]
    }

    /// A response head with its fields in the order given, each connection's only one.
    static func head(_ status: Int, reason: String, fields: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason.isEmpty ? GameHTTP.reason(status) : reason)\r\n"
        for (name, value) in fields + [("Connection", "close")]
        where !name.isEmpty && !name.contains(where: { $0 == ":" || $0.isWhitespace || $0.isNewline })
            && !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) {
            text += "\(name): \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }
}

/// Serves one app instance's network origin on `127.0.0.1`, from a port the system picks.
/// Requests from this device only, with the page's `Host` and token, one request per
/// connection. Upstream requests use their own ephemeral session: no cookies, no cache.
@MainActor
final class AgentAppNetServer {
    let token = GameOrigin.newToken()
    let appOrigin: String
    private var listener: NWListener?
    private var port: UInt16?
    private var isListening = false
    private var isStopped = false
    private var waiting: [CheckedContinuation<URL, Error>] = []
    private var connections: [ObjectIdentifier: AgentAppNetConnection] = [:]
    let session: URLSession
    let delegate: AgentAppNetSessionDelegate
    static let maxConnections = 32

    init(appOrigin: String) {
        self.appOrigin = appOrigin
        let delegate = AgentAppNetSessionDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        listener?.cancel()
        session.invalidateAndCancel()
    }

    /// `http://127.0.0.1:<port>/<token>/`, once listening.
    var base: URL? {
        guard isListening, let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/")
    }

    func start() async throws -> URL {
        if isStopped { throw GameServerError.stopped }
        if let base { return base }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if listener == nil { listen() }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        listener?.cancel()
        listener = nil
        isListening = false
        settle(.failure(GameServerError.stopped))
        let open = Array(connections.values)
        connections.removeAll()
        for connection in open { connection.close() }
        session.invalidateAndCancel()
    }

    private func listen() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { return settle(.failure(error)) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    self.port = port
                    self.isListening = true
                    if let base = self.base { self.settle(.success(base)) }
                case .failed(let error), .waiting(let error):
                    let wasListening = self.isListening
                    listener.cancel()
                    self.listener = nil
                    self.isListening = false
                    self.settle(.failure(error))
                    // The system can take the socket back while the app is suspended; the
                    // page keeps its URLs because the port stays the same.
                    if wasListening, !self.isStopped { self.listen() }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener, let port = self.port,
                      self.connections.count < Self.maxConnections, GameServer.isLoopback(connection.endpoint) else {
                    return connection.cancel()
                }
                let served = AgentAppNetConnection(connection, authority: "127.0.0.1:\(port)", server: self)
                self.connections[ObjectIdentifier(served)] = served
                served.start()
            }
        }
        listener.start(queue: .main)
    }

    /// Listens again after the system took the socket while the app was suspended.
    func resume() {
        guard !isStopped, listener == nil, port != nil else { return }
        listen()
    }

    private func settle(_ result: Result<URL, Error>) {
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume(with: result) }
    }

    fileprivate func remove(_ connection: AgentAppNetConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }
}

/// Routes each upstream task's callbacks to the connection that started it.
final class AgentAppNetSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: AgentAppNetTaskHandler] = [:]

    func register(_ handler: AgentAppNetTaskHandler, for task: URLSessionTask) {
        lock.withLock { handlers[task.taskIdentifier] = handler }
    }

    private func handler(_ task: URLSessionTask) -> AgentAppNetTaskHandler? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        handler(dataTask)?.received(response, finalURL: dataTask.currentRequest?.url ?? response.url)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        handler?.completed(error)
    }
}

/// What a connection does with its upstream task's callbacks, on any queue.
final class AgentAppNetTaskHandler: @unchecked Sendable {
    let onResponse: @Sendable (URLResponse, URL?) -> Void
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable (Error?) -> Void

    init(onResponse: @escaping @Sendable (URLResponse, URL?) -> Void, onData: @escaping @Sendable (Data) -> Void,
         onComplete: @escaping @Sendable (Error?) -> Void) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
    }

    func received(_ response: URLResponse, finalURL: URL?) { onResponse(response, finalURL) }
    func received(_ data: Data) { onData(data) }
    func completed(_ error: Error?) { onComplete(error) }
}

/// One connection to the network origin: its request, the upstream request it becomes, and
/// the answer streamed back. Upstream reading pauses while more than `highWater` bytes wait to
/// go to the page, so a slow reader does not make the device hold a whole download.
@MainActor
private final class AgentAppNetConnection {
    nonisolated let connection: NWConnection
    private let authority: String
    private weak var server: AgentAppNetServer?
    private var buffer = Data()
    private var request: GameHTTP.Request?
    private var bodyLength = 0
    private var task: URLSessionDataTask?
    private var pending = 0
    private var suspended = false
    private var started = false
    private var finishing = false
    private var isClosed = false
    private var corsOrigin = "*"
    private var method = "GET"
    private var deadline: DispatchWorkItem?
    static let highWater = 4 * 1024 * 1024
    static let lowWater = 1024 * 1024

    init(_ connection: NWConnection, authority: String, server: AgentAppNetServer) {
        self.connection = connection
        self.authority = authority
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        arm(30)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated { self?.received(data, ended: isComplete || error != nil) }
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        guard !isClosed, task == nil, !started else { return }
        if let data { buffer.append(data) }
        if request == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > GameHTTP.maxHeadBytes { return answer(431, "Request header fields too large") }
                return ended ? close() : receive()
            }
            // The head is read on its own: GameHTTP refuses bodies, which this origin carries.
            let head = buffer[..<end.upperBound]
            buffer = Data(buffer[end.upperBound...])
            switch Self.parse(Data(head)) {
            case .reject(let status): return answer(status, "Malformed request")
            case .incomplete: return close()
            case .request(let parsed):
                request = parsed
                guard parsed.fields["transfer-encoding"] == nil else { return answer(411, "Send a request body with a length") }
                let length = parsed.value("content-length").flatMap(Int.init) ?? (parsed.fields["content-length"] == nil ? 0 : -1)
                guard (0 ... AgentAppNet.maxBody).contains(length) else {
                    return answer(413, "A request body is at most \(AgentAppNet.maxBody) bytes")
                }
                bodyLength = length
            }
        }
        guard let request else { return }
        if buffer.count < bodyLength {
            return ended ? close() : receive()
        }
        route(request, body: buffer.prefix(bodyLength))
    }

    /// GameHTTP's head reader, with the body fields it refuses taken out and checked here.
    static func parse(_ head: Data) -> GameHTTP.Parse {
        var text = String(decoding: head, as: UTF8.self)
        var kept: [String] = []
        var bodyFields: [String] = []
        for line in text.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") || lower.hasPrefix("transfer-encoding:") { bodyFields.append(line) } else { kept.append(line) }
        }
        text = kept.joined(separator: "\r\n")
        guard case .request(var request) = GameHTTP.parse(Data(text.utf8)) else { return GameHTTP.parse(Data(text.utf8)) }
        for line in bodyFields {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            request.fields[line[..<colon].lowercased(), default: []].append(value)
        }
        return .request(request)
    }

    private func route(_ request: GameHTTP.Request, body: Data) {
        guard let server else { return close() }
        guard request.value("host") == authority else { return answer(400, "Wrong host") }
        guard let origin = AgentAppNet.allowedOrigin(request.value("origin"), appOrigin: server.appOrigin) else {
            return answer(403, "Only the app may use its network origin")
        }
        corsOrigin = origin
        let url: URL
        switch AgentAppNet.target(request.target, token: server.token) {
        case .failure(let refusal): return answer(refusal.status, refusal.message)
        case .success(let target): url = target
        }
        if request.method == "OPTIONS", request.value("access-control-request-method") != nil {
            started = true
            send(AgentAppNet.head(204, reason: "No Content", fields: AgentAppNet.preflight(request, origin: origin)))
            return finish()
        }
        method = request.method
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.httpShouldHandleCookies = false
        if !body.isEmpty { upstream.httpBody = body }
        var fields: [(String, String)] = []
        for (name, values) in request.fields { for value in values { fields.append((name, value)) } }
        for (name, value) in AgentAppNet.upstreamHeaders(fields) { upstream.addValue(value, forHTTPHeaderField: name) }
        if upstream.value(forHTTPHeaderField: "User-Agent") == nil {
            upstream.setValue("Mozilla/5.0 (iPhone) Caboose", forHTTPHeaderField: "User-Agent")
        }
        let task = server.session.dataTask(with: upstream)
        self.task = task
        // The main queue keeps the callbacks in the order they came: the head, then the body in order.
        let handler = AgentAppNetTaskHandler(
            onResponse: { [weak self] response, finalURL in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.upstreamResponded(response, finalURL: finalURL) } }
            },
            onData: { [weak self] data in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.upstreamSent(data) } }
            },
            onComplete: { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.upstreamEnded(error) } }
            })
        server.delegate.register(handler, for: task)
        deadline?.cancel()
        task.resume()
    }

    private func upstreamResponded(_ response: URLResponse, finalURL: URL?) {
        guard !isClosed, !started else { return }
        started = true
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        var fields: [(String, String)] = []
        for (name, value) in http?.allHeaderFields ?? [:] {
            guard let name = name as? String, let value = value as? String else { continue }
            fields.append((name, value))
        }
        let final = (finalURL ?? response.url)?.absoluteString ?? ""
        send(AgentAppNet.head(status, reason: "", fields: AgentAppNet.responseHeaders(fields, origin: corsOrigin, finalURL: final)))
        if method == "HEAD" {
            task?.cancel()
            finish()
        }
    }

    private func upstreamSent(_ data: Data) {
        guard !isClosed, !finishing, started, method != "HEAD" else { return }
        pending += data.count
        if pending > Self.highWater, !suspended {
            suspended = true
            task?.suspend()
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil { return self.close() }
                self.pending -= data.count
                if self.suspended, self.pending < Self.lowWater {
                    self.suspended = false
                    self.task?.resume()
                }
            }
        })
    }

    private func upstreamEnded(_ error: Error?) {
        guard !isClosed else { return }
        if started { return finish() }
        let message = (error as NSError?)?.localizedDescription ?? "The server did not answer"
        task = nil
        answer(502, message)
    }

    private func answer(_ status: Int, _ message: String) {
        guard !isClosed, !started else { return }
        started = true
        let body = Data((message + "\n").utf8)
        var fields: [(String, String)] = [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.count)),
                                          ("X-Caboose-Error", String(message.prefix(300)))]
        fields += [("Access-Control-Allow-Origin", corsOrigin), ("Access-Control-Expose-Headers", "*"), ("Vary", "Origin")]
        send(AgentAppNet.head(status, reason: "", fields: fields) + (request?.method == "HEAD" ? Data() : body))
        finish()
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func finish() {
        guard !isClosed, !finishing else { return }
        finishing = true
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func arm(_ seconds: TimeInterval) {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        task = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.remove(self)
    }
}
