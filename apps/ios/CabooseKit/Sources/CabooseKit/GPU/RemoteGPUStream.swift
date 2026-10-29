import Foundation

/// A window drawn on this device from its application's Vulkan calls (docs/gpu-stream.md):
/// `gpu.create` makes one, `gpu.data` feeds it, `gpu.destroy` ends it. Input to the window
/// still goes to the computer, where the application runs.
///
/// The device replays one stream at a time. A stream announced while another plays waits,
/// saying so in its window, and starts when that one ends; its bytes wait in its feed, and
/// the computer holds its application back meanwhile.
@MainActor
public final class RemoteGPUStream: Identifiable {
    public enum Status: Equatable, Sendable {
        case playing
        /// Waiting for the stream drawing window `behind` to end.
        case waiting(behind: Int)
        /// Over; `reason` is why, when the computer ended it early.
        case ended(reason: String?)
    }

    public let id: Int
    public let window: Int
    public private(set) var status: Status
    let feed: GPUStreamFeed
    private let acknowledge: @MainActor (UInt64) -> Void
    /// Counts this stream's replays; an event from an earlier one is ignored.
    private var playback = 0
    #if canImport(UIKit) && canImport(CabooseGPUStream)
    /// The view the stream presents into; the window's interactive view shows it.
    public let view = GPUStreamView()
    #endif

    /// The streams this device replays, the one playing first. Weak: a stream let go without
    /// `end()` (its session dropped) gives up its place on the next look.
    private static var line: [Weak] = []
    private struct Weak { weak var stream: RemoteGPUStream? }

    /// Whether this build can replay GPU streams (`gpu` in the hello).
    public nonisolated static var isSupported: Bool {
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        true
        #else
        false
        #endif
    }

    /// - Parameter acknowledge: told the stream's consumed byte count as the replay takes it.
    init(id: Int, window: Int, feed: GPUStreamFeed, acknowledge: @escaping @MainActor (UInt64) -> Void) {
        self.id = id
        self.window = window
        self.feed = feed
        self.acknowledge = acknowledge
        status = .waiting(behind: window)
        Self.line.append(Weak(stream: self))
        Self.advance()
        if case .waiting = status { show(status) }
    }

    deinit {
        // Its place in line goes with it; the next stream starts.
        Task { @MainActor in RemoteGPUStream.advance() }
    }

    /// The streams still in line, the one playing first.
    static var waitingLine: [RemoteGPUStream] {
        line.removeAll { $0.stream == nil }
        return line.compactMap(\.stream)
    }

    /// Lets the first stream in line play, and tells the others whom they wait for.
    static func advance() {
        let streams = waitingLine
        guard let first = streams.first else { return }
        if first.status != .playing { first.play() }
        for stream in streams.dropFirst() where stream.status != .waiting(behind: first.window) {
            stream.status = .waiting(behind: first.window)
            stream.show(stream.status)
        }
    }

    private func play() {
        status = .playing
        playback += 1
        show(status)
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        let (acknowledge, playback) = (acknowledge, playback)
        let player = view.play { [weak self] event in
            MainActor.assumeIsolated {
                switch event {
                case .consumed(let bytes): acknowledge(bytes)
                case .ended(.failed(let reason)): self?.replayEnded(playback: playback, failure: reason)
                case .ended, .frame: break
                }
            }
        }
        feed.attach { data in player.feed(data) }
        #endif
    }

    /// The replay `playback` stopped on its own with `failure`: the stream ends, says why,
    /// and gives up its place. An event from a replay that is no longer this stream's own does
    /// nothing.
    func replayEnded(playback: Int, failure: String) {
        guard playback == self.playback, status == .playing else { return }
        end(reason: "replay: " + failure)
    }

    /// The current replay, for `replayEnded(playback:failure:)`.
    var currentPlayback: Int { playback }

    /// Stops the replay and lets the next stream in line play. With a `reason` the stream
    /// stays in its window saying why; without one its last frame stays until the view goes.
    func end(reason: String? = nil) {
        if case .ended = status { return }
        status = .ended(reason: reason)
        feed.detach()
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        view.stop()
        #endif
        show(status)
        Self.line.removeAll { $0.stream == nil || $0.stream === self }
        Self.advance()
    }

    /// What the window says over the stream, if anything.
    public nonisolated static func message(for status: Status) -> String? {
        switch status {
        case .playing, .ended(reason: nil):
            nil
        case .waiting:
            "Waiting: this device draws one GPU-streamed app at a time. Close the other one to draw this app here."
        case .ended(reason: "spool-limit"):
            "This app's GPU stream grew past what the computer keeps for one app, so it can't be drawn here any more. Close the app and open it again."
        case .ended(reason: .some(let reason)) where reason.hasPrefix("replay: "):
            "This device could not draw this app's GPU stream: \(reason.dropFirst("replay: ".count)). Close the app and open it again."
        case .ended(reason: .some(let reason)):
            "This app's GPU stream ended (\(reason))."
        }
    }

    private func show(_ status: Status) {
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        view.message = Self.message(for: status)
        #endif
    }
}

/// The socket side of a GPU stream: takes `gpu.data` in order on the socket's queue and hands
/// it to the replay, holding what arrives before the replay is attached on the main actor.
/// A repeated or out-of-order offset (a stream resent from its start) is dropped.
///
/// One caller at a time delivers, outside the lock and in arrival order: whoever finds the
/// queue idle drains it, and anyone arriving meanwhile only queues. The sink is never called
/// under the lock, so it may block or call back in.
final class GPUStreamFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var queued: [Data] = []
    private var sink: ((Data) -> Void)?
    private var delivering = false
    private var ended = false

    /// Bytes accepted so far: the offset the next `gpu.data` must start at.
    var offset: UInt64 { lock.withLock { next } }

    func receive(offset: UInt64, data: Data) {
        let drains: Bool = lock.withLock {
            guard !ended, offset == next else { return false }
            next += UInt64(data.count)
            queued.append(data)
            return claimDelivery()
        }
        if drains { deliver() }
    }

    func attach(_ sink: @escaping (Data) -> Void) {
        let drains: Bool = lock.withLock {
            guard !ended else { return false }
            self.sink = sink
            return claimDelivery()
        }
        if drains { deliver() }
    }

    func detach() {
        lock.withLock {
            ended = true
            sink = nil
            queued.removeAll()
        }
    }

    /// Under the lock: whether the caller becomes the one delivering.
    private func claimDelivery() -> Bool {
        guard sink != nil, !delivering, !queued.isEmpty else { return false }
        delivering = true
        return true
    }

    private func deliver() {
        while true {
            let item: (sink: (Data) -> Void, data: Data)? = lock.withLock {
                guard let sink, !ended, !queued.isEmpty else {
                    delivering = false
                    return nil
                }
                return (sink, queued.removeFirst())
            }
            guard let item else { return }
            item.sink(item.data)
        }
    }
}

/// This connection's GPU streams by id, shared between the socket queue and the main actor.
final class GPUStreamFeeds: @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [Int: GPUStreamFeed] = [:]

    subscript(id: Int) -> GPUStreamFeed? {
        get { lock.withLock { feeds[id] } }
        set { lock.withLock { feeds[id] = newValue } }
    }

    func removeAll() -> [GPUStreamFeed] {
        lock.withLock {
            defer { feeds.removeAll() }
            return Array(feeds.values)
        }
    }
}
