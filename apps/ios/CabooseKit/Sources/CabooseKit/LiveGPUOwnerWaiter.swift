import Foundation
import Darwin

/// Cross-channel display metadata can arrive after BIND. Retry only when actual
/// owner state changes; one finite deadline bounds each retained request.
@MainActor
final class LiveGPUOwnerWaiter<Value: Sendable> {
    private struct Pending {
        let resolve: @MainActor () throws -> Value
        let complete: @MainActor (Result<Value, Error>) -> Void
        let deadline: DispatchWorkItem
    }
    private var requests: [UUID: Pending] = [:]
    private let timeout: TimeInterval
    private let capacity: Int
    private var cancelled = false
    init(timeout: TimeInterval = 3, capacity: Int = 32) {
        precondition(timeout > 0 && timeout.isFinite && capacity > 0)
        self.timeout = timeout; self.capacity = capacity
    }
    var pendingCount: Int { requests.count }
    func request(resolve: @escaping @MainActor () throws -> Value,
                 complete: @escaping @MainActor (Result<Value, Error>) -> Void) {
        guard !cancelled else { complete(.failure(error(ECANCELED))); return }
        guard requests.count < capacity else { complete(.failure(error(ENOSPC))); return }
        do { complete(.success(try resolve())); return }
        catch { if !Self.pending(error) { complete(.failure(error)); return } }
        let id = UUID()
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(id, .failure(Self.timeoutError())) }
        }
        requests[id] = Pending(resolve: resolve, complete: complete, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }
    func retry() {
        for (id, request) in requests {
            guard requests[id] != nil else { continue }
            do { finish(id, .success(try request.resolve())) }
            catch { if !Self.pending(error) { finish(id, .failure(error)) } }
        }
    }
    func cancel() {
        cancelled = true
        for id in Array(requests.keys) { finish(id, .failure(error(ECANCELED))) }
    }
    private func finish(_ id: UUID, _ result: Result<Value, Error>) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.complete(result)
    }
    private static func pending(_ error: Error) -> Bool {
        guard let error = error as? LiveGPUBindingError,
              case .native(_, let code) = error else { return false }
        return code == EAGAIN
    }
    private static func timeoutError() -> LiveGPUBindingError { .native(operation: "visible owner deadline", code: EAGAIN) }
    private func error(_ code: Int32) -> LiveGPUBindingError { .native(operation: "visible owner admission", code: code) }
}
