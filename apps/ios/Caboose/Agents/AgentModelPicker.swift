import SwiftUI

/// Uses the current ACP session's advertisement; no model names are embedded in the app.
struct AgentModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agentID: String
    let taskID: String?
    @State private var state: AgentModelState?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var selected: String? {
        taskID == nil ? model.agents.selectedModels[agentID] ?? state?.models?.currentModelId
            : state?.requestedModel ?? (state?.currentModelKnown == false ? nil : state?.models?.currentModelId)
    }
    private var busy: Bool {
        guard let task = model.agents.tasks.first(where: { $0.id == taskID }) else { return false }
        return task.isRunning || !(task.queued ?? []).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ProgressView("Reading models from the agent…")
                } else if let models = state?.models {
                    Section {
                        ForEach(models.availableModels) { choice in
                            Button {
                                saving = true
                                error = nil
                                Task {
                                    defer { saving = false }
                                    do {
                                        let result = try await model.agents.selectModel(choice.id, agent: agentID, taskID: taskID)
                                        if let result { state = result }
                                        else { dismiss() }
                                    } catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(choice.name).foregroundStyle(.primary)
                                        if let description = choice.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if selected == choice.id { Image(systemName: "checkmark") }
                                }
                            }
                            .disabled(saving || busy)
                        }
                    } footer: {
                        if busy { Text("Model selection is available after the agent and its queued messages finish.") }
                        else if state?.currentModelKnown == false { Text("Your selection applies when this chat resumes for its next message.") }
                        else if taskID != nil { Text("Your selection applies to the next message. Current model: \(models.availableModels.first(where: { $0.id == models.currentModelId })?.name ?? models.currentModelId).") }
                    }
                } else if error == nil {
                    Text(agentID.isEmpty ? "Choose an agent first." : "This agent does not advertise model selection.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Try Again") { Task { await load() } }.disabled(loading || saving)
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: agentID + (taskID ?? "")) { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        guard !agentID.isEmpty else { return }
        do { state = try await model.agents.modelState(agent: agentID, taskID: taskID) }
        catch { self.error = error.localizedDescription }
    }
}
