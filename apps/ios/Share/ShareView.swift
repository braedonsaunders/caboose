import SwiftUI
import UniformTypeIdentifiers

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.credentials == nil {
                    ContentUnavailableView("Not Connected", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                           description: Text("Open Caboose and connect to your computer first."))
                } else if model.phase == .loading {
                    ProgressView()
                } else if model.items.isEmpty {
                    ContentUnavailableView("Nothing to Send", systemImage: "tray",
                                           description: Text(model.skipped.isEmpty ? "Caboose can take pages, text, photos and files."
                                                             : "Files over 20 MB are too large to share from here."))
                } else {
                    form
                }
            }
            .navigationTitle("Caboose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
            }
        }
    }

    private var busy: Bool {
        if case .sending = model.phase { true } else { false }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(model.items) { item in row(item) }
                if !model.skipped.isEmpty {
                    Label("Too large to share from here: \(model.skipped.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                if !model.pages.isEmpty {
                    Button("Open on Computer", systemImage: "safari", action: model.openPage)
                }
                if !model.files.isEmpty || !model.texts.isEmpty {
                    Button("Save to Downloads", systemImage: "square.and.arrow.down") { model.save(open: false) }
                    Button("Save and Open", systemImage: "arrow.up.forward.app") { model.save(open: true) }
                }
            }
            .disabled(busy)

            Section {
                TextField("Ask an agent to do something with this…", text: $model.prompt, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .focused($promptFocused)
                Picker("Agent", selection: $model.agent) {
                    Text("Default Agent").tag("")
                    ForEach(model.agents) { Text($0.name).tag($0.id) }
                }
                Button("Ask Agent", systemImage: "sparkle", action: model.askAgent)
                    .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Agent")
            } footer: {
                if model.files.count > ShareModel.maxAttachments {
                    Text("An agent takes the first \(ShareModel.maxAttachments) files.")
                }
            }
            .disabled(busy)

            switch model.phase {
            case .sending(let message):
                Section { Label { Text(message) } icon: { ProgressView() } }
            case .done(let message):
                Section { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            case .failed(let message):
                Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func row(_ item: SharedItem) -> some View {
        switch item {
        case .page(let url):
            Label {
                VStack(alignment: .leading) {
                    Text(url.host() ?? url.absoluteString).font(.subheadline.weight(.semibold))
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: { Image(systemName: "globe") }
        case .text(let text):
            Label { Text(text).lineLimit(3).font(.subheadline) } icon: { Image(systemName: "text.alignleft") }
        case .file(let name, let type, let data):
            Label {
                VStack(alignment: .leading) {
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                if type.conforms(to: .image), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 5))
                } else {
                    Image(systemName: type.conforms(to: .movie) ? "film" : "doc")
                }
            }
        }
    }
}
