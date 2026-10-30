import CabooseKit
import SwiftUI
import UniformTypeIdentifiers

/// What the phone took from a drag on the computer (docs/display.md, Drag and drop).
///
/// iOS has no way to hand a drag in progress to another app, so a Linux drag cannot land
/// straight in Photos or Files. Instead, released on the phone's own target it lands here,
/// as native items: drag them on into any app, share them, or copy them.
@MainActor @Observable
final class DragShelf {
    struct Item {
        var content: ClipboardContent?
        var files: [URL]
        var directory: URL?
        var problems: [String]
    }

    private(set) var item: Item?
    private(set) var loading = false
    private var task: Task<Void, Never>?

    func receive(_ content: ClipboardContent, host: HostClient) {
        clear()
        guard let paths = content.filePaths else {
            item = Item(content: content, files: [], directory: nil, problems: [])
            return
        }
        loading = true
        task = Task { [weak self] in
            let fetched = await PasteboardBridge.fetch(paths, host: host)
            guard let self, !Task.isCancelled else {
                if let directory = fetched.directory { try? FileManager.default.removeItem(at: directory) }
                return
            }
            loading = false
            item = Item(content: content, files: fetched.files, directory: fetched.directory, problems: fetched.problems)
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        loading = false
        if let directory = item?.directory { try? FileManager.default.removeItem(at: directory) }
        item = nil
    }

    /// The text and image as one item, and each file as its own.
    var providers: [NSItemProvider] {
        guard let item else { return [] }
        let main = item.content.flatMap { content in
            ClipboardContent(content.entries.filter { $0.mime != ClipboardPolicy.uriList })
        }
        return PasteboardBridge.providers(main, files: item.files)
    }

    /// The items for the share sheet: the text, the image and the files.
    var shareItems: [Any] {
        guard let item else { return [] }
        var items: [Any] = []
        if let image = (item.content?.data(ClipboardPolicy.png) ?? item.content?.data(ClipboardPolicy.jpeg)).flatMap(UIImage.init(data:)) {
            items.append(image)
        } else if let text = item.content?.text, item.files.isEmpty {
            items.append(text)
        }
        return items + item.files
    }

    func copy() {
        let providers = providers
        guard !providers.isEmpty else { return }
        UIPasteboard.general.setItemProviders(providers, localOnly: false, expirationDate: nil)
    }
}

/// The phone's drop target while an application on the computer drags something: lift
/// the finger over it to bring the drag to the phone.
struct DragOutTarget: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session, let types = session.computerDrag {
            let hovering = session.dragOutHovering
            Label(Self.title(types), systemImage: "iphone.and.arrow.forward")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thickMaterial), in: Capsule())
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.snappy, value: hovering)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { session.dragOutFrame = proxy.frame(in: .global).insetBy(dx: -24, dy: -24) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in session.dragOutFrame = frame.insetBy(dx: -24, dy: -24) }
                })
                .onDisappear { session.dragOutFrame = nil }
                .padding(.bottom, 32)
                .accessibilityLabel("Drop here to bring the dragged item to iPhone")
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    static func title(_ types: [String]) -> String {
        if types.contains(ClipboardPolicy.uriList) { return "Drop here to bring the files to iPhone" }
        if types.contains(ClipboardPolicy.png) || types.contains(ClipboardPolicy.jpeg) { return "Drop here to bring the image to iPhone" }
        return "Drop here to bring the text to iPhone"
    }
}

/// What was taken from a computer drag, as native items to drag on, share or copy.
struct DragShelfView: View {
    @Environment(AppModel.self) private var model
    @State private var sharing = false

    var body: some View {
        let shelf = model.pasteboard.shelf
        if shelf.loading || shelf.item != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("From your computer").font(.headline)
                    Spacer()
                    Button("Done") { shelf.clear() }
                }
                if shelf.loading {
                    ProgressView("Copying files…")
                } else if let item = shelf.item {
                    if let content = item.content {
                        if let image = (content.data(ClipboardPolicy.png) ?? content.data(ClipboardPolicy.jpeg)).flatMap(UIImage.init(data:)) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                .onDrag { shelf.providers.first ?? NSItemProvider() }
                        } else if let text = content.text {
                            Text(text).lineLimit(4).font(.body.monospaced())
                                .onDrag { shelf.providers.first ?? NSItemProvider() }
                        }
                    }
                    ForEach(item.files, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: "doc")
                            .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                    }
                    ForEach(item.problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { shelf.copy() }
                        Button("Share", systemImage: "square.and.arrow.up") { sharing = true }
                    }
                    .buttonStyle(.bordered)
                    Text("Drag an item into another app, or share or copy it. iOS can't pass a drag from your computer straight into another app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding()
            .sheet(isPresented: $sharing) { ShareSheet(items: shelf.shareItems) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
