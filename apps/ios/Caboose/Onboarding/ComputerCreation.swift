import CabooseKit
import Foundation
import Observation

/// Making a computer on the host and following it until it is up: the owner names it and
/// picks a size, the host makes and starts it, and its boot is followed step by step from
/// the host's own events (`GET /v1/computers/<id>/boot`). Nothing here moves on a timer:
/// every change on screen is one the host reported.
@MainActor @Observable
final class ComputerCreation {
    enum Stage: Equatable {
        /// Naming it and choosing its size.
        case choosing
        /// `POST /v1/computers` is under way.
        case creating
        /// Made; its boot is being followed.
        case starting
    }

    struct Created: Equatable {
        var id: String
        var name: String
    }

    private(set) var stage: Stage = .choosing
    var name: String
    var sizeID: String?
    private(set) var list: HostComputerList?
    private(set) var loadingList = false
    /// Why the host would not make it, or why its computers could not be read.
    private(set) var formError: String?
    private(set) var created: Created?
    private(set) var tracker = BootTracker()
    /// The retry could not be started; the failed attempt stays on screen.
    private(set) var retryError: String?
    private(set) var retrying = false

    @ObservationIgnored private let host: HostClient
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let opened: @MainActor (Created) -> Void
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var finished = false

    init(host: HostClient, list: HostComputerList?, deviceName: String, opened: @escaping @MainActor (Created) -> Void) {
        self.host = host
        self.deviceName = deviceName
        self.opened = opened
        name = HostComputerList.suggestedName(deviceName: deviceName, existing: list?.computers.map(\.name) ?? [])
        apply(list)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool {
        stage == .choosing && !trimmedName.isEmpty && trimmedName.count <= 64
            && list?.allowsCreating == true && list?.availableSizes.contains { $0.id == sizeID } == true
    }

    /// Reads the host's computers and sizes, for a host that has not been read yet.
    func loadList() async {
        guard !loadingList else { return }
        loadingList = true
        defer { loadingList = false }
        do {
            let list = try await host.computers()
            apply(list)
            formError = nil
        } catch {
            formError = error.localizedDescription
        }
    }

    private func apply(_ list: HostComputerList?) {
        guard let list else { return }
        let renamed = name == HostComputerList.suggestedName(deviceName: deviceName, existing: self.list?.computers.map(\.name) ?? [])
        self.list = list
        if renamed { name = HostComputerList.suggestedName(deviceName: deviceName, existing: list.computers.map(\.name)) }
        if sizeID == nil || !list.availableSizes.contains(where: { $0.id == sizeID }) { sizeID = list.suggestedSize?.id }
    }

    /// Makes the computer and starts it, then follows its boot.
    func create() async {
        guard canCreate, let sizeID else { return }
        stage = .creating
        formError = nil
        do {
            let computer = try await host.createComputer(name: trimmedName, size: sizeID)
            created = Created(id: computer.id, name: computer.name)
            tracker = BootTracker(boot: computer.boot)
            stage = .starting
            follow()
        } catch {
            stage = .choosing
            formError = error.localizedDescription
        }
    }

    /// Starts the computer again after a failed boot (`POST /v1/computers/<id>/boot`) and
    /// follows the new attempt.
    func retry() async {
        guard let created, tracker.failed, !retrying else { return }
        retrying = true
        retryError = nil
        defer { retrying = false }
        do {
            let boot = try await host.startBoot(computer: created.id)
            tracker.retrying()
            tracker.apply(boot)
            follow()
        } catch {
            retryError = error.localizedDescription
        }
    }

    /// Stops following; the host goes on starting the computer regardless.
    func stop() {
        watch?.cancel()
        watch = nil
    }

    /// Follows the boot over its event stream. A dropped stream is opened again, which reads
    /// the current attempt first, so nothing is missed and nothing is guessed meanwhile.
    private func follow() {
        watch?.cancel()
        guard let created else { return }
        watch = Task { [weak self, host] in
            var askedToStart = false
            while !Task.isCancelled {
                guard let self else { return }
                if self.tracker.isFinished { break }
                do {
                    for try await boot in host.bootEvents(computer: created.id) {
                        guard !Task.isCancelled else { return }
                        // A computer that has not booted since the host started has no boot
                        // yet: start it, once, which answers with the attempt under way.
                        if boot == nil, self.tracker.boot == nil, !askedToStart {
                            askedToStart = true
                            self.tracker.apply(try await host.startBoot(computer: created.id))
                            continue
                        }
                        self.tracker.apply(boot)
                        if self.tracker.isFinished { break }
                    }
                    if self.tracker.isFinished { break }
                    self.tracker.dropped(reason: "The host ended the progress stream early.")
                } catch {
                    guard !Task.isCancelled else { return }
                    self.tracker.dropped(reason: error.localizedDescription)
                }
                guard case .reconnecting(let attempt, _) = self.tracker.link else { continue }
                try? await Task.sleep(for: .seconds(BootTracker.reconnectDelay(attempt: attempt)))
            }
            guard let self, !Task.isCancelled, self.tracker.succeeded, !self.finished else { return }
            self.finished = true
            self.opened(created)
        }
    }
}
