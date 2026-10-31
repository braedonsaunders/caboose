import CabooseKit
import UIKit
import UniformTypeIdentifiers

/// Items from iOS (a paste, a drop) read into what the computer takes: text, one image as
/// PNG or JPEG, and files copied to a private temporary directory, then uploaded to the
/// computer's transfer area.
final class StagedItems: @unchecked Sendable {
    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? { "More than 1 GB is not sent at once. Send fewer or smaller files." }
    }

    /// The most one paste or drop uploads.
    static let uploadLimit: Int64 = 1024 * 1024 * 1024

    var text: String?
    var images: [ClipboardEntry] = []
    var files: [(name: String, url: URL)] = []
    private var directory: URL?
    private var bytes: Int64 = 0

    func removeTemporaryFiles() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    var isEmpty: Bool { text == nil && images.isEmpty && files.isEmpty }

    /// Reads `providers`. A single image becomes the image representation and, when
    /// `imageAsFile` (a drop) or when it is too large for the clipboard, a file as well;
    /// several images are files.
    static func read(_ providers: [NSItemProvider], imageAsFile: Bool) async throws -> StagedItems {
        let items = StagedItems()
        let imageCount = providers.filter { imageItem($0) != nil }.count
        do {
            for provider in providers {
                try Task.checkCancellation()
                switch DropPolicy.representation(for: provider.registeredTypeIdentifiers) {
                case .text where items.text == nil:
                    items.text = await loadText(provider)
                case .file(let type) where imageItem(provider) == type && imageCount == 1:
                    let original = await loadData(provider, type)
                    let image = await convert(provider, original: original, type: type)
                    if let image, image.data.count <= ClipboardPolicy.maxBytes { items.images = [image] }
                    if let original, imageAsFile || items.images.isEmpty {
                        try items.add(try items.stage(original, name: provider.suggestedName ?? "Image", type: type))
                    }
                case .text, .none:
                    continue
                case .fileURL, .file:
                    guard items.files.count < ClipboardPolicy.maxFiles, let url = await items.loadFile(provider) else { continue }
                    try items.add(url)
                }
            }
        } catch {
            items.removeTemporaryFiles()
            throw error
        }
        return items
    }

    private func add(_ url: URL) throws {
        bytes += Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard bytes <= Self.uploadLimit else { throw Failure.tooLarge }
        files.append((url.lastPathComponent, url))
    }

    /// Uploads the files to one new transfer and returns their paths on the computer; on
    /// failure or cancellation the transfer is removed.
    func upload(to host: HostClient) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let transfer = HostClient.newTransferID()
        var paths: [String] = []
        do {
            for file in files {
                try Task.checkCancellation()
                paths.append(try await host.uploadTransfer(id: transfer, name: file.name, file: file.url))
            }
            return paths
        } catch {
            await host.cancelTransfer(id: transfer)
            throw error
        }
    }

    // MARK: Loading

    private static func imageItem(_ provider: NSItemProvider) -> String? {
        let identifiers = provider.registeredTypeIdentifiers
        guard case .file(let type) = DropPolicy.representation(for: identifiers), UTType(type)?.conforms(to: .image) == true else { return nil }
        return type
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    /// The image as Linux applications take it, as `DropPolicy.dropTypes` announces it:
    /// a PNG as it is, anything else as JPEG.
    private static func convert(_ provider: NSItemProvider, original: Data?, type: String) async -> ClipboardEntry? {
        if UTType(type)?.conforms(to: .png) == true, let original { return ClipboardEntry(mime: ClipboardPolicy.png, data: original) }
        if UTType(type)?.conforms(to: .jpeg) == true, let original { return ClipboardEntry(mime: ClipboardPolicy.jpeg, data: original) }
        guard let original, let image = UIImage(data: original), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ClipboardEntry(mime: ClipboardPolicy.jpeg, data: jpeg)
    }

    private func folder() throws -> URL {
        if directory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("staged-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
        }
        let folder = directory!.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func stage(_ data: Data, name: String, type: String) throws -> URL {
        var name = HostClient.transferName(name)
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension { name += "." + ext }
        let url = try folder().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Copies a file representation out of the provider's temporary location, refusing
    /// anything over the per-file limit.
    private func loadFile(_ provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true || $0 == UTType.fileURL.identifier }),
              let folder = try? folder() else { return nil }
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
}
