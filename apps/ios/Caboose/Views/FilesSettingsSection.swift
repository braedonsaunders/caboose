import SwiftUI

/// Registration status is independent of the host's availability and Files' visibility switch.
struct FilesSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.filesRegistering {
                Label { Text("Setting up Files…") } icon: { ProgressView() }
            }
            if let error = model.filesRegistrationError {
                Label("Files setup failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Retry Files Setup") { model.registerFiles() }
                .disabled(model.filesRegistering)
        } header: {
            Text("Files on This Device")
        } footer: {
            Text("In Files, open Browse, then More (…) > Edit. If Caboose is listed and switched off, turn it on. Your computer’s home appears as a location named after the computer. Files setup errors appear here.")
        }
    }
}
