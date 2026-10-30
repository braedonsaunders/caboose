import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// A drop is an explicit user action. Text goes to the chosen window; files use the
/// computer's normal default application after being saved in Downloads.
struct WindowDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat
    var presentedSize: CGSize? = nil
    /// The fitted content rectangle inside its layout viewport, including padding.
    var presentedFrame: CGRect? = nil
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL, .image, .plainText, .data], isTargeted: nil) { providers, point in
                let accepted = providers.compactMap { provider -> (NSItemProvider, DropPolicy.Representation)? in
                    DropPolicy.representation(for: provider.registeredTypeIdentifiers).map { (provider, $0) }
                }
                guard !accepted.isEmpty, let host = model.host else { return false }
                for (provider, representation) in accepted {
                    switch representation {
                    case .text:
                        guard let originalSession = model.session, originalSession.state == .ready,
                              originalSession.windows[window.id] === window else { continue }
                        let remoteSize = window.frame.size
                        let shownSize = presentedSize ?? CGSize(width: remoteSize.width / pixelsPerPoint, height: remoteSize.height / pixelsPerPoint)
                        let mapping = DesktopGeometry.SurfaceMapping(shown: presentedFrame ?? CGRect(origin: .zero, size: shownSize), remote: remoteSize)
                        guard let position = mapping.point(point) else { continue }
                        _ = provider.loadObject(ofClass: NSString.self) { value, failure in
                            Task { @MainActor in
                                guard let text = value as? String else { error = failure?.localizedDescription ?? "Could not read the dropped text."; return }
                                guard let session = model.session, session === originalSession, session.state == .ready,
                                      session.windows[window.id] === window, window.frame.size == remoteSize else { error = "The window is no longer connected."; return }
                                session.focus(window)
                                session.pointerButton(in: window, button: 1, pressed: true, at: position)
                                session.pointerButton(in: window, button: 1, pressed: false, at: position)
                                session.type(text, in: window)
                            }
                        }
                    case .fileURL:
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, failure in
                            let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                            guard let url, url.isFileURL else {
                                Task { @MainActor in error = failure?.localizedDescription ?? "Could not read the dropped file." }
                                return
                            }
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            send(url, name: provider.suggestedName ?? url.lastPathComponent, host: host)
                        }
                    case .file(let type):
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, failure in
                            guard let url else {
                                Task { @MainActor in error = failure?.localizedDescription ?? "Could not read the dropped file." }
                                return
                            }
                            send(url, name: provider.suggestedName ?? url.lastPathComponent, host: host)
                        }
                    }
                }
                return true
            }
            .alert("Drop failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func send(_ url: URL, name: String, host: HostClient) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let count = size.fileSize, count <= DropPolicy.maxFileBytes else {
                throw DropError.invalidFile
            }
            let data = try Data(contentsOf: url)
            guard data.count <= DropPolicy.maxFileBytes else { throw DropError.invalidFile }
            Task { @MainActor in
                do { _ = try await host.sendFile(name: name, data: data, open: true) }
                catch { self.error = error.localizedDescription }
            }
        } catch {
            Task { @MainActor in self.error = error.localizedDescription }
        }
    }

    private enum DropError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "Choose a regular file no larger than 50 MB." }
    }
}
