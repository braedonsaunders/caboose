import CoreGraphics
import Foundation

/// Synthetic taps need a real down interval: some desktop UI loops sample button state
/// once per frame and never observe a press and release delivered together.
@MainActor
public final class PointerClickDriver {
    public typealias Sleep = @MainActor (UInt64) async throws -> Void
    private let sleep: Sleep
    private var pending: [(Bool) -> Bool] = []
    private var active: ((Bool) -> Bool)?
    private(set) var task: Task<Void, Never>?
    private var generation = 0

    public init(sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
    }

    public func click(send: @escaping (Bool) -> Bool) {
        pending.append(send)
        startNext()
    }

    public func click(in window: RemoteWindow, session: any DisplaySession, at point: CGPoint, button: Int = 1) {
        let epoch = session.epoch
        let connection = (session as? CabooseDisplaySession)?.connections
        click { [weak session, weak window] pressed in
            guard let session, let window, session.state == .ready,
                  session.epoch == epoch, (session as? CabooseDisplaySession)?.connections == connection,
                  session.windows[window.id] === window else { return false }
            session.pointerButton(in: window, button: button, pressed: pressed, at: point)
            return true
        }
    }

    /// Release the old target before a drag, detachment or ownership change; drop queued taps.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pending.removeAll()
        let release = active
        active = nil
        _ = release?(false)
    }

    private func startNext() {
        guard task == nil else { return }
        while !pending.isEmpty {
            let send = pending.removeFirst()
            guard send(true) else { continue }
            active = send
            let ticket = generation
            task = Task { [self] in
                do {
                    try await sleep(100_000_000)
                    guard generation == ticket, !Task.isCancelled else { return }
                    active = nil
                    _ = send(false)
                    // A queued double-click also needs an observable up between presses.
                    try await sleep(20_000_000)
                    guard generation == ticket, !Task.isCancelled else { return }
                    task = nil
                    startNext()
                } catch {
                    if generation == ticket { cancel() }
                }
            }
            return
        }
    }
}
