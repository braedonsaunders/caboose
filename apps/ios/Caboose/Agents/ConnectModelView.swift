import CabooseKit
import SwiftUI

/// Connect a model with an API key instead of an account: OpenRouter (any model), Anthropic or
/// OpenAI. The key goes into the environment of the registry agent that runs the provider, in
/// the computer; that agent becomes the default.
struct ConnectModelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ModelProvider = .openRouter
    @State private var key = ""
    @State private var modelID: String?
    @State private var models: [OpenRouterModel] = []
    @State private var modelsError: String?
    @State private var step: String?
    @State private var error: String?
    @State private var connected = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(ModelProvider.all) { provider in
                            VStack(alignment: .leading) {
                                Text(provider.name)
                                Text(provider.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(provider)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Runs \(agentName(provider)) on your computer with your key. Signing in to an account works too: Agents… in the composer's menu.")
                }
                Section {
                    NativeTextInput("\(provider.keyVariable)", text: $key, secure: true, capitalization: .none, correction: false, monospaced: true)
                    Link(destination: provider.keyURL) { Label("Get a Key from \(provider.name.replacingOccurrences(of: " API", with: ""))", systemImage: "arrow.up.right.square") }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Kept in your computer for this agent only, and never shown again.")
                }
                if provider.modelVariable != nil {
                    Section {
                        if models.isEmpty, modelsError == nil {
                            LabeledContent("Model") { ProgressView() }
                        } else if let modelsError {
                            Label(modelsError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                ModelPicker(models: models, selection: $modelID)
                            } label: {
                                LabeledContent("Model", value: models.first { $0.id == modelID }?.name ?? "Choose")
                            }
                        }
                    } footer: {
                        Text("Only models that can call tools are listed, since an agent works through them.")
                    }
                }
                if let step {
                    Section { Label(step, systemImage: connected ? "checkmark.circle.fill" : "hourglass").foregroundStyle(connected ? .green : .secondary) }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect a Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .disabled(!ModelProvider.plausible(key: key) || (provider.modelVariable != nil && modelID == nil) || (step != nil && !connected))
                }
            }
            .disabled(step != nil && !connected && error == nil)
            .task { await loadModels() }
        }
    }

    private func agentName(_ provider: ModelProvider) -> String {
        model.agents.listing(provider.agent)?.name ?? provider.agent
    }

    private func loadModels() async {
        guard models.isEmpty else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            models = OpenRouterModel.ranked(try OpenRouterModel.decodeList(data))
            modelID = modelID ?? models.first?.id
        } catch {
            modelsError = "OpenRouter's model list did not load. \(error.localizedDescription)"
        }
    }

    private func connect() {
        error = nil
        connected = false
        step = "Connecting…"
        let provider = provider, key = key, modelID = provider.modelVariable == nil ? nil : modelID
        Task {
            do {
                try await model.agents.connect(provider, key: key, model: modelID) { step = $0 }
                connected = true
                step = "\(agentName(provider)) is ready and is now the default."
                self.key = ""
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch {
                step = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// OpenRouter's models, searchable, leading vendors' newest first.
private struct ModelPicker: View {
    let models: [OpenRouterModel]
    @Binding var selection: String?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown = search.isEmpty ? models : models.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
        List(shown) { item in
            Button {
                selection = item.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(item.id).font(.caption.monospaced())
                            if let price = item.pricePerMillion {
                                Text("· $\(price.input, specifier: "%.2f") / $\(price.output, specifier: "%.2f") per M")
                            }
                            if let context = item.contextLength { Text("· \(context / 1000)K") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    if item.id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search models")
        .navigationTitle("Model")
    }
}
