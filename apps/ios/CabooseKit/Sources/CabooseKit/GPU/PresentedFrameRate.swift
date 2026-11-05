import Foundation

/// How often each computer window presents a picture on this device's GPU: the frame rate
/// the frame-rate overlay shows. A present counts once the executor accepted it.
public final class PresentedFrameRate: @unchecked Sendable {
    public static let shared = PresentedFrameRate()
    /// The span a rate is measured over, in seconds.
    public static let span: TimeInterval = 2

    private let lock = NSLock()
    private var presents: [Int: [TimeInterval]] = [:]

    public init() {}

    /// `CABOOSE_PRESENT_TRACE=1`: every accepted present on standard error, with the gap since
    /// the window's previous one, for finding stalls frame by frame.
    static let traces = ProcessInfo.processInfo.environment["CABOOSE_PRESENT_TRACE"] == "1"
    private var traced: [Int: TimeInterval] = [:]
    private func trace(window: Int, at time: TimeInterval) {
        let previous = lock.withLock { () -> TimeInterval? in
            defer { traced[window] = time }
            return traced[window]
        }
        let gap = previous.map { Int((time - $0) * 1000) } ?? 0
        FileHandle.standardError.write(Data("CABOOSE_PRESENT window=\(window) gap_ms=\(gap)\n".utf8))
    }

    /// Window `window` presented a picture at `time` (seconds on a monotonic clock).
    public func note(window: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if Self.traces { trace(window: window, at: time) }
        lock.withLock {
            var times = presents[window, default: []]
            times.append(time)
            if let first = times.firstIndex(where: { $0 > time - Self.span }), first > 0 { times.removeFirst(first) }
            presents[window] = times
        }
    }

    /// Window `window`'s presents per second over the last `span`, or nil when it presented
    /// none in that time.
    public func rate(window: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        lock.withLock {
            let recent = (presents[window] ?? []).filter { $0 > time - Self.span && $0 <= time }
            guard !recent.isEmpty else {
                presents[window] = nil
                return nil
            }
            return Double(recent.count) / Self.span
        }
    }

    /// The first of `windows` (topmost first) that presented in the last `span`, with its rate.
    public func frontmost(_ windows: [Int], at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (window: Int, rate: Double)? {
        for window in windows {
            if let rate = rate(window: window, at: time) { return (window, rate) }
        }
        return nil
    }
}
