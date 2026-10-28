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
        /// Parked on request: memory and every app saved, nothing running.
        case parked
        /// A cold restart is underway; open apps are closing.
        case restarting
        case failed(String)
        /// Another device took the display over; it stays there until the person asks for it back.
        case displayElsewhere
    }

    private(set) var phase: Phase
    let agents = AgentCenter()
    var notificationTaskID: String?
    var askFocusRequested = false
    let catalog = CatalogCenter()
    let documents = OpenDocumentCenter()
    /// Videos playing on the computer that can move to the phone.
    let media = MediaHandoff()
    let phone = PhoneHandoff()
    /// Where the computer's sound plays, and the AirPlay device it last played on.
    let airPlay = AirPlayCenter()
    /// A window on the agent seat being watched or taken over full screen.
    var presentedAgentWindowID: Int?
    private(set) var filesRegistrationError: String?
    private(set) var filesRegistering = false
    private var filesRegistrationRevision = 0
    private(set) var credentials: Credentials?
    /// The owner's display.
    private(set) var session: (any DisplaySession)?
    private(set) var computer: HostClient.Session.Computer?
    private(set) var apps: [HostClient.App] = []
    private(set) var appIcons: [String: UIImage] = [:]
    /// The window shown full screen, if any.
    var presentedWindowID: Int? {
        didSet {
            guard presentedWindowID != nil, deviceViewport.owner != .card else { return }
            deviceViewport.presentCard()
            // The underlying stage remains measurable, but cannot configure this window.
            yard.session = nil
            leaveDeviceDesktop()
        }
    }
    var keyboardVisible = false
    private(set) var launching: HostClient.App?
    /// An app that would not start. The computer is fine, so Home stays and says which app.
    var launchFailure: String?
    /// A pairing code is being traded for this phone's token.
    private(set) var pairing = false
    /// Why the last pairing code did not sign this phone in.
    var pairingFailure: String?
    /// The shell's selected tab.
    var selectedTab: ShellTab = .home
    /// Home's pinned and recently opened apps, kept on the phone for this computer.
    private(set) var shortcuts = AppShortcuts()
    /// The newest files in the computer's home, hidden ones left out, from the last file scan.
    private(set) var recentFiles: [RecentFile] = []
    /// A file opened from Home: its window opens full screen when it appears.
    private var openingFileSince: Date?

    /// Linux pixels per iOS point. 2 gives crisp text with the guest running at 192 dpi.
    let pixelsPerPoint: CGFloat = 2

    /// A TV or monitor is showing the desktop; the phone is its trackpad.
    private(set) var externalDisplayActive = false
    private(set) var desktop = DesktopModel(pixelsPerPoint: 1)
    private var externalSize: CGSize = .zero
    private var placedWindowIDs = Set<Int>()
    /// Last frames of the computer's windows, by window id, for instant resume.
    private var frameCache: [Int: CGImage] = [:]
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var fileSearchTask: Task<Void, Never>?
    private var sceneActive = true

    private var launchStartedAt: Date?
    private var knownWindowIDs = Set<Int>()
    private var pasteboardChangeCount = UIPasteboard.general.changeCount
    private var observingWindows = false

    init() {
        let saved = Credentials.load()
        credentials = saved
        phase = saved == nil ? .needsSetup : .waking
        shortcuts = Self.loadShortcuts(for: saved)
        agents.onComputer = { [weak self] status in
            self?.computerStatus = status
            self?.registerFiles(name: status.settings.name)
        }
        agents.onEvent = { [weak self] type, event in
            guard let self else { return }
            self.media.handle(type, event)
            self.catalog.handle(type, event)
            self.phone.handle(type, event)
            if type == "fs.changed" { self.refreshFileSearch() }
            if type == "notification", self.session is CabooseDisplaySession { Self.postDesktop(event) }
            if type == "fs.changed", let credentials = self.credentials { FileDomains.signal(credentials); self.documents.requestSync(model: self) }
        }
        registerFiles()
        catalog.onChange = { [weak self] in await self?.refreshApps() }
        media.attach(host: { [weak self] in self?.host })
        phone.attach(host: { [weak self] in self?.host })
    }

    var host: HostClient? { credentials.map { HostClient(baseURL: activeHostURL ?? $0.hostURL, token: $0.token) } }
    /// The host address this wake reached — the LAN or the VPN one — chosen at each wake.
    private(set) var activeHostURL: URL?
    /// Reached through another of the host's addresses (a VPN, away from home).
    var isRemote: Bool { activeHostURL != nil && activeHostURL != credentials?.hostURL }

    /// Normal application windows, most recently raised first.
    var appWindows: [RemoteWindow] {
        (session?.windows.values.filter { !$0.isAuxiliary } ?? []).sorted { $0.raisedAt > $1.raisedAt }
    }

    /// Menus, popups and dialogs belonging to a window (or floating while it is shown).
    func auxiliaryWindows(for parent: RemoteWindow) -> [RemoteWindow] {
        guard let windows = session?.windows else { return [] }
        func belongs(_ window: RemoteWindow) -> Bool {
            var id = window.transientFor
            var seen: Set<Int> = [window.id]
            while let ancestor = id, seen.insert(ancestor).inserted {
                if ancestor == parent.id { return true }
                id = windows[ancestor]?.transientFor
            }
            return window.transientFor == nil
        }
        return windows.values.filter { $0.isAuxiliary && belongs($0) }.sorted { $0.id < $1.id }
    }

    func window(_ id: Int?) -> RemoteWindow? { id.flatMap { session?.windows[$0] } }

    // MARK: Setup

    /// Signs in with a pairing link or typed code: the host trades it once for this phone's own token.
    func pair(with link: PairingLink) {
        guard !pairing else { return }
        pairing = true
        pairingFailure = nil
        Task {
            defer { pairing = false }
            do { connect(with: try await link.redeem(deviceName: UIDevice.current.name)) }
            catch { pairingFailure = error.localizedDescription }
        }
    }

    func connect(with credentials: Credentials) {
        if let old = self.credentials, old.fileDomainIdentifier != credentials.fileDomainIdentifier { FileDomains.remove(old) }
        if self.credentials != nil && self.credentials != credentials {
            fileSearchTask?.cancel()
            ComputerSearch.clear()
            PushCoordinator.shared.unregister(from: host)
            LiveActivityCoordinator.shared.unregister(from: host)
        }
        credentials.save()
        if self.credentials?.fileDomainIdentifier != credentials.fileDomainIdentifier {
            shortcuts = Self.loadShortcuts(for: credentials)
            recentFiles = []
        }
        self.credentials = credentials
        filesRegistrationError = nil
        registerFiles(name: "Caboose")
        activeHostURL = nil
        Task { await wake() }
    }

    func signOut() {
        fileSearchTask?.cancel()
        ComputerSearch.clear()
        PushCoordinator.shared.unregister(from: host)
        LiveActivityCoordinator.shared.unregister(from: host)
        session?.disconnect()
        session = nil
        agents.reset()
        catalog.reset()
        documents.reset()
        media.reset()
        phone.reset()
        computerStatus = nil
        settingsPresented = false
        recentFiles = []
        selectedTab = .home
        deviceDesktopActive = false
        deviceViewport = DeviceViewport()
        filesRegistrationRevision += 1
        filesRegistering = false
        filesRegistrationError = nil
        if let credentials { FileDomains.remove(credentials) }
        Credentials.clear()
        credentials = nil
        activeHostURL = nil
        phase = .needsSetup
    }

    /// Advertise the paired computer without depending on its host or display being online.
    func registerFiles(name: String? = nil) {
        guard let credentials else { return }
        filesRegistrationRevision += 1
        let revision = filesRegistrationRevision
        filesRegistering = true
        let displayName = name ?? computerStatus?.settings.name ?? computer?.name ?? "Caboose"
        FileDomains.register(credentials, name: displayName) { [weak self] error in
            guard let self, self.filesRegistrationRevision == revision,
                  self.credentials?.fileDomainIdentifier == credentials.fileDomainIdentifier else { return }
            self.filesRegistering = false
            self.filesRegistrationError = error.map {
                let detail = $0 as NSError
                return "\(detail.localizedDescription) (\(detail.domain) \(detail.code))"
            }
        }
    }

    // MARK: Lifecycle

    /// Wakes the computer and opens the display. `quiet` keeps the current screen in place,
    /// for reconnects the person should not have to notice.
    func wake(quiet: Bool = false) async {
        if let credentials, credentials.candidates.count > 1 {
            let reached = await credentials.reachableURL()
            if reached != activeHostURL { activeHostURL = reached }
        }
        guard let host else { phase = .needsSetup; return }
        if case .ready = phase, session?.state == .ready { return }
        if !quiet { phase = .waking }
        do {
            let wake = try await host.wake()
            // A wake may finish after backgrounding or changing computers. Do not attach
            // an old computer's control channel in either case.
            guard sceneActive, self.host?.token == host.token, self.host?.baseURL == host.baseURL else { return }
            computer = wake.computer
            registerFiles(name: wake.computer.name)
            if !quiet { phase = .connecting }
            startSession(host: host, display: wake.display)
            agents.detach()
            agents.attach(host: host)
            PushCoordinator.shared.synchronize()
            LiveActivityCoordinator.shared.connected()
            catalog.attach(host)
            documents.requestSync(model: self)
            agents.prepareSeat(displayToken: wake.display.token, capabilities: seatCapabilities())
            Task { await media.refresh() }
            Task { await refreshApps() }
            refreshFileSearch()
            Task { try? await refreshComputer() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func sceneBecameActive() {
        sceneActive = true
        registerFiles()
        phone.setActive(true)
        documents.requestSync(model: self)
        showSharedDocumentIfAvailable()
        offerPasteboardIfChanged()
        if phase != .displayElsewhere, session == nil || session?.state != .ready { Task { await wake() } }
    }

    /// Leaving the app closes the display; the computer keeps every app running and parks on idle.
    func sceneEnteredBackground() {
        sceneActive = false
        phone.setActive(false)
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
        let caps = displayCapabilities()
        placedWindowIDs.removeAll()
        let url = host.socketURL(display.path)
        let session: any DisplaySession = CabooseDisplaySession(displayURL: url, token: host.token, password: display.token, capabilities: caps)
        session.onClipboardText = { text in UIPasteboard.general.string = text }
        session.clipboardProvider = { UIPasteboard.general.string }
        session.onBell = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        session.onOpenURL = { [weak self] url in self?.phone.open(url) }
        session.onNotification = { note in Self.post(note) }
        // A window raised on the desktop stays on the desktop; only the phone's cards follow it.
        session.onRaise = { [weak self] wid in
            guard let self else { return }
            if self.yardActive { self.yard.focus(wid) } else if !self.desktopActive { self.presentedWindowID = wid }
        }
        session.cachedFrame = { [weak self] wid in self?.frameCache[wid] }
        self.session = session
        yard.session = session
        yard.invalidate()
        session.connect()
        observeSession()
    }

    /// "Typing 85 ms · Ping 4 ms": how responsive the computer is right now.
    var connectionSummary: String {
        var parts: [String] = []
        if let echo = session?.typingEchoMs { parts.append("Typing \(echo) ms") }
        if let ping = session?.latencyMs { parts.append("Ping \(Int(ping.rounded())) ms") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }

    /// The screen the computer lays windows out for: the big screen at its own pixels when
    /// one is connected, else the phone.
    private func displayCapabilities() -> ClientCapabilities {
        if deviceViewport.owner == .card, deviceViewport.cardSize != .zero {
            let frame = DeviceViewport.guestFrame(size: deviceViewport.cardSize, pixelsPerPoint: pixelsPerPoint)
            return ClientCapabilities(desktopWidth: Int(frame.width), desktopHeight: Int(frame.height),
                                      dpi: Int(96 * pixelsPerPoint), refreshRate: UIScreen.main.maximumFramesPerSecond)
        }
        if desktopActive {
            // The big screen at its own pixels: a real desktop, not a scaled phone.
            let scale = desktop.pixelsPerPoint
            // Linux text grows with the desktop's size factor, through the DPI it is told.
            return ClientCapabilities(desktopWidth: Int(externalSize.width * scale), desktopHeight: Int(externalSize.height * scale),
                                      dpi: Int((96 * scale * desktop.ui).rounded()), refreshRate: 60)
        }
        let bounds = UIScreen.main.bounds
        let longSide = max(bounds.width, bounds.height)
        // A square desktop that fits either orientation, so rotating never strands a window offscreen.
        return ClientCapabilities(desktopWidth: Int(longSide * pixelsPerPoint), desktopHeight: Int(longSide * pixelsPerPoint),
                                  dpi: Int(96 * pixelsPerPoint), refreshRate: UIScreen.main.maximumFramesPerSecond)
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
            // Another device has the display: taking it back on our own would start a tug of war.
            if session.isReplaced {
                reconnectTask?.cancel()
                reconnectTask = nil
                phase = .displayElsewhere
            // A dropped connection while the app is in use is retried quietly; only give up after a few tries.
            } else if sceneActive, reconnectAttempts < 4 {
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
        if yardActive, deviceViewport.owner != .card {
            yard.sync(session.windows) { $0.appClass?.name }
        } else if desktopActive, deviceViewport.owner != .card {
            desktop.sync(with: Array(session.windows.values))
            for (index, window) in appWindows.reversed().enumerated() where !placedWindowIDs.contains(window.id) {
                placedWindowIDs.insert(window.id)
                let frame = desktop.isZoomed(window.id) ? desktop.maximizedFrame
                    : desktop.remembered(window) ?? desktop.placement(for: window, index: index)
                session.configure(window, frame: frame, state: ["maximized": false])
                desktop.raise(window.id)
            }
            // Dialogs and tool windows: over their parent, or centred, never left at the origin.
            // Menus and tooltips (override-redirect) keep the place the app chose.
            for window in session.windows.values where window.isAuxiliary && !window.isOverrideRedirect && !placedWindowIDs.contains(window.id) {
                placedWindowIDs.insert(window.id)
                let parent = window.transientFor.flatMap { session.windows[$0] }
                session.configure(window, frame: desktop.centred(window, over: parent))
                desktop.raise(window.id)
            }
        }
        if let presented = presentedWindowID, !current.contains(presented) {
            presentedWindowID = appWindows.first?.id
        }
        if let target = launching, let newest = added.compactMap({ session.windows[$0] }).first(where: { !$0.isAuxiliary && matches($0, target) }) {
            launching = nil
            if !desktopActive { presentedWindowID = newest.id }
        }
        if let since = openingFileSince, let newest = added.compactMap({ session.windows[$0] }).first(where: { !$0.isAuxiliary }) {
            openingFileSince = nil
            if Date().timeIntervalSince(since) < 30, !desktopActive { presentedWindowID = newest.id }
        }
        showSharedDocumentIfAvailable()
    }

    private func showSharedDocumentIfAvailable() {
        let shared = UserDefaults(suiteName: OpenDocumentStore.group)
        if let id = shared?.string(forKey: "document-open-desktop-id"),
           shared?.string(forKey: "document-open-domain") == credentials?.fileDomainIdentifier {
            let app = apps.first(where: { $0.id == id }) ?? HostClient.App(id: id, name: id, icon: "", categories: [], exec: "")
            if let window = appWindows.first(where: { matches($0, app) }) {
                presentedWindowID = window.id
                shared?.removeObject(forKey: "document-open-desktop-id")
                shared?.removeObject(forKey: "document-open-domain")
            }
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

    /// The desktop on this phone's or iPad's own screen, without a TV: the same windows,
    /// dock and Launchpad, driven by touch (and by a mouse or trackpad on an iPad).
    private(set) var deviceDesktopActive = false
    /// A desktop is up, on a TV or on this screen: windows float instead of filling the phone.
    var desktopActive: Bool { externalDisplayActive || deviceDesktopActive }

    private func desktopUI(forWidth width: CGFloat) -> CGFloat {
        (deviceDesktopActive ? DesktopModel.deviceUI(forWidth: width) : DesktopModel.automaticUI(forWidth: width)) * desktopZoom
    }

    /// The space each presentation receives after layout, with one geometry owner at a time.
    private var deviceViewport = DeviceViewport()
    var windowCardOwnsGeometry: Bool { deviceViewport.owner == .card }

    /// The Desktop tab reports the space it has for the desktop.
    func desktopStageResized(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        deviceViewport.updateDesktop(size)
        updateDeviceDesktop()
    }

    /// The desktop keeps its layout across tabs. While a card is presented, only the card
    /// owns guest geometry; stage measurements are saved for its eventual dismissal.
    func updateDeviceDesktop() {
        guard phase == .ready, selectedTab == .desktop, !externalDisplayActive, deviceViewport.owner == .desktop,
              deviceViewport.desktopSize != .zero else { return }
        if !deviceDesktopActive { openDeviceDesktop(size: deviceViewport.desktopSize) }
        else { deviceDesktopResized(to: deviceViewport.desktopSize) }
    }

    /// Takes the phone's desktop down so a window can be a full-screen card, keeping each
    /// window's place on it for when the desktop comes back.
    private func leaveDeviceDesktop() {
        guard deviceDesktopActive else { return }
        if let session { desktop.remember(Array(session.windows.values)) }
        closeDeviceDesktop()
    }

    func openDeviceDesktop(size: CGSize) {
        guard deviceViewport.owner == .desktop, !externalDisplayActive, size.width > 0, size.height > 0 else { return }
        deviceDesktopActive = true
        externalSize = size
        // The phone's own desktop renders at 2x like the rest of the app, not the screen's 3x:
        // indistinguishable at arm's length, and under half the pixels to encode and send.
        // Coming back, it is the same desktop: stacking, minimized windows and their places.
        let scale = min(2, max(1, UIScreen.main.scale))
        if !(desktop.directTouch && desktop.pixelsPerPoint == scale) { desktop = DesktopModel(pixelsPerPoint: scale) }
        desktop.directTouch = true
        desktop.ui = desktopUI(forWidth: size.width)
        desktop.size = size
        desktop.cursor = CGPoint(x: size.width / 2, y: size.height / 2)
        prepareYard()
        presentedWindowID = nil
        keyboardVisible = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        reconnectForDisplayChange()
    }

    /// Rotation, Stage Manager or Split View changed the desktop's size.
    func deviceDesktopResized(to size: CGSize) {
        guard deviceViewport.owner == .desktop, deviceDesktopActive, size.width > 0, size.height > 0, size != externalSize else { return }
        externalSize = size
        desktop.size = size
        desktop.ui = desktopUI(forWidth: size.width)
        reconnectForDisplayChange()
    }

    func closeDeviceDesktop() {
        guard deviceDesktopActive else { return }
        deviceDesktopActive = false
        keyboardVisible = false
        reconnectForDisplayChange()
    }

    func externalDisplayConnected(size: CGSize, scale: CGFloat) {
        // The TV takes the desktop over from the phone's own screen.
        deviceDesktopActive = false
        externalSize = size
        externalScale = scale
        desktop = DesktopModel(pixelsPerPoint: tvPixelsPerPoint(width: size.width, scale: scale))
        externalDisplayActive = true
        selectedTab = .desktop // the phone's Desktop tab is the TV's trackpad
        desktop.ui = desktopUI(forWidth: size.width)
        desktop.size = size
        desktop.cursor = CGPoint(x: size.width / 2, y: size.height / 2)
        presentedWindowID = nil
        deviceViewport.dismissCard()
        reconnectForDisplayChange()
    }

    private var externalScale: CGFloat = 1

    /// The big screen's desktop renders at 2560x1440 by default and the TV scales it to its
    /// own resolution: sharp from a couch, and under half the pixels of 4K for every scroll,
    /// animation and window move. "4K" renders at the screen's full pixels instead. Video
    /// never rides the desktop stream either way; it plays natively through media handoff.
    private(set) var desktopFull4K = UserDefaults.standard.bool(forKey: "desktopFull4K")

    private func tvPixelsPerPoint(width: CGFloat, scale: CGFloat) -> CGFloat {
        let full = max(1, scale)
        guard !desktopFull4K, width > 0 else { return full }
        return min(full, max(1, 2560 / width))
    }

    func toggleDesktopFull4K() {
        desktopFull4K.toggle()
        UserDefaults.standard.set(desktopFull4K, forKey: "desktopFull4K")
        guard externalDisplayActive else { return }
        let old = desktop.pixelsPerPoint
        let new = tvPixelsPerPoint(width: externalSize.width, scale: externalScale)
        guard old != new else { return }
        let replacement = DesktopModel(pixelsPerPoint: new)
        replacement.ui = desktop.ui
        replacement.size = desktop.size
        replacement.cursor = desktop.cursor
        replacement.sync(with: Array(session?.windows.values ?? [:].values))
        desktop = replacement
        // Windows keep their place and size on screen: rescale their Linux geometry.
        if let session {
            let ratio = new / old
            for window in session.windows.values where !window.isOverrideRedirect {
                let f = window.frame
                session.configure(window, frame: CGRect(x: f.minX * ratio, y: f.minY * ratio, width: f.width * ratio, height: f.height * ratio))
            }
        }
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
        desktop.ui = desktopUI(forWidth: externalSize.width)
        // Linux learns its new DPI from the next hello; the apps keep running.
        reconnectForDisplayChange()
    }

    func externalDisplayDisconnected() {
        externalDisplayActive = false
        reconnectForDisplayChange()
        updateDeviceDesktop()
    }

    /// The Linux apps keep running; only the display size the server lays them out for changes.
    private func reconnectForDisplayChange() {
        // A live session changes screens in place: every window stream stays open.
        if let session, session.state == .ready {
            session.reconfigure(displayCapabilities())
            placedWindowIDs.removeAll()
            yard.invalidate()
            sessionChanged()
            return
        }
        // While waking, the coming session is opened for the new screen; in the background, nothing opens.
        guard sceneActive, phase == .ready || phase == .connecting, let host, let lastDisplay else { return }
        phase = .connecting
        startSession(host: host, display: lastDisplay)
    }

    // MARK: Computer settings

    /// The host's management status: settings, what the machine runs with, and whether a restart applies them.
    private(set) var computerStatus: HostClient.ComputerStatus?
    var settingsPresented = false
    /// Settings › Agents on its own, from the Ask bar's menu.
    var showAgentSettings = false

    func refreshComputer() async throws {
        guard let host else { return }
        computerStatus = try await host.computer()
        LiveActivityCoordinator.shared.sync(agents.tasks)
    }

    /// Saves only the given changes. Name and auto-park apply at once; memory and cores at the next restart.
    func saveSettings(_ changes: [String: JSONValue]) async throws {
        guard let host, !changes.isEmpty else { return }
        computerStatus = try await host.updateSettings(changes)
    }

    /// A park is underway.
    private(set) var parking = false
    /// The wallpaper picker, from Home's background, the Desktop's menu or settings.
    var wallpaperPickerPresented = false
    /// The owner asked to restart and is being asked to confirm.
    var restartConfirmationPresented = false
    var lifecycleActionsPresented = false

    /// Parks the computer with its memory, so it resumes exactly as it was.
    func parkComputer() async throws {
        guard let host else { return }
        parking = true
        defer { parking = false }
        closeDisplay()
        do {
            try await host.park()
            phase = .parked
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
        try? await refreshComputer()
    }

    /// Cold-restarts the computer and reconnects. The person has already confirmed that open apps close.
    func restartComputer() async {
        guard let host else { return }
        settingsPresented = false
        closeDisplay()
        frameCache.removeAll() // the apps behind these frames are gone
        phase = .restarting
        do {
            computerStatus = try await host.restart()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await wake()
    }

    /// Drops the display and the agent channel without parking; the host decides what happens next.
    private func closeDisplay() {
        reconnectTask?.cancel()
        reconnectTask = nil
        presentedWindowID = nil
        presentedAgentWindowID = nil
        session?.disconnect()
        session = nil
        agents.detach()
        knownWindowIDs.removeAll()
    }


    private func refreshFileSearch() {
        guard let credentials else { return }
        fileSearchTask?.cancel()
        fileSearchTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                let files = try await ComputerSearch.refreshFiles(credentials: credentials)
                if self.credentials == credentials { recentFiles = RecentFiles.visible(files, limit: 8) }
            }
            catch { /* Keep the previous index when the computer is unavailable. */ }
        }
    }

    func refreshApps() async {
        guard let host else { return }
        for attempt in 0 ..< 10 {
            do {
                let list = try await host.apps()
                ComputerSearch.indexApps(list)
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

    /// Real applications, and desktop settings panels and system utilities apart from them.
    var partitionedApps: (main: [HostClient.App], system: [HostClient.App]) {
        let systemCategories: Set<String> = ["Settings", "DesktopSettings", "HardwareSettings", "System", "Monitor", "PackageManager"]
        let primary: Set<String> = ["WebBrowser", "TerminalEmulator", "TextEditor", "Office", "Development", "IDE", "Graphics", "AudioVideo", "FileManager"]
        var main: [HostClient.App] = [], system: [HostClient.App] = []
        for app in apps {
            let categories = Set(app.categories)
            if !categories.isDisjoint(with: primary) || categories.isDisjoint(with: systemCategories) { main.append(app) } else { system.append(app) }
        }
        return (main, system)
    }

    /// The big screen's dock, like a Mac's: one of each kind of everyday app the computer has
    /// (by .desktop id, then by category), then any other app with a window open.
    var dockApps: [HostClient.App] {
        let main = partitionedApps.main
        let wanted: [(ids: [String], category: String)] = [
            (["chromium", "google-chrome", "firefox"], "WebBrowser"),
            (["thunar", "nautilus", "nemo", "pcmanfm"], "FileManager"),
            (["xfce4-terminal", "ghostty", "alacritty", "kitty", "gnome-terminal"], "TerminalEmulator"),
            (["code", "vscodium", "zed"], "IDE"),
            (["obsidian"], ""),
            (["opencode"], ""),
            (["mousepad", "gedit", "gnome-text-editor"], "TextEditor"),
            (["libreoffice-writer"], "WordProcessor"),
            (["libreoffice-calc"], "Spreadsheet"),
            (["gimp"], "RasterGraphics"),
        ]
        var dock: [HostClient.App] = []
        for (ids, category) in wanted {
            let byID = ids.lazy.compactMap { id in main.first { $0.id.lowercased().hasPrefix(id) } }.first
            let byCategory = category.isEmpty ? nil : main.first { $0.categories.contains(category) }
            if let app = byID ?? byCategory, !dock.contains(where: { $0.id == app.id }) { dock.append(app) }
        }
        for window in appWindows {
            if let app = apps.first(where: { matches(window, $0) }), !dock.contains(where: { $0.id == app.id }) { dock.append(app) }
        }
        return Array(dock.prefix(14))
    }

    /// A dock click on the big screen: show the app's windows if it has any, else launch it.
    func openOnDesktop(_ app: HostClient.App) {
        let windows = appWindows.filter { matches($0, app) }
        if yardActive, let latest = windows.first {
            yard.focus(latest.id)
            return
        }
        if !yardActive, desktop.reveal(windows.map(\.id), session: session) { return }
        launch(app)
    }

    // MARK: Switchyard

    /// How the device's own desktop arranges windows. An iPad chooses; an iPhone always tiles.
    enum DeviceDesktopStyle: String { case tiled, free }

    private var chosenDesktopStyle = DeviceDesktopStyle(rawValue: UserDefaults.standard.string(forKey: "deviceDesktopStyle") ?? "") ?? .tiled

    var deviceDesktopStyle: DeviceDesktopStyle {
        get { UIDevice.current.userInterfaceIdiom == .pad ? chosenDesktopStyle : .tiled }
        set {
            guard UIDevice.current.userInterfaceIdiom == .pad, newValue != chosenDesktopStyle else { return }
            chosenDesktopStyle = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "deviceDesktopStyle")
            guard deviceDesktopActive else { return }
            // The same windows, rearranged: tiled into the yard, or set floating again.
            placedWindowIDs.removeAll()
            yard.invalidate()
            if newValue == .tiled { prepareYard() }
            sessionChanged()
        }
    }

    /// Switchyard: the computer's windows tiled on the device's own screen.
    let yard = YardModel()
    /// The yard is the desktop on this screen: the Desktop tab, no TV, tiled.
    var yardActive: Bool { deviceDesktopActive && deviceDesktopStyle == .tiled }

    private func prepareYard() {
        yard.storageKey = credentials.map { "switchyard." + $0.fileDomainIdentifier }
        // The same pixels as the floating desktop: 2x, whatever the screen.
        yard.pixelsPerPoint = desktop.pixelsPerPoint
        yard.session = session
        yard.learnAppClasses { [weak self] id in self?.session?.windows[id]?.appClass?.name }
    }

    /// ⌘⌥Return: a terminal, as on a Linux desktop.
    func openTerminalApp() {
        guard let terminal = partitionedApps.main.first(where: { $0.categories.contains("TerminalEmulator") }) else { return }
        open(terminal)
    }

    /// Opens an app: on the desktop when one is up, else as a full-screen card. A parked or
    /// sleeping computer is woken first.
    func open(_ app: HostClient.App) {
        recordOpen(app)
        if phase != .ready {
            Task {
                await wake()
                if phase == .connecting || phase == .ready { launch(app) }
            }
            return
        }
        if externalDisplayActive || (deviceDesktopActive && selectedTab == .desktop) {
            openOnDesktop(app)
            return
        }
        leaveDeviceDesktop()
        if let existing = appWindows.first(where: { matches($0, app) }) {
            presentedWindowID = existing.id
            return
        }
        launch(app)
    }

    // MARK: Home

    private static func shortcutsKey(_ credentials: Credentials) -> String { "caboose.shortcuts." + credentials.fileDomainIdentifier }

    private static func loadShortcuts(for credentials: Credentials?) -> AppShortcuts {
        guard let credentials, let data = UserDefaults.standard.data(forKey: shortcutsKey(credentials)),
              let saved = try? JSONDecoder().decode(AppShortcuts.self, from: data) else { return AppShortcuts() }
        return saved
    }

    private func saveShortcuts() {
        guard let credentials, let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: Self.shortcutsKey(credentials))
    }

    private func recordOpen(_ app: HostClient.App) {
        shortcuts.recordOpen(app.id)
        saveShortcuts()
    }

    func togglePin(_ app: HostClient.App) {
        shortcuts.togglePin(app.id)
        saveShortcuts()
    }

    var pinnedApps: [HostClient.App] {
        shortcuts.pinnedApps(available: Set(apps.map(\.id))).compactMap { id in apps.first { $0.id == id } }
    }

    func recentApps(limit: Int) -> [HostClient.App] {
        shortcuts.recentApps(available: Set(apps.map(\.id)), limit: limit).compactMap { id in apps.first { $0.id == id } }
    }

    /// Opens a home-relative file on the computer with its default app; the app's new
    /// window opens full screen on the phone.
    func openFile(_ path: String) async {
        guard let credentials else { return }
        if !(deviceDesktopActive && selectedTab == .desktop) { leaveDeviceDesktop() }
        openingFileSince = Date()
        do {
            try await HostShortcutFiles(credentials: credentials).open(path)
            if desktopActive { openingFileSince = nil }
        } catch {
            openingFileSince = nil
            launchFailure = "\((path as NSString).lastPathComponent) didn't open. \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Shows a window as a full-screen card, leaving the phone's desktop first if it is up.
    func show(windowID: Int) {
        presentedWindowID = windowID
    }

    /// Called after the cover finishes dismissing, so its disappearing view cannot fight
    /// the restored tiles for geometry. The layout itself stays in YardMemory throughout.
    func windowCardDismissed() {
        guard presentedWindowID == nil else { return }
        deviceViewport.dismissCard()
        yard.invalidate()
        if externalDisplayActive { reconnectForDisplayChange() }
        else { updateDeviceDesktop() }
    }

    /// The card's actual content viewport changes with folding, rotation and its controls.
    func windowCardResized(to size: CGSize) {
        guard deviceViewport.updateCard(size), !externalDisplayActive else { return }
        session?.reconfigure(displayCapabilities())
    }

    /// Follows a `caboose://` shell link.
    func follow(_ link: ShellLink) {
        switch link {
        case .tab(let tab): selectedTab = tab == .terminal && !TerminalSlot.isFilled ? .home : tab
        case .task(let id): notificationTaskID = id
        case .airPlay: selectedTab = .home; airPlay.connect()
        }
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

    func showLaunchedDocument(_ app: CatalogApp) {
        let target = apps.first(where: { $0.id == app.desktopId }) ?? HostClient.App(id: app.desktopId, name: app.name, icon: "", categories: [], exec: "")
        if let existing = appWindows.first(where: { matches($0, target) }) { presentedWindowID = existing.id }
        else { launching = target; launchStartedAt = Date() }
    }

    func matches(_ window: RemoteWindow, _ app: HostClient.App) -> Bool {
        guard let appClass = window.appClass else { return false }
        let id = app.id.replacingOccurrences(of: ".desktop", with: "").lowercased()
        return [appClass.instance.lowercased(), appClass.name.lowercased()].contains { $0 == id || id.hasSuffix($0) || $0.hasSuffix(id) }
    }

    func icon(for window: RemoteWindow) -> UIImage? {
        // An app whose id is the window's class beats one that only shares a prefix with it
        // (Thunar's window is Thunar, not Thunar's Bulk Rename).
        let names = [window.appClass?.instance, window.appClass?.name].compactMap { $0?.lowercased() }
        let exact = apps.first { names.contains($0.id.replacingOccurrences(of: ".desktop", with: "").lowercased()) }
        if let app = exact ?? apps.first(where: { matches(window, $0) }), let image = appIcons[app.id] { return image }
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

    private static func postDesktop(_ event: [String: Any]) {
        requestNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = (event["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (event["app"] as? String ?? "Caboose")
        content.body = event["body"] as? String ?? ""
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "linux.\(event["id"] as? String ?? UUID().uuidString)", content: content, trigger: nil))
    }

    private static func post(_ note: RemoteNotification) {
        requestNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = note.summary.isEmpty ? note.appName : note.summary
        content.subtitle = note.summary.isEmpty ? "" : note.appName
        content.body = note.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "linux.\(note.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
