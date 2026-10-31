import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// Drops from iOS into the Linux application under the finger (docs/display.md, Drag and
/// drop). While the drag hovers over a window, the computer drags the same types over
/// that application, and whether it accepts decides whether iOS offers the drop. When the
/// finger lifts, the files are uploaded to the computer's transfer area first; only then
/// is the computer's drag released, so the application finds the content ready. Failures
/// are shown on the phone.
struct WindowDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat
    var presentedSize: CGSize? = nil
    /// The fitted content rectangle inside its layout viewport, including padding.
    var presentedFrame: CGRect? = nil
    @State private var progress = DropProgress()

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.item], delegate: WindowDropDelegate(model: model, window: window, pixelsPerPoint: pixelsPerPoint, presentedSize: presentedSize, presentedFrame: presentedFrame, progress: progress))
            .overlay {
                if progress.sending {
                    VStack(spacing: 12) {
                        ProgressView("Sending to \(window.title.isEmpty ? "the app" : window.title)…")
                        Button("Cancel", role: .cancel) { progress.task?.cancel() }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert("Drop failed", isPresented: Binding(get: { progress.error != nil }, set: { if !$0 { progress.error = nil } })) {
                Button("OK") { progress.error = nil }
            } message: { Text(progress.error ?? "") }
    }
}

@MainActor @Observable
final class DropProgress {
    /// The types offered for the drag over this window.
    var types: [String] = []
    /// The drop happened; the drag's exit that follows is not a leave.
    var performing = false
    var sending = false
    var error: String?
    var task: Task<Void, Never>?
}

@MainActor
struct WindowDropDelegate: DropDelegate {
    let model: AppModel
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat
    let presentedSize: CGSize?
    let presentedFrame: CGRect?
    let progress: DropProgress

    private var session: (any DisplaySession)? { model.session }

    /// The drag's position in the window's pixels. Entering cannot start on letterboxing;
    /// a drag already over the window clamps to its edge.
    private func point(_ info: DropInfo, captured: Bool) -> CGPoint? {
        let remote = window.frame.size
        let shownSize = presentedSize ?? CGSize(width: remote.width / pixelsPerPoint, height: remote.height / pixelsPerPoint)
        let mapping = DesktopGeometry.SurfaceMapping(shown: presentedFrame ?? CGRect(origin: .zero, size: shownSize), remote: remote)
        return mapping.point(info.location, captured: captured)
    }

    private func types(_ info: DropInfo) -> [String] {
        DropPolicy.dropTypes(for: info.itemProviders(for: [.item]).map(\.registeredTypeIdentifiers))
    }

    func validateDrop(info: DropInfo) -> Bool {
        !progress.sending && session != nil && point(info, captured: false) != nil && !types(info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        progress.types = types(info)
        progress.performing = false
        guard let at = point(info, captured: false) else { return }
        session?.dropEnter(window, at: at, types: progress.types)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let at = point(info, captured: true) { session?.dropMove(window, at: at) }
        // Until the application has answered, the drop is offered; once it refuses, not.
        return DropProposal(operation: session?.dropAccepted == false ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        if !progress.performing { session?.dropLeave() }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let session, let host = model.host else { return false }
        let providers = info.itemProviders(for: [.item])
        let types = progress.types
        progress.performing = true
        progress.sending = true
        let progress = progress
        progress.task = Task {
            defer { progress.sending = false }
            do {
                let items = try await StagedItems.read(providers, imageAsFile: true)
                defer { items.removeTemporaryFiles() }
                let files = try await items.upload(to: host)
                try Task.checkCancellation()
                // Only what the drop announced: the computer offered the application these.
                let all = ClipboardPolicy.content(text: items.text, images: items.images, files: files)
                guard let content = all.flatMap({ ClipboardContent($0.entries.filter { types.contains($0.mime) }) }) else {
                    session.dropLeave()
                    progress.error = "Nothing in the drop could be sent."
                    return
                }
                session.dropPerform(content)
            } catch is CancellationError {
                session.dropLeave()
            } catch {
                session.dropLeave()
                progress.error = error.localizedDescription
            }
        }
        return true
    }
}
