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
    @State private var progress = DropProgress()

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.item], delegate: WindowDropDelegate(model: model, window: window, pixelsPerPoint: pixelsPerPoint, progress: progress))
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
    let progress: DropProgress

    private var session: (any DisplaySession)? { model.session }

    private func point(_ info: DropInfo) -> CGPoint {
        CGPoint(x: info.location.x * pixelsPerPoint, y: info.location.y * pixelsPerPoint)
    }

    private func types(_ info: DropInfo) -> [String] {
        DropPolicy.dropTypes(for: info.itemProviders(for: [.item]).map(\.registeredTypeIdentifiers))
    }

    func validateDrop(info: DropInfo) -> Bool {
        !progress.sending && session != nil && !types(info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        progress.types = types(info)
        progress.performing = false
        session?.dropEnter(window, at: point(info), types: progress.types)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        session?.dropMove(window, at: point(info))
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
