import CabooseKit
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's side of the native bridge (docs/native-bridge.md): answers the computer's
/// file requests with iOS pickers, sends the phone's appearance and (when shared) location,
/// and mirrors the computer's media in Now Playing.
///
/// Everything is bound to the computer it came from: a request, its upload and its answer
/// use the host it arrived from, and `BridgeLifecycle` fences callbacks so nothing begun for
/// one computer, connection or foreground acts after it.
@MainActor @Observable
final class NativeBridge {
    /// The computer a request, a track or a location belongs to.
    struct Computer {
        let host: HostClient
        /// The paired computer's identity (its File Provider domain).
        let id: String
        let documents: OpenDocumentCenter
    }

    /// Why location cannot be shared, for the settings section.
    private(set) var locationProblem: String?
    /// The computers the owner shares location with.
    private(set) var locationConsent = LocationConsent(UserDefaults.standard.stringArray(forKey: BridgeSettings.locationKey) ?? [])
    /// The computer currently paired, for the settings section.
    private(set) var computerID: String?

    @ObservationIgnored private var computer: () -> Computer? = { nil }
    @ObservationIgnored private var window: () -> UIWindow? = { nil }
    @ObservationIgnored private var life = BridgeLifecycle()
    @ObservationIgnored private var requests: [String: (request: BridgeRequest, computer: Computer)] = [:]
    @ObservationIgnored private var presented: (ticket: BridgeLifecycle.Ticket, controller: UIViewController)?
    @ObservationIgnored private var pickerDelegate: PickerDelegate?
    @ObservationIgnored private let appearance = AppearanceReporter()
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private lazy var location = LocationSharing { [weak self] problem in self?.locationProblem = problem }

    init() { BridgeSettings.register() }

    /// `computer` is the paired computer now; `window` is the app's main shell window (never an
    /// external display's), where sheets are presented and whose traits are the appearance.
    func attach(computer: @escaping () -> Computer?, window: @escaping () -> UIWindow?) {
        self.computer = computer
        self.window = window
        appearance.window = window
        appearance.send = { [weak self] look in
            guard BridgeSettings.appearance, let host = self?.computer()?.host else { return }
            try await host.putAppearance(look)
        }
    }

    /// The app is in the foreground (or not). The control connection closes in the
    /// background, so the computer shows its own dialog for what was shown or waiting here.
    func setActive(_ active: Bool) {
        dismiss(life.setActive(active))
        if !active { requests.removeAll() }
        updateLocation()
        if active { showNext() }
    }

    /// The control connection closed (AgentCenter's `onControlClosed`).
    func controlClosed() {
        dismiss(life.disconnect())
        requests.removeAll()
        nowPlaying.clear()
        updateLocation()
    }

    /// Signed out or switched computers: nothing from before may act.
    func reset() {
        dismiss(life.reset())
        requests.removeAll()
        computerID = nil
        appearance.forget()
        nowPlaying.clear()
        location.stop()
    }

    /// While the phone plays a handed-off video itself, its player owns Now Playing.
    var nowPlayingSuspended: Bool {
        get { nowPlaying.suspended }
        set { nowPlaying.suspended = newValue }
    }

    func handle(_ type: String, _ event: [String: Any]) {
        switch type {
        case "computer.state":
            // The first event on every control connection, and every lifecycle change.
            if event["state"] as? String == "running" { connected() } else { controlClosed() }
        case "bridge.request":
            guard let raw = event["request"], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let request = try? JSONDecoder().decode(BridgeRequest.self, from: data),
                  let computer = computer() else { return }
            switch life.receive(request.id, dialogs: BridgeSettings.dialogs) {
            case .queued:
                requests[request.id] = (request, computer)
                showNext()
            case .declined: send(.computer, for: request, to: computer)
            case .duplicate: break
            }
        case "bridge.cancel":
            guard let id = event["id"] as? String else { return }
            dismiss(life.withdraw(id))
            requests[id] = nil
        case "now-playing.changed":
            guard BridgeSettings.nowPlaying, let host = computer()?.host, let raw = event["nowPlaying"], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let state = try? JSONDecoder().decode(BridgeNowPlaying.self, from: data) else { return }
            nowPlaying.show(state, host: host)
        case "now-playing.stopped":
            if let id = event["id"] as? String { nowPlaying.stopped(id) }
        default: break
        }
    }

    private func connected() {
        life.connect()
        computerID = computer()?.id
        appearance.resend()
        updateLocation()
        showNext()
    }

    // Settings ----------------------------------------------------------------------------

    func appearanceSettingChanged() { appearance.resend() }
    func nowPlayingSettingChanged() { if !BridgeSettings.nowPlaying { nowPlaying.clear() } }

    /// Whether this phone shares its location with the paired computer.
    var sharesLocation: Bool { locationConsent.allows(computerID) }

    func setSharesLocation(_ shared: Bool) {
        guard let current = computer() else { return }
        locationConsent.set(shared, for: current.id)
        UserDefaults.standard.set(locationConsent.stored, forKey: BridgeSettings.locationKey)
        if shared {
            updateLocation()
        } else {
            location.stop()
            locationProblem = nil
            Task { try? await current.host.deleteLocation() }
        }
    }

    /// Location flows to the paired computer only while it has consent, the app is in front
    /// and connected.
    private func updateLocation() {
        guard life.active, life.connected, let current = computer(), locationConsent.allows(current.id) else {
            location.stop()
            return
        }
        location.start(for: current.id, host: current.host)
    }

    // File requests -----------------------------------------------------------------------

    /// Where sheets go: the top of the main shell window's presentations, while it is in front.
    private func topController() -> UIViewController? {
        guard life.active, UIApplication.shared.applicationState == .active, let window = window(),
              window.windowScene?.activationState == .foregroundActive, var controller = window.rootViewController else { return nil }
        while let next = controller.presentedViewController, !next.isBeingDismissed { controller = next }
        return controller
    }

    private func showNext() {
        guard presented == nil, let presenter = topController() else { return }
        while let ticket = life.next() {
            guard let (request, computer) = requests[ticket.request] else { _ = life.finish(ticket); continue }
            let controller: UIViewController
            switch (request.type, request.directory) {
            case (.open, false):
                let types = request.contentTypes
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: false)
                picker.allowsMultipleSelection = request.multiple
                let delegate = PickerDelegate { [weak self] urls in self?.picked(urls, ticket: ticket) }
                picker.delegate = delegate
                pickerDelegate = delegate
                controller = picker
            case (.open, true), (.save, _):
                let sheet = BridgeFileSheet(request: request, host: computer.host) { [weak self] answer in self?.finish(ticket, answer) }
                let hosting = UIHostingController(rootView: sheet)
                hosting.modalPresentationStyle = .pageSheet
                hosting.sheetPresentationController?.detents = [.large()]
                hosting.sheetPresentationController?.prefersGrabberVisible = true
                hosting.isModalInPresentation = true
                controller = hosting
            }
            presented = (ticket, controller)
            presenter.present(controller, animated: true)
            return
        }
    }

    /// The document picker returned: computer files answer with their own paths, others are
    /// copied to the computer the request came from and kept in sync with their originals.
    private func picked(_ urls: [URL], ticket: BridgeLifecycle.Ticket) {
        pickerDelegate = nil
        // A picker from before a reset, a lost connection or the background does nothing.
        guard life.isCurrent(ticket), let (request, computer) = requests[ticket.request] else { return }
        guard !urls.isEmpty else { finish(ticket, .cancel); return }
        let progress = UIHostingController(rootView: BridgeSendingView(count: urls.count))
        progress.modalPresentationStyle = .overFullScreen
        progress.modalTransitionStyle = .crossDissolve
        progress.view.backgroundColor = .clear
        presented = (ticket, progress)
        topController()?.present(progress, animated: true)
        Task {
            do {
                var paths: [ComputerPath] = []
                for url in urls {
                    guard life.isCurrent(ticket) else { return }
                    let relative = try await computer.documents.computerPath(for: url, name: url.lastPathComponent, copyOnly: false,
                                                                             host: computer.host, domain: computer.id)
                    guard life.isCurrent(ticket) else { return }
                    guard let path = ComputerPath(relative: relative) else { throw HostClient.Failure.unreachable("The file's computer location is not valid.") }
                    paths.append(path)
                }
                // Later edits on either side sync as for any opened document (fs.changed, foreground).
                finish(ticket, .chose(paths, filter: request.currentFilter))
            } catch {
                failed(ticket, error)
            }
        }
    }

    private func failed(_ ticket: BridgeLifecycle.Ticket, _ error: Error) {
        guard life.isCurrent(ticket) else { return }
        replacePresented(for: ticket) { [weak self] in
            guard let self, self.life.isCurrent(ticket), let presenter = self.topController() else { self?.finish(ticket, .cancel); return }
            let alert = UIAlertController(title: "Couldn’t Send to the Computer", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Use Computer Dialog", style: .default) { [weak self] _ in self?.finish(ticket, .computer) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(ticket, .cancel) })
            self.presented = (ticket, alert)
            presenter.present(alert, animated: true)
        }
    }

    /// Answers the shown request, to the computer it came from, once.
    private func finish(_ ticket: BridgeLifecycle.Ticket, _ result: BridgeAnswer) {
        guard life.finish(ticket), let (request, computer) = requests.removeValue(forKey: ticket.request) else { return }
        send(result, for: request, to: computer)
        dismiss(ticket)
    }

    private func send(_ answer: BridgeAnswer, for request: BridgeRequest, to computer: Computer) {
        Task { _ = try? await computer.host.answerBridge(request.id, answer) }
    }

    /// Takes down what is shown for `ticket`, if anything, then shows the next request.
    private func dismiss(_ ticket: BridgeLifecycle.Ticket?) {
        guard let ticket, let shown = presented, shown.ticket == ticket else { return }
        presented = nil
        pickerDelegate = nil
        guard shown.controller.presentingViewController != nil else { showNext(); return }
        shown.controller.presentingViewController?.dismiss(animated: true) { [weak self] in self?.showNext() }
    }

    /// Takes down what is shown for `ticket` to show something else for it.
    private func replacePresented(for ticket: BridgeLifecycle.Ticket, then: @escaping () -> Void) {
        guard let shown = presented, shown.ticket == ticket, shown.controller.presentingViewController != nil else { then(); return }
        shown.controller.presentingViewController?.dismiss(animated: true, completion: then)
    }
}

private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let done: ([URL]) -> Void
    init(done: @escaping ([URL]) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}

/// Shown while picked files go to the computer.
private struct BridgeSendingView: View {
    let count: Int
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(count == 1 ? "Sending to Computer…" : "Sending \(count) Files to Computer…").font(.headline)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.2))
    }
}

/// Sends the main window's appearance when it changes, and again for each new connection.
@MainActor
private final class AppearanceReporter {
    var send: (BridgeAppearance) async throws -> Void = { _ in }
    var window: () -> UIWindow? = { nil }
    private var last: BridgeAppearance?
    private var observing = false
    private weak var observedWindow: UIWindow?
    private var sending = false

    func forget() { last = nil }

    func resend() {
        last = nil
        observe()
        report()
    }

    private func observe() {
        if !observing {
            observing = true
            for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                         UIContentSizeCategory.didChangeNotification, UIApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
        }
        // The shell window's traits, not an external display's: re-registered if the window changes.
        guard let window = window(), window !== observedWindow else { return }
        observedWindow = window
        window.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIWindow, _: UITraitCollection) in
            self?.report()
        }
    }

    private func current() -> BridgeAppearance? {
        guard let traits = window()?.traitCollection else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.tintColor.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return BridgeAppearance(dark: traits.userInterfaceStyle == .dark, accent: Double(red), Double(green), Double(blue),
                                highContrast: traits.accessibilityContrast == .high || UIAccessibility.isDarkerSystemColorsEnabled,
                                reducedMotion: UIAccessibility.isReduceMotionEnabled, contentSize: traits.preferredContentSizeCategory.rawValue)
    }

    private func report() {
        guard let look = current(), look != last, !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await send(look)
                last = look
            } catch { return } // the next change or connection sends it again
            if current() != look { report() }
        }
    }
}
