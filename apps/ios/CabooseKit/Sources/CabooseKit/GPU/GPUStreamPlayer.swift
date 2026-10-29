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
/// Players replay concurrently on independent threads with per-thread decoder state.
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
    /// dropped. `before`, if given, runs on the feed queue just before the replay is handed the
    /// bytes, and not for bytes `discardPending` drops.
    public func feed(_ data: Data, before: (@Sendable () -> Void)? = nil) {
        guard !data.isEmpty else { return }
        let core = core
        let generation = core.generation
        core.feeding.async { core.write(data, generation: generation, before: before) }
    }

    /// Hands the replay the first `length` bytes of the file at `url` (the start of the stream),
    /// ahead of anything fed after this call: a chunk at a time, each when the replay has taken
    /// the last, so the replay sets the pace and no more than a chunk is held. Every frame is
    /// replayed and presented as it would be from the network. Reports, on the event queue, the
    /// offset the replay has accepted when it is done: all of `length`, or less when the file
    /// could not be read or `discardPending` was called; nil when the replay stopped.
    public func feed(contentsOf url: URL, length: UInt64, completion: @escaping @Sendable (UInt64?) -> Void) {
        let core = core
        let generation = core.generation
        core.feeding.async {
            var fed: UInt64 = 0
            if let file = try? FileHandle(forReadingFrom: url) {
                while fed < length, core.generation == generation {
                    let count = Int(min(UInt64(Self.fileChunk), length - fed))
                    let data = autoreleasepool { try? file.read(upToCount: count) }
                    guard let data, !data.isEmpty, core.write(data, generation: generation) else { break }
                    fed += UInt64(data.count)
                }
                try? file.close()
            }
            let accepted: UInt64? = core.state == .running ? core.consumedBytes : nil
            core.sink.takeUnretainedValue().queue.async { completion(accepted) }
        }
    }

    /// Bytes read from a file and handed to the replay at a time.
    static let fileChunk = 512 << 10

    /// Drops the bytes handed to `feed` that the replay has not taken yet, then reports, on the
    /// event queue, the offset the replay has accepted: every byte before it was taken by this
    /// replay (`cgpu_player_feed` returned for it), and none after. A chunk the replay is being
    /// handed when this is called is waited for. Nil when the replay has stopped, so it takes no
    /// more and cannot be continued. Bytes fed after this call continue from that offset.
    public func discardPending(_ completion: @escaping @Sendable (UInt64?) -> Void) {
        let core = core
        core.nextGeneration()
        core.feeding.async {
            let accepted: UInt64? = core.state == .running ? core.consumedBytes : nil
            core.sink.takeUnretainedValue().queue.async { completion(accepted) }
        }
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
        let sink: Unmanaged<EventSink>
        private let lock = NSLock()
        private var consumed: UInt64 = 0
        /// Bumped by `discardPending`: a chunk fed before it is dropped unless already taken.
        private var currentGeneration = 0

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

        var generation: Int {
            lock.lock()
            defer { lock.unlock() }
            return currentGeneration
        }

        func nextGeneration() {
            lock.lock()
            currentGeneration += 1
            lock.unlock()
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

        /// Hands `data` to the replay, unless `discardPending` dropped it; whether it was taken.
        @discardableResult
        func write(_ data: Data, generation: Int, before: (@Sendable () -> Void)? = nil) -> Bool {
            guard generation == self.generation else { return false }
            before?()
            let taken = data.withUnsafeBytes { cgpu_player_feed(handle, $0.baseAddress, $0.count) == 0 }
            guard taken else { return false }
            lock.lock()
            consumed += UInt64(data.count)
            let total = consumed
            lock.unlock()
            sink.takeUnretainedValue().send(.consumed(total))
            return true
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
