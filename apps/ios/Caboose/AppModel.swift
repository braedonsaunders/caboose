import CabooseKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// The phone's view of its computer: credentials, wake state, the live session, and apps.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        case needsSetup
        case waking
        case connecting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase
    let agents = AgentCenter()
    /// A window on the agent seat being watched or taken over full screen.
    var presentedAgentWindowID: Int?
    private(set) var credentials: Credentials?
    private(set) var session: XpraSession?
    private(set) var computer: HostClient.Session.Computer?
    private(set) var apps: [HostClient.App] = []
    private(set) var appIcons: [String: UIImage] = [:]
    /// The window shown full screen, if any.
    var presentedWindowID: Int?
    var keyboardVisible = false
    private(set) var launching: HostClient.App?
    /// An app that would not start. The computer is fine, so Home stays and says which app.
    var launchFailure: String?

    /// Linux pixels per iOS point. 2 gives crisp text with the guest running at 192 dpi.
    let pixelsPerPoint: CGFloat = 2

    /// A TV or monitor is showing the desktop; the phone is its trackpad.
    private(set) var externalDisplayActive = false
    private(set) var desktop = DesktopModel(pixelsPerPoint: 1)
    private var externalSize: CGSize = .zero
    private var placedWindowIDs = Set<Int>()
    /// Last frames of the computer's windows, by Xpra window id, for instant resume.
    private var frameCache: [Int: CGImage] = [:]
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var sceneActive = true

    private var launchStartedAt: Date?
    private var knownWindowIDs = Set<Int>()
    private var pasteboardChangeCount = UIPasteboard.general.changeCount
    private var observingWindows = false

    init() {
        let saved = Credentials.load()
        credentials = saved
        phase = saved == nil ? .needsSetup : .waking
    }

    var host: HostClient? { credentials.map { HostClient(baseURL: $0.hostURL, token: $0.token) } }

    /// Normal application windows, most recently raised first.
    var appWindows: [RemoteWindow] {
        (session?.windows.values.filter { !$0.isAuxiliary } ?? []).sorted { $0.raisedAt > $1.raisedAt }
    }

    /// Menus, popups and dialogs belonging to a window (or floating while it is shown).
    func auxiliaryWindows(for parent: RemoteWindow) -> [RemoteWindow] {
        (session?.windows.values.filter { $0.isAuxiliary && ($0.transientFor == parent.id || $0.transientFor == nil) } ?? [])
            .sorted { $0.id < $1.id }
    }

    func window(_ id: Int?) -> RemoteWindow? { id.flatMap { session?.windows[$0] } }

    // MARK: Setup

    func connect(with credentials: Credentials) {
        credentials.save()
        self.credentials = credentials
        Task { await wake() }
    }

    func signOut() {
        session?.disconnect()
        session = nil
        agents.reset()
        Credentials.clear()
        credentials = nil
        phase = .needsSetup
    }

    // MARK: Lifecycle

    /// Wakes the computer and opens the display. `quiet` keeps the current screen in place,
    /// for reconnects the person should not have to notice.
    func wake(quiet: Bool = false) async {
        guard let host else { phase = .needsSetup; return }
        if case .ready = phase, session?.state == .ready { return }
        if !quiet { phase = .waking }
        do {
            let wake = try await host.wake()
            computer = wake.computer
            if !quiet { phase = .connecting }
            startSession(host: host, display: wake.display)
            agents.detach()
            agents.attach(host: host)
            agents.prepareSeat(displayToken: wake.display.token, capabilities: seatCapabilities())
            Task { await refreshApps() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func sceneBecameActive() {
        sceneActive = true
        offerPasteboardIfChanged()
        if session == nil || session?.state != .ready { Task { await wake() } }
    }

    /// Leaving the app closes the display; the computer keeps every app running and parks on idle.
    func sceneEnteredBackground() {
        sceneActive = false
        reconnectTask?.cancel()
        if let session {
            frameCache = session.windows.reduce(into: [:]) { cache, entry in
                if let image = entry.value.surface.snapshot() { cache[entry.key] = image }
            }
        }
        session?.disconnect()
        session = nil
        agents.detach()
        knownWindowIDs.removeAll()
        if case .ready = phase { phase = .waking }
    }

    private var lastDisplay: HostClient.Session.Display?

    private func startSession(host: HostClient, display: HostClient.Session.Display) {
        session?.disconnect()
        lastDisplay = display
        let caps: ClientCapabilities
        if externalDisplayActive {
            // The big screen at its own pixels: a real desktop, not a scaled phone.
            let scale = desktop.pixelsPerPoint
            // Linux text grows with the desktop's size factor, through the DPI it is told.
            caps = ClientCapabilities(desktopWidth: Int(externalSize.width * scale), desktopHeight: Int(externalSize.height * scale),
                                      dpi: Int((96 * scale * desktop.ui).rounded()), refreshRate: 60)
        } else {
            let bounds = UIScreen.main.bounds
            let longSide = max(bounds.width, bounds.height)
            // A square desktop that fits either orientation, so rotating never strands a window offscreen.
            caps = ClientCapabilities(desktopWidth: Int(longSide * pixelsPerPoint), desktopHeight: Int(longSide * pixelsPerPoint),
                                      dpi: Int(96 * pixelsPerPoint), refreshRate: UIScreen.main.maximumFramesPerSecond)
        }
        placedWindowIDs.removeAll()
        let session = XpraSession(displayURL: host.socketURL(display.path), token: host.token, password: display.token,
                                  capabilities: caps)
        session.onClipboardText = { text in UIPasteboard.general.string = text }
        session.clipboardProvider = { UIPasteboard.general.string }
        session.onBell = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        session.onOpenURL = { url in UIApplication.shared.open(url) }
        session.onNotification = { note in Self.post(note) }
        session.onRaise = { [weak self] wid in self?.presentedWindowID = wid }
        session.cachedFrame = { [weak self] wid in self?.frameCache[wid] }
        self.session = session
        session.connect()
        observeSession()
    }

    /// Follows the session's state and its windows: new windows from a launch open full screen.
    private func observeSession() {
        guard let session else { return }
        withObservationTracking {
            _ = session.state
            _ = session.windows.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionChanged()
                self?.observeSession()
            }
        }
        sessionChanged()
    }

    private func sessionChanged() {
        guard let session else { return }
        switch session.state {
        case .ready:
            reconnectAttempts = 0
            if phase != .ready { phase = .ready }
        case .closed(let reason):
            // A dropped connection while the app is in use is retried quietly; only give up after a few tries.
            if sceneActive, reconnectAttempts < 4 {
                scheduleReconnect()
            } else if case .ready = phase {
                phase = .failed(reason ?? "The display connection closed.")
            } else if phase == .connecting {
                phase = .failed(reason ?? "Could not open the display.")
            }
        default:
            break
        }
        let current = Set(session.windows.keys)
        let added = current.subtracting(knownWindowIDs)
        knownWindowIDs = current
        if externalDisplayActive {
            desktop.sync(with: Array(session.windows.values))
            for (index, window) in appWindows.reversed().enumerated() where !placedWindowIDs.contains(window.id) {
                placedWindowIDs.insert(window.id)
                session.configure(window, frame: desktop.placement(for: window, index: index))
                desktop.raise(window.id)
            }
        }
        if let presented = presentedWindowID, !current.contains(presented) {
            presentedWindowID = appWindows.first?.id
        }
        if launching != nil, let newest = added.compactMap({ session.windows[$0] }).first(where: { !$0.isAuxiliary }) {
            launching = nil
            presentedWindowID = newest.id
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectAttempts += 1
        let delay = Double(1 << (reconnectAttempts - 1))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.session = nil
            await self.wake(quiet: true)
        }
    }

    func presentAgentWindow(_ id: Int) {
        presentedAgentWindowID = id
    }

    private func seatCapabilities() -> ClientCapabilities {
        let bounds = UIScreen.main.bounds
        let side = max(bounds.width, bounds.height) * pixelsPerPoint
        return ClientCapabilities(desktopWidth: Int(side), desktopHeight: Int(side), dpi: Int(96 * pixelsPerPoint))
    }

    // MARK: External display

    func externalDisplayConnected(size: CGSize, scale: CGFloat) {
        externalSize = size
        desktop = DesktopModel(pixelsPerPoint: max(1, scale))
        desktop.ui = DesktopModel.automaticUI(forWidth: size.width) * desktopZoom
        desktop.size = size
        desktop.cursor = CGPoint(x: size.width / 2, y: size.height / 2)
        externalDisplayActive = true
        presentedWindowID = nil
        reconnectForDisplayChange()
    }

    /// The owner's adjustment to the desktop's automatic size, kept across sessions.
    var desktopZoom: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "desktopZoom")
        return saved > 0 ? saved : 1
    }()

    /// Makes everything on the big screen larger or smaller, Linux apps included.
    func adjustDesktopZoom(by factor: CGFloat) {
        let zoom = min(2.5, max(0.6, desktopZoom * factor))
        guard zoom != desktopZoom else { return }
        desktopZoom = zoom
        UserDefaults.standard.set(Double(zoom), forKey: "desktopZoom")
        desktop.ui = DesktopModel.automaticUI(forWidth: externalSize.width) * zoom
        // Linux learns its new DPI from the next hello; the apps keep running.
        reconnectForDisplayChange()
    }

    func externalDisplayDisconnected() {
        externalDisplayActive = false
        reconnectForDisplayChange()
    }

    /// The Linux apps keep running; only the display size the server lays them out for changes.
    private func reconnectForDisplayChange() {
        guard let host, let lastDisplay else { return }
        phase = .connecting
        startSession(host: host, display: lastDisplay)
    }

    // MARK: Apps

    func refreshApps() async {
        guard let host else { return }
        for attempt in 0 ..< 10 {
            do {
                let list = try await host.apps()
                apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                for app in list where appIcons[app.id] == nil {
                    if let data = app.iconData, let image = UIImage(data: data) { appIcons[app.id] = image }
                }
                return
            } catch HostClient.Failure.notRunning {
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            } catch {
                return
            }
        }
    }

    /// A dock click on the big screen: show the app's windows if it has any, else launch it.
    func openOnDesktop(_ app: HostClient.App) {
        let ids = appWindows.filter { matches($0, app) }.map(\.id)
        if desktop.reveal(ids, session: session) { return }
        launch(app)
    }

    func open(_ app: HostClient.App) {
        if let existing = appWindows.first(where: { matches($0, app) }) {
            presentedWindowID = existing.id
            return
        }
        launch(app)
    }

    private func launch(_ app: HostClient.App) {
        guard let host else { return }
        launching = app
        launchStartedAt = Date()
        Task {
            do {
                try await host.launch(app)
            } catch {
                launching = nil
                launchFailure = "\(app.name) didn't open. \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func matches(_ window: RemoteWindow, _ app: HostClient.App) -> Bool {
        guard let appClass = window.appClass else { return false }
        let id = app.id.replacingOccurrences(of: ".desktop", with: "").lowercased()
        return [appClass.instance.lowercased(), appClass.name.lowercased()].contains { $0 == id || id.hasSuffix($0) || $0.hasSuffix(id) }
    }

    func icon(for window: RemoteWindow) -> UIImage? {
        if let app = apps.first(where: { matches(window, $0) }), let image = appIcons[app.id] { return image }
        return window.icon.map { UIImage(cgImage: $0) }
    }

    // MARK: Clipboard and notifications

    private func offerPasteboardIfChanged() {
        let count = UIPasteboard.general.changeCount
        guard count != pasteboardChangeCount else { return }
        pasteboardChangeCount = count
        if UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string { session?.offerClipboard(text) }
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private static func post(_ note: RemoteNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.summary.isEmpty ? note.appName : note.summary
        content.subtitle = note.summary.isEmpty ? "" : note.appName
        content.body = note.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "linux.\(note.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
