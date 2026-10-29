import CabooseKit
import CoreLocation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's side of the native bridge (docs/native-bridge.md): answers the computer's
/// file requests with iOS pickers, sends the phone's appearance and (when shared) location,
/// and mirrors the computer's media in Now Playing.
@MainActor @Observable
final class NativeBridge {
    /// Why location cannot be shared, for the settings section.
    private(set) var locationProblem: String?

    @ObservationIgnored private var host: () -> HostClient? = { nil }
    @ObservationIgnored private var domain: () -> String? = { nil }
    @ObservationIgnored private var documents: () -> OpenDocumentCenter? = { nil }
    @ObservationIgnored private var active = false
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queue: [BridgeRequest] = []
    @ObservationIgnored private var current: (request: BridgeRequest, controller: UIViewController?)?
    @ObservationIgnored private var pickerDelegate: PickerDelegate?
    @ObservationIgnored private let appearance = AppearanceReporter()
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()
    @ObservationIgnored private lazy var location = LocationSharing { [weak self] problem in self?.locationProblem = problem }

    init() { BridgeSettings.register() }

    func attach(host: @escaping () -> HostClient?, domain: @escaping () -> String?, documents: @escaping () -> OpenDocumentCenter?) {
        self.host = host; self.domain = domain; self.documents = documents
        appearance.send = { [weak self] look in
            guard BridgeSettings.appearance, let host = self?.host() else { return }
            try await host.putAppearance(look)
        }
        nowPlaying.control = { [weak self] id, action, position in
            try await self?.host()?.nowPlayingControl(id, action: action, position: position)
        }
        location.host = { [weak self] in self?.host() }
    }

    /// The app is in the foreground (or not): requests are shown, location flows, only then.
    func setActive(_ active: Bool) {
        self.active = active
        location.setRunning(active && connected && BridgeSettings.location)
        if active { showNext() }
    }

    /// A control connection to the computer opened: the computer gets the phone's appearance.
    func controlConnected() {
        connected = true
        appearance.resend()
        location.setRunning(active && BridgeSettings.location)
    }

    /// The computer's connection is gone: what it asked for cannot be answered any more.
    func controlDisconnected() {
        connected = false
        nowPlaying.clear()
        location.setRunning(false)
    }

    /// Signed out or switched computers.
    func reset() {
        generation += 1
        queue.removeAll()
        if let controller = current?.controller { controller.presentingViewController?.dismiss(animated: true) }
        current = nil
        connected = false
        appearance.forget()
        nowPlaying.clear()
        location.setRunning(false)
    }

    /// While the phone plays a handed-off video itself, its player owns Now Playing.
    var nowPlayingSuspended: Bool {
        get { nowPlaying.suspended }
        set { nowPlaying.suspended = newValue }
    }

    func handle(_ type: String, _ event: [String: Any]) {
        switch type {
        case "bridge.request":
            guard let raw = event["request"], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let request = try? JSONDecoder().decode(BridgeRequest.self, from: data),
                  current?.request.id != request.id, !queue.contains(where: { $0.id == request.id }) else { return }
            guard BridgeSettings.dialogs else { answer(request, .computer); return }
            guard queue.count < 8 else { answer(request, .computer); return }
            queue.append(request)
            showNext()
        case "bridge.cancel":
            guard let id = event["id"] as? String else { return }
            queue.removeAll { $0.id == id }
            if current?.request.id == id { withdraw() }
        case "now-playing.changed":
            guard BridgeSettings.nowPlaying, let raw = event["nowPlaying"], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let state = try? JSONDecoder().decode(BridgeNowPlaying.self, from: data) else { return }
            nowPlaying.show(state)
        case "now-playing.stopped":
            if let id = event["id"] as? String { nowPlaying.stopped(id) }
        default: break
        }
    }

    // Settings ----------------------------------------------------------------------------

    func appearanceSettingChanged() { appearance.resend() }
    func nowPlayingSettingChanged() { if !BridgeSettings.nowPlaying { nowPlaying.clear() } }
    func locationSettingChanged() {
        if BridgeSettings.location {
            location.setRunning(active && connected)
        } else {
            location.stopSharing()
        }
    }

    // File requests -----------------------------------------------------------------------

    private func topController() -> UIViewController? {
        guard active, UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow), var controller = window.rootViewController else { return nil }
        while let next = controller.presentedViewController, !next.isBeingDismissed { controller = next }
        return controller
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty, let presenter = topController() else { return }
        let request = queue.removeFirst()
        let controller: UIViewController
        switch (request.type, request.directory) {
        case (.open, false):
            let types = request.contentTypes
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: false)
            picker.allowsMultipleSelection = request.multiple
            let delegate = PickerDelegate { [weak self] urls in self?.picked(urls, for: request) }
            picker.delegate = delegate
            pickerDelegate = delegate
            controller = picker
        case (.open, true), (.save, _):
            guard let host = host() else { answer(request, .computer); showNext(); return }
            let sheet = BridgeFileSheet(request: request, host: host) { [weak self] answer in self?.finish(request, answer) }
            let hosting = UIHostingController(rootView: sheet)
            hosting.modalPresentationStyle = .pageSheet
            hosting.sheetPresentationController?.detents = [.large()]
            hosting.sheetPresentationController?.prefersGrabberVisible = true
            hosting.isModalInPresentation = true
            controller = hosting
        }
        current = (request, controller)
        presenter.present(controller, animated: true)
    }

    /// The document picker returned: computer files answer with their own paths, others are
    /// copied to the computer and kept in sync with their originals.
    private func picked(_ urls: [URL], for request: BridgeRequest) {
        pickerDelegate = nil
        guard !urls.isEmpty else { finish(request, .cancel); return }
        guard let host = host(), let domain = domain(), let documents = documents() else { finish(request, .computer); return }
        let generation = generation
        let progress = UIHostingController(rootView: BridgeSendingView(count: urls.count))
        progress.modalPresentationStyle = .overFullScreen
        progress.modalTransitionStyle = .crossDissolve
        progress.view.backgroundColor = .clear
        current = (request, progress)
        topController()?.present(progress, animated: true)
        Task {
            do {
                var paths: [ComputerPath] = []
                for url in urls {
                    let relative = try await documents.computerPath(for: url, name: url.lastPathComponent, copyOnly: false, host: host, domain: domain)
                    guard let path = ComputerPath(relative: relative) else { throw HostClient.Failure.unreachable("The file's computer location is not valid.") }
                    paths.append(path)
                }
                // Later edits on either side sync as for any opened document (fs.changed, foreground).
                guard self.generation == generation, current?.request.id == request.id else { return }
                finish(request, .chose(paths, filter: request.currentFilter))
            } catch {
                guard self.generation == generation, current?.request.id == request.id else { return }
                failed(request, error)
            }
        }
    }

    private func failed(_ request: BridgeRequest, _ error: Error) {
        dismissCurrent { [weak self] in
            guard let self, let presenter = self.topController() else { self?.finish(request, .cancel); return }
            let alert = UIAlertController(title: "Couldn’t Send to the Computer", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Use Computer Dialog", style: .default) { [weak self] _ in self?.finish(request, .computer) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finish(request, .cancel) })
            self.current = (request, alert)
            presenter.present(alert, animated: true)
        }
    }

    private func finish(_ request: BridgeRequest, _ result: BridgeAnswer) {
        guard current?.request.id == request.id else { answer(request, result); return }
        dismissCurrent { [weak self] in
            self?.current = nil
            self?.answer(request, result)
            self?.showNext()
        }
    }

    /// The computer withdrew the request being shown.
    private func withdraw() {
        pickerDelegate = nil
        dismissCurrent { [weak self] in
            self?.current = nil
            self?.showNext()
        }
    }

    private func dismissCurrent(_ then: @escaping () -> Void) {
        guard let controller = current?.controller, controller.presentingViewController != nil else { then(); return }
        controller.presentingViewController?.dismiss(animated: true, completion: then)
    }

    private func answer(_ request: BridgeRequest, _ answer: BridgeAnswer) {
        guard let host = host() else { return }
        Task { _ = try? await host.answerBridge(request.id, answer) }
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

/// Sends the phone's appearance when it changes, and again for each new connection.
@MainActor
private final class AppearanceReporter {
    var send: (BridgeAppearance) async throws -> Void = { _ in }
    private var last: BridgeAppearance?
    private var observing = false
    private var sending = false

    func forget() { last = nil }

    func resend() {
        last = nil
        observe()
        report()
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
                     UIContentSizeCategory.didChangeNotification, UIApplication.didBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
                self?.report()
            }
        }
    }

    private func current() -> BridgeAppearance {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        let traits = scene?.traitCollection ?? UITraitCollection.current
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.tintColor.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return BridgeAppearance(dark: traits.userInterfaceStyle == .dark, accent: Double(red), Double(green), Double(blue),
                                highContrast: traits.accessibilityContrast == .high || UIAccessibility.isDarkerSystemColorsEnabled,
                                reducedMotion: UIAccessibility.isReduceMotionEnabled, contentSize: traits.preferredContentSizeCategory.rawValue)
    }

    private func report() {
        let look = current()
        guard look != last, !sending else { return }
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
