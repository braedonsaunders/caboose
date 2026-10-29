import CabooseKit
import SwiftUI

/// Describe an app and an agent makes it: Create starts a chat with the default agent, which
/// builds a Caboose app that appears in Apps, and opens that chat in Agents.
struct NewAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var focused = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let request = AppRequest(description)
        NavigationStack {
            Form {
                Section {
                    NativeTextInput("A tracker for my runs, with a weekly chart and a goal I can set",
                                    text: $description, focus: $focused, lines: 4...12)
                } header: {
                    Text("Describe Your App")
                } footer: {
                    Text("An agent builds it on your computer and adds it to Apps. Say what it shows, what it does and how it should feel.")
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle("New App")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create(request) }.disabled(!request.isValid || busy)
                }
            }
            .overlay { if busy { ProgressView() } }
        }
    }

    private func create(_ request: AppRequest) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            let agents = model.agents
            guard let id = await agents.start(request.prompt, agent: nil) else {
                error = agents.lastError ?? "The agent could not start."
                agents.lastError = nil
                return
            }
            agents.focusedTask = id
            model.selectedTab = .agents
            dismiss()
        }
    }
}
