import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

/// The share sheet's Caboose entry: send a page, text, photos or files to the computer —
/// open them there, save them in Downloads, or hand them to an agent.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in
            self?.model.removeTemporaryFiles()
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.cancel = { [weak self] in
            self?.model.removeTemporaryFiles()
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model).preferredColorScheme(.dark))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }
}

/// One thing shared with Caboose.
enum SharedItem: Identifiable {
    case page(URL)
    case text(String)
    case file(name: String, type: UTType, url: URL)

    var id: String {
        switch self {
        case .page(let url): "page:\(url.absoluteString)"
        case .text(let text): "text:\(text.hashValue)"
        case .file(let name, _, let url): "file:\(name):\(url.absoluteString)"
        }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading, ready, sending(String), done(String), failed(String)
    }

    /// What an agent task takes with it (the host's limit).
    static let maxAttachments = 4
    static let maxAttachmentBytes = 10 * 1024 * 1024

    var items: [SharedItem] = []
    var phase = Phase.loading
    var prompt = ""
    /// A registry id, or "" for the computer's default agent.
    var agent = ""
    /// The agents installed in the computer, for the picker.
    var agents: [AgentListing] = []
    let credentials = Credentials.load()
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    var pages: [URL] { items.compactMap { if case .page(let url) = $0 { url } else { nil } } }
    var texts: [String] { items.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var files: [(name: String, type: UTType, url: URL)] {
        items.compactMap { if case .file(let name, let type, let url) = $0 { (name, type, url) } else { nil } }
    }

    func removeTemporaryFiles() {
        for file in files { try? FileManager.default.removeItem(at: file.url) }
    }

    func load(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if let item = await Self.item(from: provider) {
                items.append(item)
            }
        }
        phase = .ready
        if let host = try? await host(), let listed = try? await host.agents() {
            agents = listed.agents.filter(\.isInstalled)
        }
    }

    private static func item(from provider: NSItemProvider) async -> SharedItem? {
        // A web page arrives as a URL; a file from Files may too, as a file URL.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
            return .page(url)
        }
        // Text from an app is a string; a text file from Files loads as a URL instead.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
            return .text(text)
        }
        let fileTypes: [UTType] = [.image, .movie, .pdf, .data, .item]
        if let type = fileTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            let concrete = provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: type) } ?? type
            if let (name, url) = await file(from: provider, type: concrete) {
                return .file(name: name, type: concrete, url: url)
            }
        }
        return nil
    }

    private static func file(from provider: NSItemProvider, type: UTType) async -> (String, URL)? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.copyItem(at: url, to: local) }
                catch { continuation.resume(returning: nil); return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext.lowercased())") { name += ".\(ext)" }
                continuation.resume(returning: (name, local))
            }
        }
    }

    // MARK: Actions

    private func host() async throws -> HostClient {
        guard let credentials else { throw HostClient.Failure.unauthorized }
        return HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
    }

    func openPage() { run("Opening on your computer…", done: "Opened on your computer.") { host in
        for url in self.pages { try await host.open(url) }
    } }

    func save(open: Bool) { run("Sending to Downloads…", done: open ? "Saved in Downloads and opened." : "Saved in Downloads.") { host in
        for file in self.files { _ = try await host.sendFile(name: file.name, file: file.url, open: open) }
        if !self.texts.isEmpty {
            _ = try await host.sendFile(name: "Shared text.txt", data: Data(self.texts.joined(separator: "\n\n").utf8), open: open)
        }
    } }

    func askAgent() {
        var request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in pages { request += "\n\nPage: \(url.absoluteString)" }
        for text in texts { request += "\n\nShared text:\n\(text)" }
        let attachments = Self.attachments(for: files)
        run("Handing it to the agent…", done: "The agent is on it. Follow it in Caboose.") { host in
            _ = try await host.startAgentTask(prompt: request, agent: self.agent.isEmpty ? nil : self.agent, attachments: attachments)
        }
    }

    /// Files for an agent, within the host's limits: photos are scaled down, which is all
    /// a model can see anyway, and what does not fit is left out.
    static func attachments(for files: [(name: String, type: UTType, url: URL)]) -> [AgentAttachment] {
        var result: [AgentAttachment] = [], total = 0
        for file in files.prefix(maxAttachments) {
            let attachment: AgentAttachment
            if file.type.conforms(to: .image), let data = scaled(file.url) {
                attachment = AgentAttachment(name: (file.name as NSString).deletingPathExtension + ".jpg", type: "image/jpeg", data: data)
            } else {
                guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= maxAttachmentBytes, let data = try? Data(contentsOf: file.url) else { continue }
                attachment = AgentAttachment(name: file.name, type: file.type.preferredMIMEType ?? "application/octet-stream", data: data)
            }
            guard total + attachment.data.count <= maxAttachmentBytes else { continue }
            total += attachment.data.count
            result.append(attachment)
        }
        return result
    }

    private static func scaled(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }

    private func run(_ progress: String, done: String, _ work: @escaping (HostClient) async throws -> Void) {
        phase = .sending(progress)
        Task {
            do {
                try await work(try await host())
                phase = .done(done)
                try? await Task.sleep(for: .seconds(1.2))
                finish()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
