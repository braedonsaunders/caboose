import AVFoundation
import CabooseKit
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// The phone's side of the native bridge (docs/native-bridge.md): answers the computer's
/// file requests with iOS pickers, Photos, the camera and the document scanner, and its scan
/// requests with the scanner; sends the phone's appearance and (when shared) location,
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
    /// The delegate of the picker, camera or scanner shown (UIKit holds delegates weakly).
    @ObservationIgnored private var pickerDelegate: NSObject?
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
            guard let raw = event["request"] as? [String: Any], let computer = computer() else { return }
            guard JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw),
                  let request = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
                // One this app cannot show (from a newer computer) goes back to the computer now.
                if let id = raw["id"] as? String, id.utf8.count == 32,
                   id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    send(.computer, id: id, to: computer)
                }
                return
            }
            // A scan is asked for on purpose, so the Open and Save switch does not decline it.
            switch life.receive(request.id, dialogs: request.type == .scan || BridgeSettings.dialogs) {
            case .queued:
                requests[request.id] = (request, computer)
                showNext()
            case .declined: send(.computer, id: request.id, to: computer)
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

    // File and scan requests --------------------------------------------------------------

    /// Where sheets go: the top of the main shell window's presentations, while it is in front.
    private func topController() -> UIViewController? {
        guard life.active, UIApplication.shared.applicationState == .active, let window = window(),
              window.windowScene?.activationState == .foregroundActive, var controller = window.rootViewController else { return nil }
        while let next = controller.presentedViewController, !next.isBeingDismissed { controller = next }
        return controller
    }

    /// Where an Open request can take its file from on this phone.
    private func sources(for request: BridgeRequest) -> [BridgeSource] {
        BridgeMedia.sources(for: request, camera: UIImagePickerController.isSourceTypeAvailable(.camera),
                            scanner: VNDocumentCameraViewController.isSupported)
    }

    private func showNext() {
        guard presented == nil, let presenter = topController() else { return }
        while let ticket = life.next() {
            guard let (request, computer) = requests[ticket.request] else { _ = life.finish(ticket); continue }
            let controller: UIViewController
            switch (request.type, request.directory) {
            case (.open, false):
                let offered = sources(for: request)
                controller = offered.count > 1 ? chooser(request, sources: offered, ticket: ticket) : documentPicker(request, ticket: ticket)
            case (.scan, _):
                // The computer has no scanner to fall back to: a phone without one says so.
                guard VNDocumentCameraViewController.isSupported else { finish(ticket, .computer); continue }
                withCamera(ticket) { [weak self] in self?.showScanner(ticket) }
                return
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

    // Sources ------------------------------------------------------------------------------

    private func chooser(_ request: BridgeRequest, sources: [BridgeSource], ticket: BridgeLifecycle.Ticket) -> UIViewController {
        let sheet = BridgeSourceSheet(request: request, sources: sources) { [weak self] choice in self?.chose(choice, ticket: ticket) }
        let hosting = UIHostingController(rootView: sheet)
        hosting.modalPresentationStyle = .pageSheet
        hosting.sheetPresentationController?.detents = [.medium(), .large()]
        hosting.sheetPresentationController?.prefersGrabberVisible = true
        hosting.isModalInPresentation = true
        return hosting
    }

    private func chose(_ choice: BridgeSourceSheet.Choice, ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        switch choice {
        case .cancel: finish(ticket, .cancel)
        case .computer: finish(ticket, .computer)
        case .source(.files): show(documentPicker(request, ticket: ticket), for: ticket)
        case .source(.photos):
            let delegate = BridgePhotosDelegate { [weak self] results in self?.pickedPhotos(results, ticket: ticket) }
            pickerDelegate = delegate
            show(bridgePhotoPicker(for: request, delegate: delegate), for: ticket)
        case .source(.camera):
            withCamera(ticket) { [weak self] in
                guard let self else { return }
                let delegate = BridgeCameraDelegate { [weak self] info in self?.captured(info, ticket: ticket) }
                self.pickerDelegate = delegate
                self.show(bridgeCamera(for: request, delegate: delegate), for: ticket)
            }
        case .source(.scan): withCamera(ticket) { [weak self] in self?.showScanner(ticket) }
        }
    }

    /// A source closed without a choice: back to the sources when there are several, else
    /// the request is cancelled.
    private func back(_ ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        let offered = request.type == .open ? sources(for: request) : []
        if offered.count > 1 {
            show(chooser(request, sources: offered, ticket: ticket), for: ticket)
        } else {
            finish(ticket, .cancel)
        }
    }

    private func documentPicker(_ request: BridgeRequest, ticket: BridgeLifecycle.Ticket) -> UIViewController {
        let types = request.contentTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: false)
        picker.allowsMultipleSelection = request.multiple
        let delegate = BridgeDocumentPickerDelegate { [weak self] urls in self?.picked(urls, ticket: ticket) }
        picker.delegate = delegate
        pickerDelegate = delegate
        return picker
    }

    private func showScanner(_ ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket) else { return }
        let scanner = VNDocumentCameraViewController()
        let delegate = BridgeScannerDelegate { [weak self] result in self?.scanned(result, ticket: ticket) }
        scanner.delegate = delegate
        scanner.modalPresentationStyle = .fullScreen
        pickerDelegate = delegate
        show(scanner, for: ticket)
    }

    /// Runs `start` once the camera may be used; otherwise says how to allow it.
    private func withCamera(_ ticket: BridgeLifecycle.Ticket, _ start: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            Task { [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.life.isCurrent(ticket) else { return }
                if allowed { start() } else { self.cameraDenied(ticket) }
            }
        default: cameraDenied(ticket)
        }
    }

    private func cameraDenied(_ ticket: BridgeLifecycle.Ticket) {
        failed(ticket, BridgeMediaError("Allow Camera for Caboose in Settings to take photos and scan documents."), title: "Camera Not Allowed")
    }

    // Results ------------------------------------------------------------------------------

    /// The document picker returned: computer files answer with their own paths, others are
    /// copied to the computer the request came from and kept in sync with their originals.
    private func picked(_ urls: [URL], ticket: BridgeLifecycle.Ticket) {
        // A picker from before a reset, a lost connection or the background does nothing,
        // and leaves the current picker's delegate alone.
        guard life.isCurrent(ticket) else { return }
        pickerDelegate = nil
        guard !urls.isEmpty else { back(ticket); return }
        let uploads = urls.map { BridgeUpload(url: $0, name: $0.lastPathComponent, synced: true) }
        send(ticket, count: urls.count) { _ in uploads }
    }

    private func pickedPhotos(_ results: [PHPickerResult], ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        pickerDelegate = nil
        guard !results.isEmpty else { back(ticket); return }
        let media = BridgeMedia(request)
        let providers = results.map(\.itemProvider)
        send(ticket, count: providers.count) { folder in
            var uploads: [BridgeUpload] = []
            for provider in providers {
                let upload = try await BridgeMediaExport.picked(provider, media: media, into: folder)
                uploads.append(upload)
            }
            return uploads
        }
    }

    private func captured(_ info: [UIImagePickerController.InfoKey: Any]?, ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        pickerDelegate = nil
        let media = BridgeMedia(request)
        let date = Date()
        if let movie = info?[.mediaURL] as? URL {
            send(ticket, count: 1) { folder in
                let upload = try await BridgeMediaExport.recorded(movie, media: media, at: date, into: folder)
                return [upload]
            }
        } else if let image = info?[.originalImage] as? UIImage {
            let metadata = info?[.mediaMetadata] as? [String: Any] ?? [:]
            send(ticket, count: 1) { folder in
                let upload = try BridgeMediaExport.photo(image, metadata: metadata, media: media, at: date, into: folder)
                return [upload]
            }
        } else {
            back(ticket)
        }
    }

    private func scanned(_ result: Result<[UIImage], Error>?, ticket: BridgeLifecycle.Ticket) {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        pickerDelegate = nil
        let pages: [UIImage]
        switch result {
        case nil: back(ticket); return
        case .failure(let error)?: failed(ticket, error); return
        case .success(let scanned)?: pages = scanned
        }
        guard !pages.isEmpty, let format = BridgeMedia(request).scanFormat else { back(ticket); return }
        if case .pages = format {
            guard pages.count <= 64 else { failed(ticket, BridgeMediaError("A scan sent as images can have at most 64 pages.")); return }
            if !request.multiple && pages.count > 1 {
                let alert = UIAlertController(title: "Send the First Page?",
                                              message: "\(request.appName ?? "The app") opens one image, and this scan has \(pages.count) pages.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Send First Page", style: .default) { [weak self] _ in
                    self?.sendScan([pages[0]], format: format, ticket: ticket)
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.back(ticket) })
                show(alert, for: ticket)
                return
            }
        }
        sendScan(pages, format: format, ticket: ticket)
    }

    private func sendScan(_ pages: [UIImage], format: BridgeMedia.ScanFormat, ticket: BridgeLifecycle.Ticket) {
        let date = Date()
        send(ticket, count: format == .pdf ? 1 : pages.count) { folder in
            try BridgeMediaExport.scan(pages, as: format, at: date, into: folder)
        }
    }

    /// Makes the files for `ticket` off the main thread in a temporary folder, sends them to
    /// the computer the request came from, and answers with their paths, showing progress
    /// meanwhile. Picked documents stay in sync with their originals; new files have none.
    private func send(_ ticket: BridgeLifecycle.Ticket, count: Int, make: @escaping @Sendable (URL) async throws -> [BridgeUpload]) {
        guard life.isCurrent(ticket), let (request, computer) = requests[ticket.request] else { return }
        let progress = UIHostingController(rootView: BridgeSendingView(count: count))
        progress.modalPresentationStyle = .overFullScreen
        progress.modalTransitionStyle = .crossDissolve
        progress.view.backgroundColor = .clear
        show(progress, for: ticket)
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bridge-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let uploads = try await Task.detached(priority: .userInitiated) { try await make(folder) }.value
                var paths: [ComputerPath] = []
                for upload in uploads {
                    guard life.isCurrent(ticket) else { return }
                    let relative: String
                    if upload.synced {
                        relative = try await computer.documents.computerPath(for: upload.url, name: upload.name, copyOnly: false,
                                                                             host: computer.host, domain: computer.id)
                    } else {
                        relative = try await computer.documents.newDocumentPath(for: upload.url, name: upload.name, host: computer.host)
                    }
                    guard life.isCurrent(ticket) else { return }
                    guard let path = ComputerPath(relative: relative) else { throw HostClient.Failure.unreachable("The file's computer location is not valid.") }
                    paths.append(path)
                }
                // Later edits to a picked document sync as for any opened one (fs.changed, foreground).
                finish(ticket, .chose(paths, filter: request.currentFilter))
            } catch {
                failed(ticket, error)
            }
        }
    }

    private func failed(_ ticket: BridgeLifecycle.Ticket, _ error: Error, title: String = "Couldn’t Send to the Computer") {
        guard life.isCurrent(ticket), let (request, _) = requests[ticket.request] else { return }
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        // A scan has no computer dialog to fall back to.
        if request.type != .scan {
            alert.addAction(UIAlertAction(title: "Use Computer Dialog", style: .default) { [weak self] _ in self?.finish(ticket, .computer) })
        }
        alert.addAction(UIAlertAction(title: request.type == .scan ? "OK" : "Cancel", style: .cancel) { [weak self] _ in self?.finish(ticket, .cancel) })
        show(alert, for: ticket)
    }

    // Presentation -------------------------------------------------------------------------

    /// Answers the shown request, to the computer it came from, once.
    private func finish(_ ticket: BridgeLifecycle.Ticket, _ result: BridgeAnswer) {
        guard life.finish(ticket), let (request, computer) = requests.removeValue(forKey: ticket.request) else { return }
        send(result, id: request.id, to: computer)
        dismiss(ticket)
    }

    private func send(_ answer: BridgeAnswer, id: String, to computer: Computer) {
        Task { _ = try? await computer.host.answerBridge(id, answer) }
    }

    /// Shows `controller` for `ticket` in place of what is shown for it. Without a window to
    /// show it in, the computer shows its own dialog.
    private func show(_ controller: UIViewController, for ticket: BridgeLifecycle.Ticket) {
        replacePresented(for: ticket) { [weak self] in
            guard let self, self.life.isCurrent(ticket) else { return }
            guard let presenter = self.topController() else { self.finish(ticket, .computer); return }
            self.presented = (ticket, controller)
            presenter.present(controller, animated: true)
        }
    }

    /// Takes down what is shown for `ticket`, if anything, then shows the next request.
    private func dismiss(_ ticket: BridgeLifecycle.Ticket?) {
        guard let ticket else { return }
        // Nothing shown yet (the camera permission prompt is up): the next one may show now.
        guard let shown = presented, shown.ticket == ticket else { showNext(); return }
        presented = nil
        pickerDelegate = nil
        takeDown(shown.controller) { [weak self] in self?.showNext() }
    }

    /// Takes down what is shown for `ticket` to show something else for it.
    private func replacePresented(for ticket: BridgeLifecycle.Ticket, then: @escaping () -> Void) {
        guard let shown = presented, shown.ticket == ticket else { then(); return }
        takeDown(shown.controller, then: then)
    }

    /// Dismisses `controller` if it is up, or waits for a dismissal under way (a picker that
    /// closes itself), then runs `then`.
    private func takeDown(_ controller: UIViewController, then: @escaping () -> Void) {
        if controller.isBeingDismissed, let coordinator = controller.transitionCoordinator {
            if !coordinator.animate(alongsideTransition: nil, completion: { _ in then() }) { then() }
        } else if let presenting = controller.presentingViewController, !controller.isBeingDismissed {
            presenting.dismiss(animated: true, completion: then)
        } else {
            then()
        }
    }
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
        .glassEffect(.regular, in: .surface(cornerRadius: 24))
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
