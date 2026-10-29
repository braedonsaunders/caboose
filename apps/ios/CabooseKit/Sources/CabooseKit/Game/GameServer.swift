import Foundation
import Network

/// A game's origin on the device (docs/game-handoff.md, "Files"): an HTTP/1.1 server on
/// `127.0.0.1` that serves one game's files to its web view as
/// `http://127.0.0.1:<port>/<token>/<path>`.
///
/// WebKit gives cross-origin isolation, and with it `SharedArrayBuffer` and threaded
/// WebAssembly, only to http(s) origins, never to a custom URL scheme; `127.0.0.1` is a
/// potentially trustworthy origin, so the page is a secure context over plain HTTP. Each game
/// has its own server, so its own port and origin: one game's page reaches no other game's
/// files or storage, and stopping the server ends every connection the game had.
///
/// The listener takes connections on the loopback interface only, and only from loopback
/// addresses. A request is served only when its `Host` is exactly `127.0.0.1:<port>` and its
/// first path component is the game's 128-bit random token, and only `GET` and `HEAD` are
/// answered, read-only, from the game's root (`GameFileResponder`). The head of a request is
/// bounded (`Limits.maxHeadBytes`), as are the connections open at once, the time to send a
/// request and the time a response may go without progress. Each connection carries one
/// request (`Connection: close`). The host's bearer token never appears in a URL or a response.
@MainActor
final class GameServer {
    struct Limits: Sendable {
        var maxHeadBytes = GameHTTP.maxHeadBytes
        /// Open at once; WebKit opens at most six per origin.
        var maxConnections = 32
        /// How long a connection has to send its request head, in seconds.
        var requestTimeout: TimeInterval = 10
        /// How long an answer may go without any of it moving, in seconds: as long as a request
        /// to the computer may take.
        var progressTimeout: TimeInterval = 60

        static let standard = Limits()
    }

    let token: String
    let root: String
    let limits: Limits
    private let responder: GameFileResponder
    private var listener: NWListener?
    /// The port once the server first listened; it listens there again after a failure, so the
    /// page's origin stays the same.
    private var port: UInt16?
    private var isListening = false
    private(set) var isStopped = false
    private var waiting: [CheckedContinuation<GameOrigin, Error>] = []
    private var connections: [ObjectIdentifier: GameServerConnection] = [:]

    init(root: String, responder: GameFileResponder, limits: Limits = .standard, token: String = GameOrigin.newToken()) {
        self.root = root
        self.responder = responder
        self.limits = limits
        self.token = token
    }

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.connection.forceCancel() }
    }

    /// The origin while the server is listening.
    var origin: GameOrigin? {
        guard isListening, let port else { return nil }
        return GameOrigin(port: port, token: token)
    }

    /// The connections open now.
    var openConnections: Int { connections.count }

    /// Listens, if it is not already, and returns the origin once it is. After a failure it
    /// listens on the same port again.
    func start() async throws -> GameOrigin {
        if isStopped { throw GameServerError.stopped }
        if let origin { return origin }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            if listener == nil { listen() }
        }
    }

    /// Stops listening and closes every connection; a response still on its way writes nothing more.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        listener?.cancel()
        listener = nil
        isListening = false
        settle(.failure(GameServerError.stopped))
        let open = Array(connections.values)
        connections.removeAll()
        for connection in open { connection.abort() }
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
                self.listenerChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return connection.cancel() }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            self.port = port
            isListening = true
            settle(.success(GameOrigin(port: port, token: token)))
        case .failed(let error), .waiting(let error):
            let wasListening = isListening
            listener?.cancel()
            listener = nil
            isListening = false
            settle(.failure(error))
            // The system can take a listening socket back while the app is suspended: listen
            // again once, on the same port. `start()` tries again after that.
            if wasListening, !isStopped { listen() }
        default:
            break
        }
    }

    private func settle(_ result: Result<GameOrigin, Error>) {
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume(with: result) }
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped, let port, connections.count < limits.maxConnections, Self.isLoopback(connection.endpoint) else {
            return connection.cancel()
        }
        let served = GameServerConnection(connection, origin: GameOrigin(port: port, token: token), root: root,
                                          limits: limits, responder: responder, server: self)
        connections[ObjectIdentifier(served)] = served
        served.start()
    }

    fileprivate func remove(_ connection: GameServerConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    /// Whether a peer is on this device.
    nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }
}

enum GameServerError: LocalizedError {
    case stopped

    var errorDescription: String? { "The game's files are no longer served on this device." }
}

/// One connection to a game's server, carrying one request and its answer.
@MainActor
private final class GameServerConnection: GameResponseSink {
    nonisolated let connection: NWConnection
    private let origin: GameOrigin
    private let root: String
    private let limits: GameServer.Limits
    private let responder: GameFileResponder
    private weak var server: GameServer?
    private var buffer = Data()
    private var isClosed = false
    /// The answer is complete and on its way out; nothing more is written.
    private var isFinishing = false
    private var serving: Task<Void, Never>?
    private var deadline: DispatchWorkItem?

    init(_ connection: NWConnection, origin: GameOrigin, root: String, limits: GameServer.Limits,
         responder: GameFileResponder, server: GameServer) {
        self.connection = connection
        self.origin = origin
        self.root = root
        self.limits = limits
        self.responder = responder
        self.server = server
    }

    var isLive: Bool { !isClosed && !isFinishing }

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
        arm(limits.requestTimeout)
        receive()
    }

    private func receive() {
        // Never more than one byte past the bound, so an oversized head is noticed, not kept.
        let room = max(1, limits.maxHeadBytes + 1 - buffer.count)
        connection.receive(minimumIncompleteLength: 1, maximumLength: room) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated { self?.received(data, ended: isComplete || error != nil) }
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        guard !isClosed, serving == nil, !isFinishing else { return }
        if let data { buffer.append(data) }
        switch GameHTTP.parse(buffer, limit: limits.maxHeadBytes) {
        case .incomplete:
            if ended { close() } else { receive() }
        case .reject(let status):
            answer(status)
        case .request(let request):
            buffer = Data()
            switch GameHTTP.route(request, origin: origin, root: root) {
            case .status(let status):
                answer(status)
            case .file(let path, let range, let head):
                arm(limits.progressTimeout)
                let responder = responder
                serving = Task { [weak self] in
                    guard let self else { return }
                    await responder.respond(path: path, range: range, head: head, to: self)
                }
            }
        }
    }

    private func answer(_ status: Int) {
        start(status, headers: GameHTTP.statusHeaders(status))
        finish()
    }

    // MARK: GameResponseSink

    func start(_ status: Int, headers: [String: String]) {
        guard isLive else { return }
        connection.send(content: GameHTTP.head(status, headers: headers), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.abort() }
        })
    }

    func send(_ data: Data) async {
        guard isLive else { return }
        let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
        guard sent else { return abort() }
        arm(limits.progressTimeout)
    }

    func finish() {
        guard isLive else { return }
        isFinishing = true
        // The final message ends the stream (a FIN), after everything sent before it.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func abort() {
        guard !isClosed else { return }
        connection.forceCancel()
        close()
    }

    // MARK: Lifetime

    /// Gives the connection a deadline: without progress by then, it is cut off.
    private func arm(_ seconds: TimeInterval) {
        guard !isClosed else { return }
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.abort() } }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        deadline?.cancel()
        deadline = nil
        serving?.cancel()
        serving = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.remove(self)
    }
}
