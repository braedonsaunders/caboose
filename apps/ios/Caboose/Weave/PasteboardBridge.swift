import CabooseKit
import UIKit
import UniformTypeIdentifiers

/// The phone's pasteboard and the computer's clipboard, both ways, with text, images and
/// files (docs/display.md, Clipboard), and the results of drag and drop.
///
/// - A copy on the computer lands on the pasteboard with its text and image; files it
///   names under the computer's home are downloaded first and put on the pasteboard as
///   files, with their names.
/// - A copy on the phone is offered when the app becomes active: its text, its image
///   (PNG or JPEG) and its files, which are uploaded to the computer's transfer area so
///   Linux applications can paste them.
/// - What the phone takes from a computer drag goes to the `shelf`.
///
/// Failures are reported in an alert; nothing is pretended.
@MainActor
final class PasteboardBridge {
    /// The most downloaded for one copy or drag from the computer.
    static let downloadLimit: Int64 = 256 * 1024 * 1024

    /// What the phone took from a computer drag.
    let shelf = DragShelf()
    private var changeCount = UIPasteboard.general.changeCount
    private var receiving: Task<Void, Never>?
    private var offering: Task<Void, Never>?
    private var downloads: URL?

    /// Routes the computer's copies to the pasteboard, its drags to the shelf, and drop
    /// failures to an alert.
    func attach(_ session: any DisplaySession, host: HostClient) {
        session.onClipboard = { [weak self] content in self?.received(content, host: host) }
        session.onDragData = { [weak self] content in self?.shelf.receive(content, host: host) }
        session.onDropResult = { ok, reason in
            guard !ok, let message = Self.dropFailure(reason) else { return }
            Self.report("Drop failed", message)
        }
    }

    static func dropFailure(_ reason: String?) -> String? {
        switch reason {
        case "cancelled": nil
        case "rejected": "The app under your finger did not take the drop."
        case "timeout": "The app did not finish taking the drop."
        default: "The drop could not be sent to your computer."
        }
    }

    // MARK: Computer → phone

    private func received(_ content: ClipboardContent, host: HostClient) {
        receiving?.cancel()
        guard let paths = content.filePaths else {
            write(content, files: [])
            return
        }
        receiving = Task { [weak self] in
            let fetched = await Self.fetch(paths, host: host)
            guard let self, !Task.isCancelled else {
                if let directory = fetched.directory { try? FileManager.default.removeItem(at: directory) }
                return
            }
            if let previous = downloads { try? FileManager.default.removeItem(at: previous) }
            downloads = fetched.directory
            write(content, files: fetched.files)
            if !fetched.problems.isEmpty {
                Self.report(fetched.files.isEmpty ? "Files were not copied to iPhone" : "Some files were not copied to iPhone",
                            fetched.problems.prefix(3).joined(separator: "\n"))
            }
        }
    }

    /// Downloads files the computer named, under its home only, within `downloadLimit`
    /// together, into a new private directory.
    static func fetch(_ paths: [String], host: HostClient) async -> (directory: URL?, files: [URL], problems: [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("computer-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return (nil, [], [error.localizedDescription]) }
        var files: [URL] = []
        var problems: [String] = []
        var budget = downloadLimit
        for path in paths {
            guard !Task.isCancelled else { break }
            guard let relative = ClipboardPolicy.homeRelative(path) else {
                problems.append("\((path as NSString).lastPathComponent) is outside your computer's home.")
                continue
            }
            do {
                let file = try await host.downloadHomeFile(relative, into: directory.appendingPathComponent(UUID().uuidString), limit: budget)
                budget -= Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
                files.append(file)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return (directory, files, problems)
    }

    /// Item providers for a copy: one item with its text and image, and one per file.
    static func providers(_ content: ClipboardContent?, files: [URL]) -> [NSItemProvider] {
        var providers: [NSItemProvider] = []
        let main = NSItemProvider()
        var hasMain = false
        for (mime, type) in [(ClipboardPolicy.text, UTType.utf8PlainText), (ClipboardPolicy.png, .png), (ClipboardPolicy.jpeg, .jpeg)] {
            guard let data = content?.data(mime) else { continue }
            main.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            hasMain = true
        }
        if hasMain { providers.append(main) }
        for file in files {
            guard let provider = NSItemProvider(contentsOf: file) else { continue }
            provider.suggestedName = file.lastPathComponent
            providers.append(provider)
        }
        return providers
    }

    private func write(_ content: ClipboardContent, files: [URL]) {
        let providers = Self.providers(content, files: files)
        guard !providers.isEmpty else { return }
        UIPasteboard.general.setItemProviders(providers, localOnly: false, expirationDate: nil)
        // The app's own write is not a copy on the phone.
        changeCount = UIPasteboard.general.changeCount
    }

    // MARK: Phone → computer

    /// Offers the pasteboard to the computer if it changed since the app last looked.
    func offerIfChanged(to session: (any DisplaySession)?, host: HostClient?) {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != changeCount, let session, let host else { return }
        changeCount = pasteboard.changeCount
        offering?.cancel()
        let providers = pasteboard.itemProviders
        offering = Task {
            do {
                let items = try await StagedItems.read(providers, imageAsFile: false)
                defer { items.removeTemporaryFiles() }
                guard !items.isEmpty else { return }
                let files = try await items.upload(to: host)
                try Task.checkCancellation()
                if let content = ClipboardPolicy.content(text: items.text, images: items.images, files: files) {
                    session.offerClipboard(content)
                }
            } catch is CancellationError {
            } catch {
                Self.report("Your copy was not sent to your computer", error.localizedDescription)
            }
        }
    }

    // MARK: Reporting

    static func report(_ title: String, _ message: String) {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = controller.presentedViewController { controller = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}
