#if canImport(CabooseGPUStream)
import CabooseGPUStream
import Foundation
import QuartzCore

/// Replays a window's GPU stream (docs/gpu-stream.md) on this device's GPU into a
/// `CAMetalLayer`: GFXReconstruct's Vulkan replay through MoltenVK, on a thread of its own.
///
/// Feed the stream's bytes in order as they arrive; `feed` returns at once and the bytes are
/// handed to the replay in order, as fast as it takes them. Events arrive on `queue`:
/// each replayed frame, each fed chunk the replay has taken (its running byte total, which is
/// the offset a `gpu.ack` reports), and the end.
///
/// GFXReconstruct's decoder keeps process-wide state, so one player replays at a time: a
/// player started while another is replaying waits for that one to stop.
public final class GPUStreamPlayer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case running
        /// Every frame of a finished stream was replayed, or the player was stopped.
        case finished
        case failed(String)
    }

    public enum Event: Equatable, Sendable {
        /// Frames replayed and presented so far.
        case frame(UInt64)
        /// Bytes of the stream the replay has taken so far.
        case consumed(UInt64)
        case ended(State)
    }

    private let core: Core

    /// Starts a player presenting into `layer`, which it keeps until it is released.
    public init(layer: CAMetalLayer, queue: DispatchQueue = .main, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        core = Core(layer: layer, sink: EventSink(queue: queue, handler: onEvent))
    }

    deinit {
        // Destroying the C player joins the replay thread: do it on the feed queue, after the
        // feeds already queued, never on the caller's thread.
        let core = core
        core.cancel()
        core.feeding.async { withExtendedLifetime(core) {} }
    }

    /// Frames replayed and presented so far.
    public var framesRendered: UInt64 { cgpu_player_frames(core.handle) }

    public var state: State { core.state }

    /// Bytes of the stream the replay has taken so far.
    public var consumedBytes: UInt64 { core.consumedBytes }

    /// Hands the next bytes of the stream to the replay. Bytes fed after the replay stopped are
    /// dropped.
    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let core = core
        core.feeding.async { core.write(data) }
    }

    /// Ends the stream after the bytes fed so far; the replay finishes their frames and stops.
    public func finish() {
        let core = core
        core.feeding.async { cgpu_player_finish(core.handle) }
    }

    /// Stops the replay after the frame it is on, dropping bytes not yet taken.
    public func stop() { core.cancel() }

    /// Waits until the replay stops, and returns how it stopped.
    public func waitUntilEnded() async -> State {
        let core = core
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = cgpu_player_wait(core.handle)
                continuation.resume(returning: core.state)
            }
        }
    }
}

extension GPUStreamPlayer {
    /// Owns the C player. Queued feeds keep it alive, so it is destroyed after the last of them.
    fileprivate final class Core: @unchecked Sendable {
        let handle: OpaquePointer
        let feeding = DispatchQueue(label: "com.braedonsaunders.caboose.gpu-stream.feed", qos: .userInteractive)
        private let sink: Unmanaged<EventSink>
        private let lock = NSLock()
        private var consumed: UInt64 = 0

        init(layer: CAMetalLayer, sink: EventSink) {
            let retained = Unmanaged.passRetained(sink)
            guard let handle = cgpu_player_create(Unmanaged.passUnretained(layer).toOpaque(), gpuStreamEvent,
                                                  retained.toOpaque())
            else { preconditionFailure("cgpu_player_create refused a CAMetalLayer") }
            self.handle = handle
            self.sink = retained
        }

        deinit {
            cgpu_player_destroy(handle)
            sink.release()
        }

        var consumedBytes: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return consumed
        }

        var state: State {
            switch cgpu_player_state(handle) {
            case CGPU_STATE_RUNNING: return .running
            case CGPU_STATE_FINISHED: return .finished
            default:
                let length = cgpu_player_copy_error(handle, nil, 0)
                var message = [CChar](repeating: 0, count: length + 1)
                _ = cgpu_player_copy_error(handle, &message, message.count)
                return .failed(String(cString: message))
            }
        }

        func write(_ data: Data) {
            let taken = data.withUnsafeBytes { cgpu_player_feed(handle, $0.baseAddress, $0.count) == 0 }
            guard taken else { return }
            lock.lock()
            consumed += UInt64(data.count)
            let total = consumed
            lock.unlock()
            sink.takeUnretainedValue().send(.consumed(total))
        }

        func cancel() { cgpu_player_cancel(handle) }
    }

    fileprivate final class EventSink: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: @Sendable (Event) -> Void

        init(queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) {
            self.queue = queue
            self.handler = handler
        }

        func send(_ event: Event) {
            let handler = handler
            queue.async { handler(event) }
        }
    }
}

/// The replay thread's events, into the player's `EventSink`.
private let gpuStreamEvent: cgpu_event_callback = { context, status in
    guard let context, let status = status?.pointee else { return }
    let sink = Unmanaged<GPUStreamPlayer.EventSink>.fromOpaque(context).takeUnretainedValue()
    switch status.event {
    case CGPU_EVENT_FRAME:
        sink.send(.frame(status.frames))
    default:
        let state: GPUStreamPlayer.State = switch status.state {
        case CGPU_STATE_RUNNING: .running
        case CGPU_STATE_FINISHED: .finished
        default: .failed(status.error.map { String(cString: $0) } ?? "")
        }
        sink.send(.ended(state))
    }
}
#endif
