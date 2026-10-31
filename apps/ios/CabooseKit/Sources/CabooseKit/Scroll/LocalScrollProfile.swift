import Foundation
import Metal
import OSLog
import QuartzCore

/// On-device measurement of phone-owned scrolling, enabled with `CABOOSE_SCROLL_PROFILE=1`.
///
/// For each gesture, from its first touch until the scroll hands back to the app: touch to
/// glass latency (a touch sample's timestamp to the presented time of the first drawable
/// that includes it), frame pacing (intervals between presented drawables, and refreshes
/// that presented nothing while composing), the blank fraction of the region, and how
/// pictures were placed. Each gesture is logged (subsystem `org.caboose`, category
/// `scroll`) and appended as one JSON line to `Documents/scroll-profile.jsonl`.
public final class LocalScrollProfile: @unchecked Sendable {
    public static let enabled = ProcessInfo.processInfo.environment["CABOOSE_SCROLL_PROFILE"] == "1"
    private static let log = Logger(subsystem: "org.caboose", category: "scroll")

    private let lock = NSLock()
    private var active = false
    private var started: CFTimeInterval = 0
    private var pendingTouches: [CFTimeInterval] = []
    private var latencies: [Double] = []
    private var presented: [CFTimeInterval] = []
    private var blanks: [Double] = []
    private var composed = 0, refreshes = 0
    private var moved = 0, still = 0, unrelated = 0
    private var label = ""

    public init() {}

    /// Names the next gestures, for synthetic replays.
    public func label(_ name: String) { lock.withLock { label = name } }

    func begin(at time: CFTimeInterval) {
        guard Self.enabled else { return }
        lock.withLock {
            if !active { reset(); active = true; started = time }
            pendingTouches.append(time)
        }
    }

    func touch(at time: CFTimeInterval) {
        guard Self.enabled else { return }
        lock.withLock { if active { pendingTouches.append(time) } }
    }

    func presenting(_ drawable: CAMetalDrawable, at refresh: CFTimeInterval) {
        guard Self.enabled else { return }
        let touches: [CFTimeInterval] = lock.withLock {
            let included = pendingTouches
            pendingTouches.removeAll()
            return included
        }
        drawable.addPresentedHandler { [weak self] presentedDrawable in
            let time = presentedDrawable.presentedTime
            guard let self, time > 0 else { return }
            self.lock.withLock {
                self.presented.append(time)
                for touch in touches { self.latencies.append(time - touch) }
            }
        }
    }

    func refresh(at time: CFTimeInterval, composed didCompose: Bool, blank: Int, region: Int) {
        guard Self.enabled else { return }
        lock.withLock {
            guard active else { return }
            refreshes += 1
            if didCompose {
                composed += 1
                blanks.append(Double(blank) / Double(max(1, region)))
            }
        }
    }

    func measured(_ observation: ScrollObservation) {
        guard Self.enabled else { return }
        lock.withLock {
            switch observation {
            case .moved, .reported: moved += 1
            case .still: still += 1
            case .unrelated: unrelated += 1
            }
        }
    }

    /// The scroll handed back to the app: report the gesture.
    func finish(model: LocalScroll, at time: CFTimeInterval) {
        guard Self.enabled else { return }
        let line: String? = lock.withLock {
            guard active else { return nil }
            active = false
            func pct(_ values: [Double], _ p: Double) -> Double {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
            }
            let sortedPresented = presented.sorted()
            let intervals = zip(sortedPresented.dropFirst(), sortedPresented).map { ($0 - $1) * 1000 }
            let expected = intervals.isEmpty ? 0 : pct(intervals, 0.5)
            let late = intervals.filter { $0 > expected * 1.5 }.count
            let fields: [String: Any] = [
                "label": label,
                "duration_ms": Int((time - started) * 1000),
                "touch_to_glass_ms": ["p50": pct(latencies, 0.5) * 1000, "p95": pct(latencies, 0.95) * 1000, "max": (latencies.max() ?? 0) * 1000],
                "frame_interval_ms": ["p50": expected, "p95": pct(intervals, 0.95), "max": intervals.max() ?? 0],
                "late_frames": late,
                "presented": presented.count,
                "refreshes": refreshes,
                "composed": composed,
                "blank": ["p50": pct(blanks, 0.5), "p95": pct(blanks, 0.95), "max": blanks.max() ?? 0],
                "pictures": ["moved": moved, "still": still, "unrelated": unrelated],
                "app_latency_ms": model.latency * 1000,
                "app_gain": model.gain,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let line else { return }
        Self.log.notice("\(line, privacy: .public)")
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("scroll-profile.jsonl")
        let bytes = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            try? handle.close()
        } else {
            try? bytes.write(to: url)
        }
    }

    private func reset() {
        pendingTouches.removeAll(); latencies.removeAll(); presented.removeAll(); blanks.removeAll()
        composed = 0; refreshes = 0; moved = 0; still = 0; unrelated = 0
    }
}
