import Foundation

/// A window drawn on this device from its application's Vulkan calls (docs/gpu-stream.md):
/// `gpu.create` makes one, `gpu.data` feeds it, `gpu.destroy` ends it. Input to the window
/// still goes to the computer, where the application runs.
///
/// A playing stream's replay is kept through a lost connection (`suspend()`) and continues on
/// the next one when the computer resumes it there (`resume(feed:acknowledge:seek:)`). What
/// arrives is kept in the device's copy of the stream (`GPUStreamCache`); a new replay of a
/// stream the device holds the start of takes that from there and asks the computer for the
/// rest (`gpu.seek`).
///
/// Every stream replays as soon as it is announced, on its own replay thread, alongside any
/// other the device is drawing.
@MainActor
public final class RemoteGPUStream: Identifiable {
    public enum Status: Equatable, Sendable {
        case playing
        /// Over; `reason` is why, when the computer ended it early.
        case ended(reason: String?)
    }

    /// How a stream kept through a lost connection stands.
    enum Suspension: Equatable {
        /// The replay is still taking the chunk it was being handed.
        case settling
        /// The replay has accepted exactly this many bytes, and can continue from there.
        case at(UInt64)
        /// The replay stopped; it cannot continue.
        case lost
    }

    public let id: Int
    public let window: Int
    /// Names the stream for resuming; nil from a computer that names none.
    public let nonce: String?
    public private(set) var status: Status
    /// The connection's feed this stream takes its bytes from.
    private(set) var feed: GPUStreamFeed
    /// Where a new replay takes the stream's start from.
    let start: GPUStreamResume.Start
    /// The device's copy of the stream, while it keeps one.
    private let cache: GPUStreamCache.Stream?
    private var acknowledge: @MainActor (UInt64) -> Void
    /// Tells the computer where the stream continues for this replay (`gpu.seek`).
    private var seek: @MainActor (UInt64) -> Void
    /// Whether what the replay takes is acknowledged: not while it takes the device's copy, which
    /// the computer has no need to send.
    private var acking = true
    /// Set while the stream is kept through a lost connection.
    private(set) var suspension: Suspension?
    /// Counts this stream's replays; an event from an earlier one is ignored.
    private var playback = 0
    #if canImport(UIKit) && canImport(CabooseGPUStream)
    /// The view the stream presents into; the window's interactive view shows it.
    public let view = GPUStreamView()
    #endif

    /// Whether this build can replay GPU streams (`gpu` in the hello).
    public nonisolated static var isSupported: Bool {
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        true
        #else
        false
        #endif
    }

    /// - Parameters:
    ///   - start: where the replay takes the stream's start from.
    ///   - cache: the device's copy of the stream, which keeps what arrives.
    ///   - acknowledge: told the stream's consumed byte count as the replay takes it.
    ///   - seek: tells the computer to continue the stream at an offset.
    init(id: Int, window: Int, nonce: String? = nil, feed: GPUStreamFeed, start: GPUStreamResume.Start = .network,
         cache: GPUStreamCache.Stream? = nil, acknowledge: @escaping @MainActor (UInt64) -> Void,
         seek: @escaping @MainActor (UInt64) -> Void = { _ in }) {
        self.id = id
        self.window = window
        self.nonce = nonce
        self.feed = feed
        self.start = start
        self.cache = cache
        self.acknowledge = acknowledge
        self.seek = seek
        status = .playing
        play()
    }

    private func play() {
        playback += 1
        show(status)
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        let playback = playback
        let player = view.play { [weak self] event in
            MainActor.assumeIsolated {
                switch event {
                case .consumed(let bytes): self?.consumed(bytes, playback: playback)
                case .ended(.failed(let reason)): self?.replayEnded(playback: playback, failure: reason)
                case .ended, .frame: break
                }
            }
        }
        switch start {
        case .network:
            attachNetwork(player)
        case .seekToStart:
            // The computer continues the stream further on, for a replay this device lost.
            feed.restart(at: 0)
            seek(0)
            attachNetwork(player)
        case .cached(let length):
            guard let cache else { return attachNetwork(player) }
            acking = false
            player.feed(contentsOf: cache.dataURL, length: length) { [weak self] accepted in
                MainActor.assumeIsolated { self?.cachedStartTaken(accepted, playback: playback, player: player) }
            }
        }
        #endif
    }

    #if canImport(UIKit) && canImport(CabooseGPUStream)
    /// The stream's bytes from the connection go to the replay, and into the device's copy just
    /// before the replay takes them.
    private func attachNetwork(_ player: GPUStreamPlayer) {
        acking = true
        let cache = cache
        feed.attach { offset, data in
            if let cache {
                player.feed(data) { cache.write(data, at: offset) }
            } else {
                player.feed(data)
            }
        }
    }

    /// The replay took the device's copy up to `accepted` (all of it, unless reading it failed):
    /// the computer continues the stream from exactly there.
    private func cachedStartTaken(_ accepted: UInt64?, playback: Int, player: GPUStreamPlayer) {
        guard playback == self.playback, status == .playing, suspension == nil, let accepted else { return }
        feed.restart(at: accepted)
        seek(accepted)
        attachNetwork(player)
    }
    #endif

    private func consumed(_ bytes: UInt64, playback: Int) {
        guard playback == self.playback, acking else { return }
        acknowledge(bytes)
    }

    /// The connection went: keeps the replay for the next one, when it can. Bytes received and
    /// not yet taken by the replay are dropped; once the replay has taken the chunk it was
    /// being handed, `suspension` says how far it got. Returns false for a stream that cannot
    /// be kept (ended, unnamed by the computer, or with no running replay), which the caller
    /// ends.
    func suspend() -> Bool {
        guard status == .playing, nonce != nil, suspension == nil else { return false }
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        guard let player = view.player, player.state == .running else { return false }
        feed.detach()
        acknowledge = { _ in }
        seek = { _ in }
        cache?.commit()
        suspension = .settling
        let playback = playback
        player.discardPending { [weak self] accepted in
            MainActor.assumeIsolated {
                guard let self, self.playback == playback, self.suspension == .settling else { return }
                self.suspension = accepted.map(Suspension.at) ?? .lost
            }
        }
        return true
        #else
        return false
        #endif
    }

    /// The offset a kept replay continues from: settled, and the replay still running.
    var resumableOffset: UInt64? {
        guard status == .playing, case .at(let offset) = suspension else { return nil }
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        guard view.player?.state == .running else { return nil }
        #endif
        return offset
    }

    /// The stream as `GPUStreamResume.plan` weighs it.
    var kept: GPUStreamResume.Kept {
        let ended = if case .ended = status { true } else { false }
        return GPUStreamResume.Kept(id: id, nonce: nonce, ended: ended, resumable: resumableOffset, suspended: suspension != nil)
    }

    /// Continues the kept replay on a new connection, whose `feed` starts where the replay
    /// stands.
    func resume(feed: GPUStreamFeed, acknowledge: @escaping @MainActor (UInt64) -> Void,
                seek: @escaping @MainActor (UInt64) -> Void) {
        guard suspension != nil else { return }
        self.feed = feed
        self.acknowledge = acknowledge
        self.seek = seek
        suspension = nil
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        if let player = view.player { attachNetwork(player) }
        #endif
    }

    /// The stream is over on the computer: nothing kept of it can be replayed again.
    func discardCache() {
        cache?.discard()
    }

    /// The replay `playback` stopped on its own with `failure`: the stream ends and says why.
    /// An event from a replay that is no longer this stream's own does nothing.
    func replayEnded(playback: Int, failure: String) {
        guard playback == self.playback, status == .playing else { return }
        // Replayed again, the same bytes would fail the same way.
        cache?.discard()
        end(reason: "replay: " + failure)
    }

    /// The current replay, for `replayEnded(playback:failure:)`.
    var currentPlayback: Int { playback }

    /// Stops the replay. With a `reason` the stream stays in its window saying why; without one
    /// its last frame stays until the view goes.
    func end(reason: String? = nil) {
        if case .ended = status { return }
        status = .ended(reason: reason)
        feed.detach()
        cache?.close()
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        view.stop()
        #endif
        show(status)
    }

    /// What the window says over the stream, if anything.
    public nonisolated static func message(for status: Status) -> String? {
        switch status {
        case .playing, .ended(reason: nil):
            nil
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
/// it to the replay with its offset, holding what arrives before the replay is attached on the
/// main actor. A stream that resumes a kept replay starts at the offset `gpu.create` resumed it
/// at; one whose start the replay took from the device's copy restarts where that ended.
///
/// The bytes at an offset never change, so a chunk that overlaps the next offset brings what
/// follows it, and one wholly before it (a resent part) or past it brings nothing.
///
/// One caller at a time delivers, outside the lock and in arrival order: whoever finds the
/// queue idle drains it, and anyone arriving meanwhile only queues. The sink is never called
/// under the lock, so it may block or call back in.
final class GPUStreamFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var queued: [(offset: UInt64, data: Data)] = []
    private var sink: ((UInt64, Data) -> Void)?
    private var delivering = false
    private var ended = false

    init(offset: UInt64 = 0) {
        next = offset
    }

    /// Bytes accepted so far: the offset the next `gpu.data` must start at.
    var offset: UInt64 { lock.withLock { next } }

    func receive(offset: UInt64, data: Data) {
        let drains: Bool = lock.withLock {
            let end = offset + UInt64(data.count)
            guard !ended, offset <= next, end > next else { return false }
            queued.append((next, offset == next ? data : Data(data.dropFirst(Int(next - offset)))))
            next = end
            return claimDelivery()
        }
        if drains { deliver() }
    }

    /// Drops what is queued and takes the stream from `offset` on: the replay has everything
    /// before it.
    func restart(at offset: UInt64) {
        lock.withLock {
            queued.removeAll()
            next = offset
        }
    }

    func attach(_ sink: @escaping (UInt64, Data) -> Void) {
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
            let item: (sink: (UInt64, Data) -> Void, chunk: (offset: UInt64, data: Data))? = lock.withLock {
                guard let sink, !ended, !queued.isEmpty else {
                    delivering = false
                    return nil
                }
                return (sink, queued.removeFirst())
            }
            guard let item else { return }
            item.sink(item.chunk.offset, item.chunk.data)
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
