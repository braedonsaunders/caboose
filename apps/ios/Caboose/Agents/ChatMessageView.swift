import CabooseKit
import SwiftUI

/// Readable native blocks with selectable text and independently scrollable code.
struct ChatMessageView: View {
    let text: String
    @Environment(AppModel.self) private var model
    @State private var artifact: ChatArtifactFile?
    @State private var artifactError: String?
    @State private var downloading = false
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Markdown.inline(text)).lineSpacing(4).textSelection(.enabled)
                case .heading(let level, let text):
                    Text(Markdown.inline(text))
                        .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                        .accessibilityAddTraits(.isHeader).textSelection(.enabled)
                case .code(let language, let code):
                    CodeMessage(language: language, code: code)
                case .html(let html):
                    ChatHTMLArtifact(html: html)
                case .image(let alt, let destination):
                    ChatArtifactImage(alt: alt, destination: destination)
                case .quote(let text):
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(Brand.amber.opacity(0.7)).frame(width: 3)
                        Text(Markdown.inline(text)).foregroundStyle(.secondary).textSelection(.enabled)
                    }.fixedSize(horizontal: false, vertical: true)
                case .list(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(marker).foregroundStyle(Brand.amber).frame(minWidth: 16, alignment: .trailing)
                        Text(Markdown.inline(text)).textSelection(.enabled)
                    }
                case .divider:
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Brand.amber)
        .environment(\.openURL, OpenURLAction { url in
            if ChatArtifactPolicy.guestPath(url.absoluteString) != nil {
                openArtifact(url.absoluteString)
                return .handled
            }
            if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
            artifactError = "This link is not a supported web address or a file inside your computer home."
            return .handled
        })
        .overlay(alignment: .bottomTrailing) {
            if downloading { ProgressView("Downloading file…").font(.caption).padding(12).background(.regularMaterial, in: .capsule).accessibilityAddTraits(.updatesFrequently) }
        }
        .sheet(item: $artifact) { ChatFilePreview(file: $0) }
        .alert("Could not open file", isPresented: Binding(get: { artifactError != nil }, set: { if !$0 { artifactError = nil } })) {
            Button("OK", role: .cancel) { artifactError = nil }
        } message: { Text(artifactError ?? "") }
        .onDisappear { downloadTask?.cancel(); downloadTask = nil }
    }
    private func openArtifact(_ destination: String) {
        guard !downloading else { return }
        downloading = true
        downloadTask = Task { @MainActor in
            defer { downloading = false }
            do {
                guard let host = model.host else { throw HostClient.Failure.unauthorized }
                let file = try await host.chatArtifact(destination)
                try Task.checkCancellation()
                artifact = file
            } catch is CancellationError { }
            catch { if !Task.isCancelled { artifactError = error.localizedDescription } }
        }
    }
}

private struct CodeMessage: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
            }.padding(12)
            Divider().opacity(0.3)
            ScrollView(.horizontal) {
                Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(14)
            }
        }
        .background(.black.opacity(0.22), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
        .onChange(of: code) { _, _ in copied = false }
    }
}

/// The shared agent seat, paced by its own session. It never takes input or resizes a window.
struct AgentSeatPreview: UIViewRepresentable {
    let seat: CabooseDisplaySession
    let window: RemoteWindow

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: nil, window: window)
        view.isInteractive = false
        view.pacer = seat
        view.showsVideo = false
        view.pixelsPerPoint = max(1, window.frame.width / 320)
        return view
    }
    func updateUIView(_ view: RemoteWindowView, context: Context) {
        if view.remoteWindow?.id != window.id { view.attach(window) }
        view.pacer = seat
        view.pixelsPerPoint = max(1, window.frame.width / 320)
    }
}

struct AgentSeatCard: View {
    @Environment(AppModel.self) private var model
    let seat: CabooseDisplaySession
    let window: RemoteWindow

    var body: some View {
        Button { model.presentAgentWindow(window.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Agent computer", systemImage: "desktopcomputer").font(.caption.weight(.semibold))
                    Spacer()
                    Label("Watch", systemImage: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.amber)
                }
                AgentSeatPreview(seat: seat, window: window)
                    .frame(height: 168).clipped().clipShape(.rect(cornerRadius: 10))
                    .allowsHitTesting(false).accessibilityHidden(true)
                Text(window.title.isEmpty ? "Shared agent seat" : window.title)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.amber.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch agent computer: \(window.title)")
    }
}
