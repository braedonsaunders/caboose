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
    case file(name: String, type: UTType, url: URL, bookmark: Data?, directPath: String?)

    var id: String {
        switch self {
        case .page(let url): "page:\(url.absoluteString)"
        case .text(let text): "text:\(text.hashValue)"
        case .file(let name, _, let url, _, _): "file:\(name):\(url.absoluteString)"
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
    struct CatalogEntry: Decodable, Identifiable {
        struct FileTypes: Decodable { let extensions: [String]; let utTypes: [String] }
        struct Source: Decodable { let size: Int? }
        struct Progress: Decodable { let phase: String; let value: Double?; let message: String? }
        let id: String; let name: String; let desktopId: String; let fileTypes: FileTypes
        let source: Source; let installedVersion: String?; let lastError: String?; let progress: Progress?
    }
    struct Catalog: Decodable { let apps: [CatalogEntry] }
    var catalog: [CatalogEntry] = []
    var selectingApp = false
    var installing: String?
    let credentials = Credentials.load()
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    var pages: [URL] { items.compactMap { if case .page(let url) = $0 { url } else { nil } } }
    var texts: [String] { items.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    var files: [(name: String, type: UTType, url: URL, bookmark: Data?, directPath: String?)] {
        items.compactMap { if case .file(let name, let type, let url, let bookmark, let directPath) = $0 { (name, type, url, bookmark, directPath) } else { nil } }
    }
    var canWriteBack: Bool { files.allSatisfy { $0.bookmark != nil || $0.directPath != nil } }
    var compatibleApps: [CatalogEntry] {
        catalog.filter { app in files.allSatisfy { file in
            app.fileTypes.extensions.contains { $0.caseInsensitiveCompare((file.name as NSString).pathExtension) == .orderedSame } || app.fileTypes.utTypes.contains(file.type.identifier)
        } }
    }

    func removeTemporaryFiles() {
        for file in files { try? FileManager.default.removeItem(at: file.url) }
    }

    func load(_ providers: [NSItemProvider]) async {
        for provider in providers {
            do { if let item = try await Self.item(from: provider) { items.append(item) } }
            catch { phase = .failed(error.localizedDescription); return }
        }
        phase = .ready
        if let host = try? await host(), let listed = try? await host.agents() {
            agents = listed.agents.filter(\.isInstalled)
        }
        await refreshCatalog()
    }

    private static func item(from provider: NSItemProvider) async throws -> SharedItem? {
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
            if let (name, url, bookmark, source) = await file(from: provider, type: concrete) {
                let directPath: String?
                if let source, let credentials = Credentials.load() {
                    do { directPath = try await OpenDocumentStore.directPath(source, domain: credentials.fileDomainIdentifier) }
                    catch { try? FileManager.default.removeItem(at: url); throw error }
                }
                else { directPath = nil }
                return .file(name: name, type: concrete, url: url, bookmark: bookmark, directPath: directPath)
            }
        }
        return nil
    }

    private static func file(from provider: NSItemProvider, type: UTType) async -> (String, URL, Data?, URL?)? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { url, inPlace, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                var coordinationError: NSError?, operationError: Error?, bookmark: Data?
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                    do {
                        try FileManager.default.copyItem(at: coordinated, to: local)
                        if inPlace { bookmark = try? coordinated.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                    } catch { operationError = error }
                }
                guard coordinationError == nil, operationError == nil else { try? FileManager.default.removeItem(at: local); continuation.resume(returning: nil); return }
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                if !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext.lowercased())") { name += ".\(ext)" }
                continuation.resume(returning: (name, local, bookmark, inPlace ? url : nil))
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

    func refreshCatalog(wake: Bool = false) async {
        do {
            let client = try await host()
            if wake { _ = try await client.wake() }
            let response: Catalog = try await client.request("GET", "/v1/catalog", timeout: 60)
            catalog = response.apps
        }
        catch { phase = .failed(error.localizedDescription) }
    }

    func openOnComputer(_ app: CatalogEntry) {
        run("Opening on your computer…", done: "Opened. Return to Caboose to see the window.") { host in
            _ = try await host.wake()
            let fresh: Catalog = try await host.request("GET", "/v1/catalog", timeout: 60)
            self.catalog = fresh.apps
            var chosen = fresh.apps.first(where: { $0.id == app.id }) ?? app
            if chosen.installedVersion == nil {
                self.installing = app.id
                defer { self.installing = nil }
                let _: [String: Bool] = try await host.request("POST", "/v1/catalog/\(app.id)/install", timeout: 30)
                var installed = false
                for _ in 0..<1800 {
                    let response: Catalog = try await host.request("GET", "/v1/catalog", timeout: 60)
                    self.catalog = response.apps
                    if let state = response.apps.first(where: { $0.id == app.id }) {
                        if state.installedVersion != nil { chosen = state; installed = true; break }
                        if state.progress?.phase == "failed" { throw HostClient.Failure.unreachable(state.progress?.message ?? "Installation failed.") }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                if !installed { throw HostClient.Failure.unreachable("Installation is still running. Open Caboose to check its progress.") }
            }
            guard let credentials = self.credentials else { throw HostClient.Failure.unauthorized }
            for file in self.files {
                let path: String
                if let direct = file.directPath { path = direct }
                else if let bookmark = file.bookmark, let existing = try OpenDocumentStore.existing(bookmark: bookmark, domain: credentials.fileDomainIdentifier) { path = existing.path }
                else {
                    let id = UUID().uuidString, folder = "Caboose Documents/" + UUID().uuidString
                    let clean = (file.name as NSString).lastPathComponent
                    guard !clean.isEmpty, clean != ".", clean != ".." else { throw HostClient.Failure.unreachable("The document has no usable name.") }
                    path = folder + "/" + clean
                    try await host.openDocumentMkdir("Caboose Documents", allowExisting: true)
                    try await host.openDocumentMkdir(folder)
                    let hash = try CoordinatedDocument.hash(file.url)
                    let uploaded = try await host.openDocumentUpload(file.url, path: path)
                    if let bookmark = file.bookmark {
                        try OpenDocumentStore.save(OpenDocumentRecord(id: id, domain: credentials.fileDomainIdentifier, name: clean, path: path, bookmark: bookmark, localHash: hash, remoteETag: uploaded.etag))
                    }
                }
                try await host.openDocumentLaunch(path, desktopID: chosen.desktopId)
            }
            let shared = UserDefaults(suiteName: OpenDocumentStore.group)
            shared?.set(credentials.fileDomainIdentifier, forKey: "document-open-domain")
            shared?.set(chosen.desktopId, forKey: "document-open-desktop-id")
        }
    }

    func askAgent() {
        var request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in pages { request += "\n\nPage: \(url.absoluteString)" }
        for text in texts { request += "\n\nShared text:\n\(text)" }
        let attachments = Self.attachments(for: files.map { ($0.name, $0.type, $0.url) })
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
