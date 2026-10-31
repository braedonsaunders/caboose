import CabooseKit
import SwiftUI

/// A command run on the computer, opened from its `caboose://command/<id>` link, its
/// notification or its Live Activity. It follows a running command until it ends.
struct CommandView: View {
    let id: String
    @State private var command: ComputerCommand?
    @State private var failure: String?
    @State private var actionError: String?
    @State private var working = false
    @State private var saved = false

    /// Showing a whole megabyte in a list row is slow; the rest stays on the host.
    private static let shownCharacters = 65_536

    var body: some View {
        Group {
            if let command {
                content(command)
            } else if let failure {
                ContentUnavailableView("Command unavailable", systemImage: "terminal", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(command?.title ?? "Command")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await follow() }
    }

    private func content(_ command: ComputerCommand) -> some View {
        List {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if command.isRunning { ProgressView() }
                        Text(command.summary)
                    }
                }
                Text(command.script)
                    .font(.footnote.monospaced())
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            if !command.stdout.isEmpty {
                Section(command.truncated.stdout ? "Output (beginning)" : "Output") { stream(command.stdout) }
            }
            if !command.stderr.isEmpty {
                Section(command.truncated.stderr ? "Errors (end)" : "Errors") { stream(command.stderr, tail: true) }
            }
            if !command.outputs.isEmpty {
                Section {
                    ForEach(command.outputs, id: \.self) { Label($0, systemImage: "doc") }
                    if !command.isRunning && !saved {
                        Button("Save Files to Downloads", systemImage: "square.and.arrow.down") { Task { await saveFiles(command) } }
                            .disabled(working)
                    }
                } header: {
                    Text("Files")
                } footer: {
                    Text(saved ? "Saved to Downloads on your computer." : "In \(command.directory)/out on your computer.")
                }
            }
            if command.isRunning {
                Section {
                    Button("Cancel Command", systemImage: "stop.circle", role: .destructive) { Task { await cancel() } }
                        .disabled(working)
                }
            }
            if let actionError {
                Section { Text(actionError).foregroundStyle(.orange) }
            }
        }
    }

    private func stream(_ text: String, tail: Bool = false) -> some View {
        let shown = text.count > Self.shownCharacters ? String(tail ? text.suffix(Self.shownCharacters) : text.prefix(Self.shownCharacters)) : text
        return Text(shown)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
    }

    /// Long-polls while the command runs: the host answers when it ends, or after 25 seconds.
    private func follow() async {
        guard ComputerCommand.isValidID(id) else {
            failure = "This link does not name a command."
            return
        }
        var wait = 0
        while !Task.isCancelled {
            do {
                let next = try await pairedHostClient().command(id, wait: wait)
                command = next
                guard next.isRunning else { return }
                wait = 25
            } catch {
                if command == nil {
                    failure = error.localizedDescription
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func cancel() async {
        working = true
        defer { working = false }
        do {
            command = try await pairedHostClient().cancelCommand(id)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    /// Moves the output files into ~/Downloads (as `name (2).ext` beside an existing file), then
    /// moves the emptied job directory to Trash.
    private func saveFiles(_ command: ComputerCommand) async {
        guard let credentials = Credentials.load() else { actionError = HostClient.Failure.unauthorized.localizedDescription; return }
        working = true
        defer { working = false }
        let fs = HostShortcutFiles(credentials: credentials)
        do {
            try await fs.mkdir("Downloads", allowExisting: true)
            let present = try await fs.list(command.directory + "/out")
            for name in command.outputs {
                guard let entry = present.first(where: { $0.name == name && $0.kind == "file" }), let etag = entry.etag else { continue }
                let ext = (name as NSString).pathExtension
                let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                var number = 1
                while true {
                    let target = "Downloads/" + stem + (number == 1 ? "" : " (\(number))") + (ext.isEmpty ? "" : "." + ext)
                    do {
                        try await fs.move(command.directory + "/out/" + name, to: target, etag: etag)
                        break
                    } catch HostClient.Failure.server(409, _) where number < 1000 {
                        number += 1
                    }
                }
            }
            try? await fs.remove(command.directory)
            saved = true
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }
}
