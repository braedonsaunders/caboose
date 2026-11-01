#if canImport(UIKit)
import Foundation
import OSLog

/// The app creates this explicitly for its owner computer. It is never created
/// by CabooseDisplaySession, so agent, thumbnail and auxiliary connections cannot
/// accidentally become a GPU executor. One instance is one executor; a new one replaces it once it ends.
@MainActor
public final class LiveGPUOwnerSession {
    private static let log = Logger(subsystem: "org.caboose", category: "LiveGPUOwner")
    public enum State: Equatable { case idle, connecting, connected, draining, ended(cleanupFailed: Bool) }
    /// Suspension in place across the background (docs/gpu-live.md, "Suspending an executor").
    public enum Suspension: Equatable { case none, suspending, suspended, quiesced }
    public private(set) var suspension = Suspension.none
    private var closesTransportWhenQuiesced = false
    public private(set) var state = State.idle
    public let presentationOwners: LiveGPUPresentationOwners
    /// A new executor may follow once this one has ended. A transport loss never brings the
    /// remote retirement receipt, but the host relay ends only after both of its sides close
    /// and the broker revokes the old lease, so the server fences the old one. Native cleanup
    /// that failed (as after a lost device) does not hold the phone's GPU: the failed
    /// executor is kept alive with whatever native state it still holds, and a new one,
    /// with new processes and a new device, takes over.
    public var canReplace: Bool {
        if case .ended = state { return true }
        return false
    }
    // The running executor survives UI/session ARC until it ends, never released on view
    // dismissal; one whose native cleanup failed is kept for the life of the app.
    private static var retainedExecutor: LiveGPUOwnerSession?
    private static var failedExecutors: [LiveGPUOwnerSession] = []
    private let executor: LiveGPUSession
    private let onEnd: @MainActor (Error?, Error?) -> Void
    private final class Reference { weak var owner: LiveGPUOwnerSession? }

    /// `pairing` names the computer's persistent GPU caches (LiveGPUCacheRoot); without it,
    /// or if they cannot be created, the computer sends every shader in full.
    public init(hostURL: URL, phoneToken: String, pairing: String? = nil,
                onEnd: @escaping @MainActor (Error?, Error?) -> Void) throws {
        let reference = Reference()
        let owners = LiveGPUPresentationOwners { [reference] identity in
            reference.owner?.executor.requestSurfaceRevocation(identity)
        }
        let cacheRoot = pairing.flatMap { try? LiveGPUCacheRoot.directory(pairing: $0) }
        let binding = try LiveGPUNativeBinding(presentationOwners: owners, cacheRoot: cacheRoot)
        // The transport resumes this executor across a lost socket when the computer offers it.
        executor = try LiveGPUSession(transport: LiveGPUResumableTransport(hostURL: hostURL, phoneToken: phoneToken),
                                      nativeBinding: binding)
        presentationOwners = owners; self.onEnd = onEnd
        reference.owner = self
    }
    public func start() throws {
        guard state == .idle, Self.retainedExecutor == nil else { throw LiveGPUError.closed }
        Self.retainedExecutor = self
        state = .connecting
        Self.log.info("Owner executor connecting")
        executor.start { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .transportOpened:
                    // Transport acceptance does not imply SESSION_READY or a surface.
                    if self.state == .connecting { self.state = .connected }
                    Self.log.info("Owner GPU transport opened")
                case .ended(let cause, let cleanupError):
                    self.presentationOwners.revoke()
                    self.state = .ended(cleanupFailed: cleanupError != nil)
                    if Self.retainedExecutor === self {
                        Self.retainedExecutor = nil
                        if cleanupError != nil { Self.failedExecutors.append(self) }
                    }
                    Self.log.info("Owner executor ended: cause=\(cause != nil, privacy: .public) cleanupFailed=\(cleanupError != nil, privacy: .public) retirementConfirmed=\(self.executor.remoteRetirementCompleted, privacy: .public)")
                    // Also on standard output, which device consoles capture when the log is not.
                    print("CABOOSE_GPU_OWNER_ENDED cause=\(cause.map { String(describing: $0) } ?? "none") " +
                          "cleanup=\(cleanupError.map { String(describing: $0) } ?? "ok") " +
                          "retirement_confirmed=\(self.executor.remoteRetirementCompleted ? 1 : 0)")
                    fflush(stdout)
                    self.onEnd(cause, cleanupError)
                }
            }
        }
    }
    /// Call after the ordinary display hello/windows change. A READY-induced
    /// display reconnect does not reconstruct this independent executor.
    public func update(display: CabooseDisplaySession) {
        guard display.state == .ready else { return }
        switch state {
        case .idle, .connecting, .connected:
            presentationOwners.update(epoch: display.server?.gpuLiveEpoch, windows: display.windows)
        case .draining, .ended: break
        }
    }
    /// Suspends the executor in place as the app leaves the foreground: its objects, memory and
    /// surfaces stay, and the computer holds its applications. `completion(false)` when it
    /// cannot (the computer does not resume executors, or it is ending); close it then.
    public func suspend(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard suspension == .none, state == .connecting || state == .connected else { completion(false); return }
        suspension = .suspending
        executor.suspend(quiesced: { [weak self] in
            Task { @MainActor in self?.quiesced() }
        }, done: { [weak self] suspended in
            Task { @MainActor in
                guard let self else { return }
                if self.suspension == .suspending { self.suspension = suspended ? .suspended : .none }
                Self.log.info("Owner executor suspend: \(suspended, privacy: .public)")
                print("CABOOSE_GPU_OWNER suspend=\(suspended ? 1 : 0)"); fflush(stdout)
                completion(suspended)
            }
        })
    }
    private func quiesced() {
        guard suspension == .suspended || suspension == .suspending else { return }
        suspension = .quiesced
        print("CABOOSE_GPU_OWNER quiesced background=\(closesTransportWhenQuiesced ? 1 : 0)"); fflush(stdout)
        if closesTransportWhenQuiesced { executor.suspendTransport() }
    }
    /// In the background: closes the suspended executor's socket once the broker holds it, so
    /// the host keeps it for its extended window rather than ending it as silent.
    public func closeTransportWhenQuiesced() {
        closesTransportWhenQuiesced = true
        if suspension == .quiesced { executor.suspendTransport() }
    }
    /// Back in the foreground: reconnects if needed and continues the suspended executor.
    public func resume() {
        guard suspension != .none else { return }
        suspension = .none; closesTransportWhenQuiesced = false
        Self.log.info("Owner executor resumed")
        print("CABOOSE_GPU_OWNER resume"); fflush(stdout)
        executor.resume()
    }
    public func close() {
        switch state {
        case .draining, .ended: return
        default: break
        }
        state = .draining
        Self.log.info("Owner executor drain requested")
        presentationOwners.revoke()
        executor.close()
    }
    /// Used when the app cannot retain a foreground transport. This does not
    /// manufacture remote release; the broker remains responsible for fencing.
    public func abort() {
        switch state { case .ended: return; default: break }
        state = .draining
        Self.log.info("Owner executor abort requested; remote retirement remains unconfirmed")
        presentationOwners.revoke()
        executor.abort()
    }
}
#endif
