import CabooseKit
import UIKit

/// A small download seam; replace this implementation with the streamed /v1/fs client.
protocol PhoneFileDownloading {
    func downloadPhoneFile(id: String) async throws -> Data
}

extension HostClient: PhoneFileDownloading {
    func downloadPhoneFile(id: String) async throws -> Data {
        struct Download: Decodable { let data: String }
        let result: Download = try await request("GET", "/v1/phone/files/\(id)", timeout: 300)
        guard let data = Data(base64Encoded: result.data), data.count <= PhoneEvent.maxFileBytes else {
            throw PhoneHandoff.Error.invalidFile
        }
        return data
    }
}

@MainActor
final class PhoneHandoff {
    enum Error: LocalizedError {
        case invalidFile, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "The computer returned an invalid file."
            case .unavailable: return "The computer is not connected."
            }
        }
    }
    private var pending: [PhoneEvent] = []
    private var presenting = false
    private var generation = 0
    private var host: () -> (any PhoneFileDownloading)? = { nil }
    private var active = false

    func attach(host: @escaping () -> (any PhoneFileDownloading)?) { self.host = host }
    func setActive(_ active: Bool) { self.active = active; if active { showNext() } }
    func reset() { pending.removeAll(); generation += 1 }

    func handle(_ type: String, _ event: [String: Any]) {
        guard type.hasPrefix("phone."), JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let parsed = try? JSONDecoder().decode(PhoneEvent.self, from: data) else { return }
        enqueue(parsed)
    }
    func open(_ url: URL) { if PhoneEvent.allowedURL(url) { enqueue(.open(url)) } }

    private func enqueue(_ event: PhoneEvent) {
        guard pending.count < 20 else { return }
        pending.append(event)
        showNext()
    }
    private func topController() -> UIViewController? {
        guard active, UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow), var controller = window.rootViewController else { return nil }
        while let next = controller.presentedViewController { controller = next }
        return controller
    }
    private func showNext() {
        guard !presenting, !pending.isEmpty, let controller = topController() else { return }
        presenting = true
        let event = pending.removeFirst()
        let eventGeneration = generation
        let title: String
        let message: String
        switch event {
        case .open(let url): title = "Open on iPhone?"; message = url.absoluteString
        case .share(let file): title = "Share from your computer?"; message = "\(file.name) (\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)))"
        case .print(let file): title = "Print from your computer?"; message = file.name
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.finished() })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            guard let self else { return }
            guard self.generation == eventGeneration else { self.finished(); return }
            switch event {
            case .open(let url):
                if self.active && UIApplication.shared.applicationState == .active { UIApplication.shared.open(url) }
                self.finished()
            case .share(let file), .print(let file):
                Task { await self.downloadAndPresent(file, printing: { if case .print = event { return true }; return false }(), generation: eventGeneration) }
            }
        })
        controller.present(alert, animated: true)
    }
    private func downloadAndPresent(_ file: PhoneEvent.File, printing: Bool, generation: Int) async {
        do {
            guard let host = host() else { throw Error.unavailable }
            try await Task.sleep(for: .milliseconds(300)) // Let the confirmation alert finish dismissing.
            let data = try await host.downloadPhoneFile(id: file.id)
            guard data.count == file.size, !printing || data.starts(with: Data("%PDF-".utf8)) else { throw Error.invalidFile }
            guard self.generation == generation, let controller = topController() else { throw Error.unavailable }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.name)
            try data.write(to: url, options: .atomic)
            if printing {
                let printer = UIPrintInteractionController.shared
                let info = UIPrintInfo(dictionary: nil)
                info.outputType = .general
                info.jobName = file.name
                printer.printInfo = info
                printer.printingItem = url
                let done: UIPrintInteractionController.CompletionHandler = { [weak self] _, _, _ in
                    try? FileManager.default.removeItem(at: directory)
                    self?.finished()
                }
                let shown: Bool
                if UIDevice.current.userInterfaceIdiom == .pad {
                    shown = printer.present(from: controller.view.bounds, in: controller.view, animated: true, completionHandler: done)
                } else { shown = printer.present(animated: true, completionHandler: done) }
                if !shown {
                    try? FileManager.default.removeItem(at: directory)
                    throw Error.unavailable
                }
            } else {
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = controller.view
                sheet.popoverPresentationController?.sourceRect = controller.view.bounds
                sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    try? FileManager.default.removeItem(at: directory)
                    self?.finished()
                }
                controller.present(sheet, animated: true)
            }
        } catch {
            if self.generation == generation, let controller = topController() {
                let alert = UIAlertController(title: "Could not hand off", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finished() })
                controller.present(alert, animated: true)
            } else { finished() }
        }
    }
    private func finished() {
        presenting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showNext() }
    }
}
