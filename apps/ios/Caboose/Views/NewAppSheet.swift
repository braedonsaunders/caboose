import CabooseKit
import SwiftUI

/// Describe an app and an agent makes it: Create starts a chat with the default agent, which
/// builds a Caboose app that appears in Apps, and opens that chat in Agents.
struct NewAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var focused = true
    /// The Create in flight. Clearing it (the sheet closing) makes its result change nothing
    /// here; a chat the host already admitted keeps running and is listed in Agents.
    @State private var operation: UUID?
    @State private var error: String?

    var body: some View {
        let request = AppRequest(description)
        let busy = operation != nil
        NavigationStack {
            Form {
                Section {
                    NativeTextInput("A tracker for my runs, with a weekly chart and a goal I can set",
                                    text: $description, focus: $focused, lines: 4...12)
                } header: {
                    Text("Describe Your App")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("An agent builds it on your computer and adds it to Apps. Say what it shows, what it does and how it should feel.")
                        if request.description.count > AppRequest.maxLength * 9 / 10 {
                            Text("\(request.description.count) of \(AppRequest.maxLength) characters")
                                .foregroundStyle(request.isValid ? Color.secondary : Color.orange)
                                .monospacedDigit()
                        }
                    }
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
            .onDisappear { operation = nil }
        }
    }

    private func create(_ request: AppRequest) {
        let token = UUID()
        operation = token; error = nil
        let agents = model.agents
        Task {
            let id = await agents.start(request.prompt, agent: nil)
            // Only this sheet's latest Create, on the computer it was made for, changes the UI.
            guard operation == token, model.agents === agents else { return }
            operation = nil
            guard let id else {
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
