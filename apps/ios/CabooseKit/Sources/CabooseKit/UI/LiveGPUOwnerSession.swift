#if canImport(UIKit)
import Foundation

/// The app creates this explicitly for its owner computer. It is never created
/// by CabooseDisplaySession, so agent, thumbnail and auxiliary connections cannot
/// accidentally become a GPU executor. One instance is one nonrestartable lease.
@MainActor
public final class LiveGPUOwnerSession {
    public enum State: Equatable { case idle, connecting, connected, draining, ended(cleanupFailed: Bool) }
    public private(set) var state = State.idle
    public let presentationOwners: LiveGPUPresentationOwners
    // Failed native retirement must survive UI/session ARC. This reservation is
    // released only after local native cleanup succeeds, never on view dismissal.
    private static var retainedExecutor: LiveGPUOwnerSession?
    private let executor: LiveGPUSession
    private let onEnd: @MainActor (Error?, Error?) -> Void
    private final class Reference { weak var owner: LiveGPUOwnerSession? }

    public init(hostURL: URL, phoneToken: String,
                onEnd: @escaping @MainActor (Error?, Error?) -> Void) throws {
        let reference = Reference()
        let owners = LiveGPUPresentationOwners { [reference] in reference.owner?.close() }
        let binding = try LiveGPUNativeBinding(presentationOwners: owners)
        executor = try LiveGPUSession(transport: LiveGPUConnection(hostURL: hostURL, phoneToken: phoneToken),
                                      nativeBinding: binding)
        presentationOwners = owners; self.onEnd = onEnd
        reference.owner = self
    }
    public func start() throws {
        guard state == .idle, Self.retainedExecutor == nil else { throw LiveGPUError.closed }
        Self.retainedExecutor = self
        state = .connecting
        executor.start { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .transportOpened:
                    // Transport acceptance does not imply SESSION_READY or a surface.
                    if self.state == .connecting { self.state = .connected }
                case .ended(let cause, let cleanupError):
                    self.presentationOwners.revoke()
                    self.state = .ended(cleanupFailed: cleanupError != nil)
                    if cleanupError == nil, Self.retainedExecutor === self { Self.retainedExecutor = nil }
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
    public func close() {
        switch state {
        case .draining, .ended: return
        default: break
        }
        state = .draining
        presentationOwners.revoke()
        executor.close()
    }
    /// Used when the app cannot retain a foreground transport. This does not
    /// manufacture remote release; the broker remains responsible for fencing.
    public func abort() {
        switch state { case .ended: return; default: break }
        state = .draining
        presentationOwners.revoke()
        executor.abort()
    }
}
#endif
