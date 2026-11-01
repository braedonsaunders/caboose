import CabooseKit
import Foundation
import Observation

/// The computer's running apps (`GET /v1/running-apps`) and ending them. The Task Manager
/// polls while it is on screen; the shell refreshes the last listing when windows come and
/// go, so a dock entry knows an app that runs without windows (Steam in its tray).
@MainActor @Observable
final class RunningAppsCenter {
    /// Asked of the owner before ending an app from a menu.
    struct Confirmation: Identifiable {
        enum Kind { case forceQuit, kill, deleteService }
        let id = UUID()
        let kind: Kind
        let name: String
        let ids: [String]
    }

    /// An action the host refused, or that could not reach it.
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    static let pollInterval: Duration = .seconds(2)

    private(set) var listing: RunningAppsListing?
    /// The listing could not be read; the last one stays.
    private(set) var listingError: String?
    /// Apps with an action in flight.
    private(set) var busy: Set<String> = []
    var confirmation: Confirmation?
    var failure: Failure?
    /// An app asked to quit that is still running: offered Force Quit.
    var stillRunning: RunningApp?
    private var followUp = QuitFollowUp()
    private var generation = 0

    func reset() {
        generation += 1
        listing = nil
        listingError = nil
        busy = []
        confirmation = nil
        failure = nil
        stillRunning = nil
        followUp = QuitFollowUp()
    }

    /// Reads the listing once.
    func refresh(model: AppModel) async throws {
        guard let host = model.host else { return }
        let epoch = generation
        let fresh = try await host.runningApps()
        guard epoch == generation else { return }
        listing = fresh
        listingError = nil
        let due = followUp.due(listed: fresh.apps.map(\.id), now: .now)
        if stillRunning == nil, let id = due.first, let app = fresh.apps.first(where: { $0.id == id }) {
            stillRunning = app
        }
        if let offered = stillRunning, !fresh.apps.contains(where: { $0.id == offered.id }) { stillRunning = nil }
    }

    /// Reads the listing every two seconds until the caller's task ends (the screen goes away).
    func poll(model: AppModel) async {
        while !Task.isCancelled {
            do {
                try await refresh(model: model)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                listingError = error.localizedDescription
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// A dock or taskbar entry's running apps in the last listing.
    func running(windowIDs: some Sequence<Int>, desktopID: String?) -> [RunningApp] {
        TaskManager.matching(windowIDs: windowIDs, desktopID: desktopID, in: listing?.apps ?? [])
    }

    // MARK: Ending apps

    func quit(_ app: RunningApp, model: AppModel) async {
        await quit(ids: [app.id], name: app.name, model: model)
    }

    /// Asks each app's windows to close, then checks after `QuitFollowUp.defaultDelay` and
    /// offers Force Quit for one that is still running.
    func quit(ids: [String], name: String, model: AppModel) async {
        guard let host = model.host, !ids.isEmpty else { return }
        let epoch = generation
        var asked = false
        for id in ids {
            busy.insert(id)
            do {
                _ = try await host.quitRunningApp(id)
                followUp.quitRequested(id, at: .now)
                asked = true
            } catch {
                if epoch == generation { failure = Failure(title: "Couldn’t Quit \(name)", message: error.localizedDescription) }
            }
            if epoch == generation { busy.remove(id) }
        }
        guard asked, epoch == generation else { return }
        try? await refresh(model: model)
        try? await Task.sleep(for: .seconds(QuitFollowUp.defaultDelay + 0.2))
        guard epoch == generation else { return }
        try? await refresh(model: model)
    }

    /// Quits the app, waits up to 15 s for it to end, then opens its desktop entry again, so
    /// it starts on the phone's GPU.
    func relaunch(_ app: RunningApp, model: AppModel) async {
        guard let host = model.host, let desktopID = app.desktopId,
              let entry = model.apps.first(where: { TaskManager.sameDesktopID($0.id, desktopID) }) else { return }
        let epoch = generation
        busy.insert(app.id)
        defer { if epoch == generation { busy.remove(app.id) } }
        do {
            _ = try await host.quitRunningApp(app.id)
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(500))
                guard epoch == generation else { return }
                try await refresh(model: model)
                if listing?.apps.contains(where: { $0.id == app.id }) != true {
                    try await host.launch(entry)
                    return
                }
            }
            failure = Failure(title: "\(app.name) Is Still Running",
                              message: "It did not quit, so it was not reopened. Quit it (or Force Quit it), then open it again.")
        } catch {
            if epoch == generation { failure = Failure(title: "Couldn’t Relaunch \(app.name)", message: error.localizedDescription) }
        }
    }

    func end(_ kind: Confirmation.Kind, ids: [String], name: String, model: AppModel) async {
        guard let host = model.host, !ids.isEmpty else { return }
        let epoch = generation
        var survivors = false
        if kind == .deleteService {
            for name in ids { await deleteService(name: name, model: model) }
            return
        }
        for id in ids {
            busy.insert(id)
            followUp.forget(id)
            if stillRunning?.id == id { stillRunning = nil }
            do {
                let reply = kind == .forceQuit ? try await host.forceQuitRunningApp(id) : try await host.killRunningApp(id)
                if !reply.ended { survivors = true }
            } catch {
                if epoch == generation {
                    failure = Failure(title: kind == .forceQuit ? "Couldn’t Force Quit \(name)" : "Couldn’t End \(name)",
                                      message: error.localizedDescription)
                }
            }
            if epoch == generation { busy.remove(id) }
        }
        guard epoch == generation else { return }
        if survivors {
            failure = Failure(title: "\(name) Is Still Ending",
                              message: kind == .forceQuit
                                ? "Some of its processes had not exited when the computer answered. Kill All Processes ends them at once."
                                : "Its processes were killed, but the computer had not yet seen all of them exit.")
        }
        try? await refresh(model: model)
    }

    // MARK: Services

    /// Start, Stop, Restart, or Start with Computer on or off, then a fresh listing.
    func service(_ action: ServicesRoute.Action, _ service: RunningService, model: AppModel) async {
        guard let host = model.host else { return }
        let epoch = generation
        busy.insert(service.id)
        do {
            _ = try await host.service(action, name: service.name)
        } catch {
            if epoch == generation {
                failure = Failure(title: "Couldn’t \(Self.verb(action)) \(service.name)", message: error.localizedDescription)
            }
        }
        guard epoch == generation else { return }
        busy.remove(service.id)
        try? await refresh(model: model)
    }

    private static func verb(_ action: ServicesRoute.Action) -> String {
        switch action {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .enable, .disable: "Change"
        }
    }

    /// Stops an owner service and removes it, after the owner confirmed.
    func deleteService(name: String, model: AppModel) async {
        guard let host = model.host else { return }
        let epoch = generation
        let id = name + ".service"
        busy.insert(id)
        do {
            try await host.deleteService(name: name)
        } catch {
            if epoch == generation { failure = Failure(title: "Couldn’t Delete \(name)", message: error.localizedDescription) }
        }
        guard epoch == generation else { return }
        busy.remove(id)
        try? await refresh(model: model)
    }

    /// Creates an owner service, and starts it when asked. Failing to create it is the
    /// form's to show; failing to start the created service is reported here.
    func createService(name: String, _ definition: ServiceDefinition, start: Bool, model: AppModel) async throws {
        guard let host = model.host else { return }
        let epoch = generation
        _ = try await host.saveService(name: name, definition)
        if start {
            do { _ = try await host.service(.start, name: name) } catch {
                if epoch == generation { failure = Failure(title: "Couldn’t Start \(name)", message: error.localizedDescription) }
            }
        }
        try? await refresh(model: model)
    }

    // MARK: From a dock entry

    /// The entry's running apps in a listing read now, or nil after reporting that it has none.
    private func resolve(name: String, windowIDs: [Int], desktopID: String, model: AppModel) async -> [RunningApp]? {
        do {
            try await refresh(model: model)
        } catch {
            failure = Failure(title: "Couldn’t Read Running Apps", message: error.localizedDescription)
            return nil
        }
        let running = self.running(windowIDs: windowIDs, desktopID: desktopID).filter(\.canEnd)
        guard !running.isEmpty else {
            failure = Failure(title: "\(name) Is Not Running", message: "The computer lists no running app for \(name).")
            return nil
        }
        return running
    }

    func quitEntry(name: String, windowIDs: [Int], desktopID: String, model: AppModel) async {
        guard let running = await resolve(name: name, windowIDs: windowIDs, desktopID: desktopID, model: model) else { return }
        let quittable = running.filter(\.canQuit)
        guard !quittable.isEmpty else {
            confirmation = Confirmation(kind: .forceQuit, name: name, ids: running.map(\.id))
            return
        }
        await quit(ids: quittable.map(\.id), name: name, model: model)
    }

    func confirmForceQuitEntry(name: String, windowIDs: [Int], desktopID: String, model: AppModel) async {
        guard let running = await resolve(name: name, windowIDs: windowIDs, desktopID: desktopID, model: model) else { return }
        confirmation = Confirmation(kind: .forceQuit, name: name, ids: running.map(\.id))
    }
}
