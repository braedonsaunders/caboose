import CabooseKit
import Foundation

/// The host's own routes for its computers (docs/architecture.md § Computers): listing them,
/// making one, and starting it with its boot followed as it happens. These are never scoped
/// to a computer, whichever the client has open.
extension HostClient {
    func computers() async throws -> HostComputerList { try await request("GET", "/v1/computers", timeout: 20) }

    /// Makes a computer and starts it at once (`start: true`), exactly as `startBoot` would.
    func createComputer(name: String, size: String) async throws -> HostComputerList.Computer {
        try await request("POST", "/v1/computers", body: [
            "name": .string(name), "size": .string(size), "start": .bool(true),
        ], timeout: 60)
    }

    /// Starts the computer unless it is already running or starting; also the retry after a
    /// failed boot. Answers with the attempt now under way.
    func startBoot(computer id: String) async throws -> ComputerBoot? {
        let reply: ComputerBootEnvelope = try await request("POST", Self.bootPath(id), timeout: 30)
        return reply.boot
    }

    func boot(computer id: String) async throws -> ComputerBoot? {
        let reply: ComputerBootEnvelope = try await request("GET", Self.bootPath(id), timeout: 20)
        return reply.boot
    }

    /// The boot as Server-Sent Events: the current attempt at once, then every change, until
    /// an event whose attempt has finished. The stream ends there, or throws when the
    /// connection drops; the host's keepalive arrives every 15 s, so a silence of 45 s is a
    /// dropped connection.
    func bootEvents(computer id: String) -> AsyncThrowingStream<ComputerBoot?, Error> {
        var request = URLRequest(url: endpoint(Self.bootPath(id)), timeoutInterval: 45)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200 ..< 300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes where body.count < 16_384 { body.append(byte) }
                        throw Self.failure(status: status, body: body)
                    }
                    var parser = ServerSentEvents()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        line.append(byte)
                        guard byte == 0x0A || byte == 0x0D else { continue }
                        for event in parser.feed(line) where event.name == "boot" {
                            let boot = try ComputerBootEnvelope.decode(Data(event.data.utf8)).boot
                            continuation.yield(boot)
                            if boot?.isFinished == true { continuation.finish(); return }
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch let failure as Failure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Failure.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func bootPath(_ id: String) -> String { "/v1/computers/\(pathComponent(id))/boot" }

    private static func failure(status: Int, body: Data) -> Failure {
        let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        return status == 401 || status == 403 ? .unauthorized : .server(status, message)
    }
}
