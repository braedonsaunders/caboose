import Foundation
import Darwin

/// Routes each surface bind to the presentation backend of its seat (docs/gpu-live.md, "Seats").
/// One executor serves both of the computer's seats; a window bound for one seat presents only in
/// that seat's display session. With no session open for a seat its binds are answered with
/// ENOENT and dropped: an agent-seat window is never shown in the owner's display. A bound
/// surface keeps the backend it was bound with, so a seat closing later ends its windows there
/// (the owners registry invalidates them), never moves them to another seat.
final class LiveGPUSeatSurfaces: LiveGPUSurfaceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [LiveGPUSeat: any LiveGPUSurfaceBackend]

    init(owner: any LiveGPUSurfaceBackend) { backends = [.owner: owner] }

    /// Opens (`backend`) or closes (`nil`) a seat other than the owner's.
    func attach(_ backend: (any LiveGPUSurfaceBackend)?, seat: LiveGPUSeat) {
        precondition(seat != .owner, "the owner's seat is fixed for the executor's life")
        lock.withLock { backends[seat] = backend }
    }

    func bind(identity: LiveGPUSurfaceIdentity, processToken: UInt64, window: UInt64,
              instance: UInt64, width: UInt32, height: UInt32, seat: LiveGPUSeat) throws -> LiveGPUSurfaceBinding {
        guard let backend = lock.withLock({ backends[seat] }) else {
            return .init(status: .init(nativeErrno: ENOENT, vkResult: nil), resource: nil)
        }
        return try backend.bind(identity: identity, processToken: processToken, window: window,
                                instance: instance, width: width, height: height, seat: seat)
    }
}
