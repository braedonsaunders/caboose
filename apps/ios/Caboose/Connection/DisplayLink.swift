import CabooseKit
import Foundation
import Network
import Observation
import QuartzCore

/// Keeps the owner's display connected while the app is in use: one reconnect at a time,
/// on `ReconnectPolicy`'s schedule, paused while the phone has no network and restarted
/// when it gets a new one. `AppModel` performs each attempt; this decides when.
@MainActor @Observable
final class DisplayLink {
    enum Status: Equatable {
        /// Nothing to keep connected: in the background, parked, or not set up.
        case idle
        case live
        /// Attempt `attempt` of `of` runs now (`at` nil) or starts at `at`.
        case reconnecting(attempt: Int, of: Int, at: Date?, reason: String)
        /// The phone has no usable network; trying resumes when it does.
        case waitingForNetwork(reason: String)
        /// The series ended without a connection; Try Again starts another.
        case lost(String)
    }

    struct Drop: Equatable, Identifiable {
        let id = UUID()
        let at: Date
        let reason: String
    }

    private(set) var status: Status = .idle
    private(set) var path: NetworkPath?
    /// The most recent losses of the display, newest first.
    private(set) var drops: [Drop] = []
    /// Reconnects that reached the display since the app started.
    private(set) var recoveries = 0

    /// Opens the display again. The attempt reports its outcome through `connected()` or
    /// `lost(_:reason:)`.
    var attempt: (() async -> Void)?
    /// The path changed under a live display: it should prove it still answers.
    var probe: (() -> Void)?

    private var policy = ReconnectPolicy()
    private var pending: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lastPath: NetworkPath?

    /// Starts following the network path. Calling it again does nothing.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = NetworkPath(path)
            Task { @MainActor in self?.pathChanged(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "caboose.display.path"))
        self.monitor = monitor
    }

    /// The display is connected and showing the computer.
    func connected() {
        pending?.cancel()
        pending = nil
        if case .reconnecting = status { recoveries += 1 }
        if case .waitingForNetwork = status { recoveries += 1 }
        policy.connected(at: CACurrentMediaTime())
        status = .live
    }

    /// The display was lost, or an attempt failed. Schedules the next attempt, or ends the
    /// series when the policy says retrying cannot help or has been tried enough.
    func lost(_ cause: ReconnectPolicy.Cause, reason: String) {
        if case .live = status { record(reason) }
        pending?.cancel()
        pending = nil
        guard let delay = policy.next(after: cause, at: CACurrentMediaTime()) else {
            status = .lost(reason)
            return
        }
        if path?.satisfied == false {
            status = .waitingForNetwork(reason: reason)
            return
        }
        let attempt = policy.attempts
        status = .reconnecting(attempt: attempt, of: ReconnectPolicy.maxAttempts, at: Date().addingTimeInterval(delay), reason: reason)
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.run(attempt: attempt, reason: reason)
        }
    }

    /// Try Again, or the app coming to the foreground: a fresh series, now.
    func retryNow(reason: String) {
        policy.restart()
        pending?.cancel()
        pending = nil
        let attempt = 1
        _ = policy.next(after: .dropped, at: CACurrentMediaTime())
        pending = Task { [weak self] in await self?.run(attempt: attempt, reason: reason) }
    }

    /// Nothing should reconnect: the app went to the background, parked or signed out.
    func stop() {
        pending?.cancel()
        pending = nil
        policy.restart()
        status = .idle
    }

    /// One line for the places that show how the connection is: nil while it is live or
    /// nothing should be connected.
    var statusLine: String? {
        switch status {
        case .idle, .live: nil
        case .reconnecting(let attempt, let of, let at, _):
            if let at, at.timeIntervalSinceNow >= 1 { "Reconnecting in \(Int(at.timeIntervalSinceNow.rounded())) s · attempt \(attempt) of \(of)" }
            else { "Reconnecting · attempt \(attempt) of \(of)" }
        case .waitingForNetwork: "Waiting for a network"
        case .lost: "Disconnected"
        }
    }

    /// Why the display is not connected, while it is not.
    var reason: String? {
        switch status {
        case .idle, .live: nil
        case .reconnecting(_, _, _, let reason), .waitingForNetwork(let reason), .lost(let reason): reason
        }
    }

    private func run(attempt: Int, reason: String) async {
        pending = nil
        if path?.satisfied == false {
            status = .waitingForNetwork(reason: reason)
            return
        }
        status = .reconnecting(attempt: attempt, of: ReconnectPolicy.maxAttempts, at: nil, reason: reason)
        await self.attempt?()
    }

    private func pathChanged(_ next: NetworkPath) {
        let previous = lastPath
        lastPath = next
        path = next
        guard next.satisfied else {
            if case .reconnecting(_, _, _, let reason) = status {
                pending?.cancel()
                pending = nil
                status = .waitingForNetwork(reason: reason)
            }
            return
        }
        switch status {
        case .idle:
            break
        case .live:
            // A socket on a route the phone left can stay open for minutes saying nothing.
            if NetworkPath.response(from: previous, to: next, live: true) == .probe { probe?() }
        case .waitingForNetwork(let reason), .lost(let reason), .reconnecting(_, _, _, let reason):
            // A new network is a new chance: start over, now.
            if NetworkPath.response(from: previous, to: next, live: false) == .retry { retryNow(reason: reason) }
        }
    }

    private func record(_ reason: String) {
        drops.insert(Drop(at: Date(), reason: reason), at: 0)
        if drops.count > 5 { drops.removeLast(drops.count - 5) }
    }
}

extension NetworkPath {
    /// The kinds of interface the path uses (`usesInterfaceType`), not the ones merely available.
    init(_ path: NWPath) {
        let kinds: [(NWInterface.InterfaceType, Kind)] = [
            (.wifi, .wifi), (.cellular, .cellular), (.wiredEthernet, .wired), (.loopback, .loopback), (.other, .other),
        ]
        self.init(satisfied: path.status == .satisfied,
                  uses: Set(kinds.filter { path.usesInterfaceType($0.0) }.map(\.1)),
                  gateways: path.gateways.map { "\($0)" },
                  expensive: path.isExpensive, constrained: path.isConstrained)
    }
}
