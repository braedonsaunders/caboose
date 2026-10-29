import Foundation

/// A window drawn on this device from its application's Vulkan calls (docs/gpu-stream.md):
/// `gpu.create` makes one, `gpu.data` feeds it, `gpu.destroy` ends it. Input to the window
/// still goes to the computer, where the application runs.
@MainActor
public final class RemoteGPUStream: Identifiable {
    public let id: Int
    public let window: Int
    let feed: GPUStreamFeed
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

    /// - Parameter acknowledge: told the stream's consumed byte count as the replay takes it.
    init(id: Int, window: Int, feed: GPUStreamFeed, acknowledge: @escaping @MainActor (UInt64) -> Void) {
        self.id = id
        self.window = window
        self.feed = feed
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        let player = view.play { event in
            if case .consumed(let bytes) = event { MainActor.assumeIsolated { acknowledge(bytes) } }
        }
        feed.attach { data in player.feed(data) }
        #endif
    }

    /// Stops the replay; the last frame stays in the view until it goes.
    func end() {
        feed.detach()
        #if canImport(UIKit) && canImport(CabooseGPUStream)
        view.stop()
        #endif
    }
}

/// The socket side of a GPU stream: takes `gpu.data` in order on the socket's queue and hands
/// it to the replay, holding what arrives before the replay is attached on the main actor.
/// A repeated or out-of-order offset (a stream resent from its start) is dropped.
final class GPUStreamFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var held: [Data] = []
    private var sink: ((Data) -> Void)?
    private var ended = false

    /// Bytes accepted so far: the offset the next `gpu.data` must start at.
    var offset: UInt64 { lock.withLock { next } }

    func receive(offset: UInt64, data: Data) {
        lock.lock()
        guard !ended, offset == next else { return lock.unlock() }
        next += UInt64(data.count)
        guard let sink else {
            held.append(data)
            return lock.unlock()
        }
        lock.unlock()
        sink(data)
    }

    func attach(_ sink: @escaping (Data) -> Void) {
        let pending: [Data] = lock.withLock {
            guard !ended else { return [] }
            self.sink = sink
            defer { held.removeAll() }
            return held
        }
        for data in pending { sink(data) }
    }

    func detach() {
        lock.withLock {
            ended = true
            sink = nil
            held.removeAll()
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
