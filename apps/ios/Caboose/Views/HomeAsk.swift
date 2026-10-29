import CabooseKit
import SwiftUI

/// Home's Ask field: one place to open a window, an app or a file by name, or to hand what
/// was typed to an agent. A tap opens `HomeFinder` over Home.
struct HomeAskField: View {
    @Environment(AppModel.self) private var model
    @State private var finding = false

    var body: some View {
        Button { finding = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.agents.available ? "Ask, open or find" : "Open or find")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.agents.available {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.amber)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.1), in: .circle)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(height: 50)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(model.agents.available ? "Ask, open or find" : "Open or find")
        .sheet(isPresented: $finding) {
            HomeFinder().environment(model)
        }
    }
}

/// What Ask finds as the owner types: open windows, then apps, then files in the computer's
/// home (`HomeToday.find`), and last, to hand the words to the default agent as a new chat.
/// Return takes the first row.
struct HomeFinder: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("caboose.agent.askFirst") private var askFirst = true
    @State private var query = ""
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else {
                    let found = results
                    if !found.isEmpty {
                        Section { ForEach(found) { row(for: $0) } }
                    }
                    if model.agents.available {
                        Section {
                            askRow
                        } footer: {
                            if let failure { Text(failure).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .safeAreaInset(edge: .top, spacing: 0) { field }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.agents.available ? "Ask, open or find" : "Open or find", text: $query)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(takeFirst)
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: Rows

    private var candidates: [HomeToday.Candidate] {
        let windows = model.appWindows.map {
            HomeToday.Candidate(kind: .window, key: String($0.id), title: $0.title.isEmpty ? model.appName(for: $0) : $0.title,
                                subtitle: model.appName(for: $0))
        }
        let apps = model.apps.map {
            HomeToday.Candidate(kind: .app, key: $0.id, title: $0.name, subtitle: $0.categories.joined(separator: " "))
        }
        let files = RecentFiles.visible(model.recentFiles, limit: 400).map {
            HomeToday.Candidate(kind: .file, key: $0.path, title: ($0.path as NSString).lastPathComponent,
                                subtitle: ($0.path as NSString).deletingLastPathComponent)
        }
        return windows + apps + files
    }

    private var results: [HomeToday.Candidate] { HomeToday.find(query, in: candidates, limit: 12) }

    @ViewBuilder private var suggestions: some View {
        let windows = model.appWindows.prefix(4)
        if !windows.isEmpty {
            Section("Open") {
                ForEach(Array(windows)) { window in
                    row(for: HomeToday.Candidate(kind: .window, key: String(window.id),
                                                 title: window.title.isEmpty ? model.appName(for: window) : window.title,
                                                 subtitle: model.appName(for: window)))
                }
            }
        }
        let apps = model.recentApps(limit: 4)
        if !apps.isEmpty {
            Section("Recent Apps") {
                ForEach(apps) { app in
                    row(for: HomeToday.Candidate(kind: .app, key: app.id, title: app.name, subtitle: ""))
                }
            }
        }
    }

    private func row(for candidate: HomeToday.Candidate) -> some View {
        Button { open(candidate) } label: {
            HStack(spacing: 12) {
                icon(for: candidate)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title).font(.body.weight(.medium)).lineLimit(1)
                    if !candidate.subtitle.isEmpty {
                        Text(subtitle(for: candidate)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var askRow: some View {
        let agent = model.agents.defaultAgent.flatMap { model.agents.listing($0)?.name } ?? "an agent"
        return Button(action: ask) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.amber)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask \(agent)").font(.body.weight(.medium))
                    Text(query).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if sending { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sending)
        .listRowBackground(Brand.amber.opacity(0.12))
    }

    @ViewBuilder private func icon(for candidate: HomeToday.Candidate) -> some View {
        switch candidate.kind {
        case .window:
            if let id = Int(candidate.key), let window = model.window(id), let image = model.icon(for: window) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow").foregroundStyle(Brand.amber)
            }
        case .app:
            if let image = model.appIcons[candidate.key] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(Brand.amber)
            }
        case .file:
            Image(systemName: FileSymbol.name(for: candidate.title))
                .font(.title3)
                .foregroundStyle(Brand.amber)
        }
    }

    private func subtitle(for candidate: HomeToday.Candidate) -> String {
        switch candidate.kind {
        case .window: "Open · \(candidate.subtitle)"
        case .app: "App"
        case .file: candidate.subtitle.isEmpty ? "Home" : candidate.subtitle
        }
    }

    // MARK: Actions

    private func takeFirst() {
        if let first = results.first { open(first) } else if model.agents.available { ask() }
    }

    private func open(_ candidate: HomeToday.Candidate) {
        switch candidate.kind {
        case .window:
            if let id = Int(candidate.key) { model.show(windowID: id) }
        case .app:
            if let app = model.apps.first(where: { $0.id == candidate.key }) { model.open(app) }
        case .file:
            Task { await model.openFile(candidate.key) }
        }
        dismiss()
    }

    /// A new chat with the owner's default agent, opened in Agents.
    private func ask() {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        sending = true
        failure = nil
        Task {
            let agents = model.agents
            if let id = await agents.start(prompt, agent: nil, askFirst: askFirst) {
                agents.currentChat = id
                model.selectedTab = .agents
                dismiss()
            } else {
                failure = agents.lastError ?? "The agent couldn't start."
                agents.lastError = nil
            }
            sending = false
        }
    }
}
