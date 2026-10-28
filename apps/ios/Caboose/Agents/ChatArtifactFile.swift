import CabooseKit
import ImageIO
import QuickLook
import SwiftUI

/// Owns only the phone's downloaded snapshot, never the guest file.
final class ChatArtifactFile: Identifiable {
    let id = UUID()
    let url: URL
    init(data: Data, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-artifact-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func thumbnail() -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private final class ArtifactRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension HostClient {
    /// A hard streaming cap applies even if a server ignores Range or lies about its length.
    func chatArtifact(_ destination: String) async throws -> ChatArtifactFile {
        guard let path = ChatArtifactPolicy.guestPath(destination) else {
            throw Failure.unreachable("This link is not a file inside your computer home.")
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/content"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=0-\(ChatArtifactPolicy.maximumFileBytes)", forHTTPHeaderField: "Range")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: ArtifactRedirectPolicy())
        guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
            throw Failure.unreachable("The computer could not download this file (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let limit = ChatArtifactPolicy.maximumFileBytes
        guard response.expectedContentLength <= limit else {
            throw Failure.unreachable("Chat previews support files up to 25 MB. Open this file in Files instead.")
        }
        var completeLength = response.expectedContentLength
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes 0-"),
                  let total = range.split(separator: "/").last.flatMap({ Int($0) }), total <= limit,
                  range == "bytes 0-\(total - 1)/\(total)" else {
                throw Failure.unreachable("This file is too large or the computer returned an incomplete download.")
            }
            completeLength = Int64(total)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.unreachable("Chat previews support files up to 25 MB. Open this file in Files instead.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        if completeLength >= 0, data.count != completeLength {
            throw Failure.unreachable("The file download was interrupted. Try again.")
        }
        if (path as NSString).pathExtension.lowercased() == "pdf",
           !data.prefix(1024).containsPDFHeader {
            throw Failure.unreachable("The downloaded file is not a PDF. Ask the agent to regenerate it.")
        }
        return try ChatArtifactFile(data: data, name: (path as NSString).lastPathComponent)
    }
}

struct ChatFilePreview: View {
    let file: ChatArtifactFile
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if ChatArtifactPolicy.canQuickLook(file.url.lastPathComponent) { ChatQuickLook(file: file) }
                else { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("Use Share to save or open this file in another app.")) }
            }
                .navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") } }
                }
        }
    }
}

private struct ChatQuickLook: UIViewControllerRepresentable {
    let file: ChatArtifactFile
    func makeCoordinator() -> Coordinator { Coordinator(file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: ChatArtifactFile
        init(_ file: ChatArtifactFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file.url as NSURL }
    }
}

struct ChatArtifactImage: View {
    @Environment(AppModel.self) private var model
    let alt: String
    let destination: String
    @State private var file: ChatArtifactFile?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = false
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Button { preview = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                }.buttonStyle(.plain).accessibilityLabel(alt.isEmpty ? "Preview generated image" : alt)
            }
            HStack {
                Label(alt.isEmpty ? "Generated image" : alt, systemImage: "photo").font(.caption).lineLimit(2)
                Spacer()
                if loading { ProgressView().accessibilityLabel("Loading image") }
                else if file != nil { Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { preview = true }.labelStyle(.iconOnly) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
        }
        .padding(12).background(.thinMaterial, in: .rect(cornerRadius: 16))
        .task(id: destination) { await load() }
        .sheet(isPresented: $preview) { if let file { ChatFilePreview(file: file) } }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let host = model.host else { throw HostClient.Failure.unauthorized }
            guard let path = ChatArtifactPolicy.guestPath(destination), ChatArtifactPolicy.isImage(path) else {
                throw HostClient.Failure.unreachable("This image is not a supported file inside your computer home.")
            }
            let downloaded = try await host.chatArtifact(destination)
            guard let thumbnail = downloaded.thumbnail() else { throw HostClient.Failure.unreachable("This file could not be decoded as an image.") }
            try Task.checkCancellation()
            file = downloaded; image = thumbnail
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private extension Data {
    var containsPDFHeader: Bool { range(of: Data("%PDF-".utf8)) != nil }
}
