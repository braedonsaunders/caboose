import CabooseKit
import UIKit
import UniformTypeIdentifiers

/// The phone's pasteboard and the computer's clipboard, both ways, with text, images and
/// files (docs/display.md, Clipboard).
///
/// - A copy on the computer lands on the pasteboard with its text and image; files it
///   names under the computer's home are downloaded first and put on the pasteboard as
///   files, with their names.
/// - A copy on the phone is offered when the app becomes active: its text, its image
///   (PNG or JPEG) and its files, which are uploaded to the computer's transfer area so
///   Linux applications can paste them.
///
/// Failures are reported in an alert; nothing is pretended.
@MainActor
final class PasteboardBridge {
    /// The most this bridge downloads for one copy from the computer, and uploads for one
    /// copy on the phone.
    static let downloadLimit: Int64 = 256 * 1024 * 1024
    static let uploadLimit: Int64 = 1024 * 1024 * 1024

    private var changeCount = UIPasteboard.general.changeCount
    private var receiving: Task<Void, Never>?
    private var offering: Task<Void, Never>?
    private var downloads: URL?

    /// Routes the computer's copies to the pasteboard.
    func attach(_ session: any DisplaySession, host: HostClient) {
        session.onClipboard = { [weak self] content in self?.received(content, host: host) }
    }

    // MARK: Computer → phone

    private func received(_ content: ClipboardContent, host: HostClient) {
        receiving?.cancel()
        guard let paths = content.filePaths else {
            write(content, files: [])
            return
        }
        receiving = Task { [weak self] in
            guard let self else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-" + UUID().uuidString, isDirectory: true)
            var files: [URL] = []
            var problems: [String] = []
            var budget = Self.downloadLimit
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { report("Could not copy files from your computer", error.localizedDescription); return }
            for path in paths {
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
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
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
            if let previous = downloads { try? FileManager.default.removeItem(at: previous) }
            downloads = directory
            write(content, files: files)
            if !problems.isEmpty {
                report(files.isEmpty ? "Files were not copied to iPhone" : "Some files were not copied to iPhone",
                       problems.prefix(3).joined(separator: "\n"))
            }
        }
    }

    /// Puts a copy on the pasteboard: one item with its text and image, and one per file.
    private func write(_ content: ClipboardContent, files: [URL]) {
        var providers: [NSItemProvider] = []
        let main = NSItemProvider()
        var hasMain = false
        for (mime, type) in [(ClipboardPolicy.text, UTType.utf8PlainText), (ClipboardPolicy.png, .png), (ClipboardPolicy.jpeg, .jpeg)] {
            guard let data = content.data(mime) else { continue }
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
        offering = Task { [weak self] in
            guard let copy = await Self.read(providers) else { return }
            guard !Task.isCancelled, let self else { return }
            var files: [String] = []
            if !copy.files.isEmpty {
                let transfer = HostClient.newTransferID()
                do {
                    for file in copy.files {
                        try Task.checkCancellation()
                        files.append(try await host.uploadTransfer(id: transfer, name: file.name, file: file.url))
                    }
                } catch {
                    await host.cancelTransfer(id: transfer)
                    if !(error is CancellationError) { report("Files were not copied to your computer", error.localizedDescription) }
                    files = []
                }
                copy.removeTemporaryFiles()
            }
            guard !Task.isCancelled else { return }
            if let content = ClipboardPolicy.content(text: copy.text, images: copy.images, files: files) {
                session.offerClipboard(content)
            }
        }
    }

    /// What was read from the pasteboard: text, an image in the types Linux applications
    /// take, and files copied to a temporary directory for upload.
    private final class Copy: @unchecked Sendable {
        var text: String?
        var images: [ClipboardEntry] = []
        var files: [(name: String, url: URL)] = []
        var directory: URL?
        func removeTemporaryFiles() { if let directory { try? FileManager.default.removeItem(at: directory) } }
    }

    private nonisolated static func read(_ providers: [NSItemProvider]) async -> Copy? {
        let copy = Copy()
        let imageTypes = providers.filter { DropPolicy.representation(for: $0.registeredTypeIdentifiers) == .file(imageType($0) ?? "") }
        var total: Int64 = 0
        for provider in providers {
            let identifiers = provider.registeredTypeIdentifiers
            switch DropPolicy.representation(for: identifiers) {
            case .text where copy.text == nil:
                copy.text = await loadText(provider)
            case .file(let type) where imageType(provider) == type && imageTypes.count == 1 && copy.images.isEmpty:
                // One image is pasted as an image; the same picture is also sent as a file
                // if it is too large for the clipboard.
                let images = await loadImage(provider)
                if images.contains(where: { $0.data.count <= ClipboardPolicy.maxBytes }) {
                    copy.images = images
                } else if let data = images.first?.data, let url = try? stage(data, name: provider.suggestedName ?? "Image", type: type, in: copy) {
                    copy.files.append((url.lastPathComponent, url))
                    total += Int64(data.count)
                }
            case .text, .none:
                continue
            case .fileURL, .file:
                guard copy.files.count < ClipboardPolicy.maxFiles, let url = await loadFile(provider, in: copy) else { continue }
                total += Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
                copy.files.append((url.lastPathComponent, url))
            }
        }
        if total > uploadLimit {
            await MainActor.run { report("Files were not copied to your computer", "Copies of more than 1 GB are not sent. Drag the files instead.") }
            copy.removeTemporaryFiles()
            copy.files = []
        }
        return copy.text == nil && copy.images.isEmpty && copy.files.isEmpty ? nil : copy
    }

    private nonisolated static func imageType(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    private nonisolated static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
        }
    }

    private nonisolated static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// The image as Linux applications take it: PNG or JPEG as copied, else converted to
    /// JPEG (a photo) or PNG (with transparency).
    private nonisolated static func loadImage(_ provider: NSItemProvider) async -> [ClipboardEntry] {
        for (type, mime) in [(UTType.png, ClipboardPolicy.png), (.jpeg, ClipboardPolicy.jpeg)]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(provider, type.identifier) { return [ClipboardEntry(mime: mime, data: data)] }
        }
        guard let type = imageType(provider), let data = await loadData(provider, type), let image = UIImage(data: data) else { return [] }
        let alpha = image.cgImage.map { ![.none, .noneSkipFirst, .noneSkipLast].contains($0.alphaInfo) } ?? false
        if alpha, let png = image.pngData() { return [ClipboardEntry(mime: ClipboardPolicy.png, data: png)] }
        return image.jpegData(compressionQuality: 0.9).map { [ClipboardEntry(mime: ClipboardPolicy.jpeg, data: $0)] } ?? []
    }

    private nonisolated static func directory(for copy: Copy) throws -> URL {
        if let directory = copy.directory { return directory }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        copy.directory = directory
        return directory
    }

    private nonisolated static func stage(_ data: Data, name: String, type: String, in copy: Copy) throws -> URL {
        var name = HostClient.transferName(name)
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension { name += "." + ext }
        let folder = try directory(for: copy).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Copies a file representation out of the provider's temporary location, refusing
    /// anything over the per-file limit.
    private nonisolated static func loadFile(_ provider: NSItemProvider, in copy: Copy) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true || $0 == UTType.fileURL.identifier }),
              let folder = try? directory(for: copy).appendingPathComponent(UUID().uuidString, isDirectory: true),
              (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      Int64(size) <= HostClient.transferFileLimit else { continuation.resume(returning: nil); return }
                let name = HostClient.transferName(provider.suggestedName.map { name in
                    (name as NSString).pathExtension.isEmpty ? name + "." + url.pathExtension : name
                } ?? url.lastPathComponent)
                let destination = folder.appendingPathComponent(name)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: destination)) != nil ? destination : nil)
            }
        }
    }

    // MARK: Reporting

    private static func report(_ title: String, _ message: String) {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = controller.presentedViewController { controller = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }

    private func report(_ title: String, _ message: String) { Self.report(title, message) }
}
