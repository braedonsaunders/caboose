import CabooseKit
import SwiftUI

/// Tools, from the Agents tab: the computer's MCP Library. MCP servers from Smithery give
/// agents more to work with; one added here is available to every agent on this computer, in
/// new chats. The servers on this computer come first, with how each is doing, then rows of
/// Smithery's servers like the app Library's: Popular, Verified, then topics. A search lists
/// Smithery's matches. The computer needs a Smithery account first, connected once.
struct McpLibrary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow = McpFlow()
    @State private var search = ""
    @State private var confirmDisconnect = false

    var body: some View {
        let mcp = model.mcp
        NavigationStack {
            Group {
                if model.host == nil {
                    ContentUnavailableView("No Computer", systemImage: "desktopcomputer",
                                           description: Text("Pair a computer to add tools for its agents."))
                } else if !mcp.available {
                    ContentUnavailableView("No Tools on This Host", systemImage: "puzzlepiece.extension",
                                           description: Text("Update caboose-host to add MCP servers to this computer."))
                } else if let account = mcp.account {
                    if account.connected {
                        library.searchable(text: $search, prompt: "Search Smithery")
                    } else {
                        ConnectSmithery()
                    }
                } else if let error = mcp.accountError {
                    ContentUnavailableView {
                        Label("Tools Unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await mcp.open() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tools")
            .navigationDestination(for: String.self) { McpShelfList(shelfID: $0) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                mcp.prepare(model.host)
                await mcp.open()
            }
        }
        .confirmationDialog("Disconnect Smithery?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await mcp.disconnect() } }
        } message: {
            Text("This computer's servers are removed from Smithery, and its agents lose them. Connecting again starts with none.")
        }
        .mcpFlows(flow, showsErrors: flow.idle && !confirmDisconnect)
    }

    @ViewBuilder private var library: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { storefront } else { McpResults(query: query) }
    }

    private var storefront: some View {
        let mcp = model.mcp
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                onThisComputer
                ForEach(mcp.storefront) { shelf in
                    StoreShelf(title: shelf.title, note: shelf.note, seeAll: shelf.id, items: shelf.servers) { McpTile(server: $0) }
                }
                if let error = mcp.storefrontError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await mcp.loadStorefront() } }
                    }
                    .padding(.horizontal, 20)
                } else if mcp.storefront.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let notice = mcp.storefrontNotice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                account
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            async let servers: Void = mcp.loadConnections(refresh: true)
            async let front: Void = mcp.loadStorefront()
            _ = await (servers, front)
        }
    }

    /// The servers this computer has added, with how each is doing.
    private var onThisComputer: some View {
        let mcp = model.mcp
        return VStack(alignment: .leading, spacing: 4) {
            Text("On This Computer").font(.title3.weight(.semibold)).padding(.horizontal, 20)
            Text("Available to every agent on this computer, in new chats.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
            if !mcp.connectionsLoaded && mcp.connections.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if mcp.connections.isEmpty {
                Text("No servers yet. Add one below and its tools reach agents in their next new chat.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 8)
            }
            ForEach(mcp.connections) { McpConnectionRow(connection: $0).padding(.horizontal, 20).padding(.vertical, 6) }
            if mcp.atLimit {
                Label("This computer holds up to \(mcp.limit) servers. Remove one to add another.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange).padding(.horizontal, 20).padding(.top, 4)
            }
        }
    }

    /// The Smithery account, at the end of the page.
    private var account: some View {
        let mcp = model.mcp
        return VStack(alignment: .leading, spacing: 8) {
            if mcp.account?.disconnecting == true {
                Label("Disconnecting didn't finish", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                Text("Smithery still has some of this computer's servers. Agents can't use Tools until you finish.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Smithery account connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
            }
            if let namespace = mcp.account?.namespace {
                Text("Namespace \(namespace)").font(.caption).foregroundStyle(.secondary)
            }
            if mcp.disconnecting {
                ProgressView()
            } else {
                Button(mcp.account?.disconnecting == true ? "Finish Disconnecting" : "Disconnect", role: .destructive) { confirmDisconnect = true }
            }
        }
        .padding(.horizontal, 20)
    }
}

/// What opens over a Library page: a server's details, Smithery's sign-in page, a server's
/// settings, and confirming a removal. Each sheet keeps its own, so a server's details can
/// sign it in.
@MainActor @Observable
final class McpFlow {
    var detail: McpDetailTarget?
    var signIn: McpSignIn?
    var setup: McpConnection?
    var remove: McpConnection?
    /// The server to check once its sign-in page closes, however it closes.
    var checkAfterSignIn: McpConnection?

    /// Nothing is open over the page, so it can show an alert.
    var idle: Bool { detail == nil && signIn == nil && setup == nil && remove == nil }

    func startSignIn(_ connection: McpConnection, _ url: URL) {
        checkAfterSignIn = connection
        signIn = McpSignIn(connection: connection, url: url)
    }
    /// Opens what a server just added asks for: its sign-in, or its settings.
    func follow(_ connection: McpConnection) {
        switch connection.status {
        case .needsSignIn(let url): startSignIn(connection, url)
        case .needsSetup: setup = connection
        default: break
        }
    }
}

struct McpSignIn: Identifiable {
    let connection: McpConnection
    let url: URL
    var id: String { connection.id }
}

/// The server a details sheet shows, with what is known before its details load.
struct McpDetailTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let iconId: String?
    let server: McpServer?

    init(_ server: McpServer) { id = server.id; name = server.name; iconId = server.iconId; self.server = server }
    init(_ connection: McpConnection) { id = connection.server; name = connection.name; iconId = connection.iconId; server = nil }
}

extension View {
    /// Presents `flow`'s sheets and confirmations, and the Library's errors when `showsErrors`.
    func mcpFlows(_ flow: McpFlow, showsErrors: Bool) -> some View {
        modifier(McpFlows(flow: flow, showsErrors: showsErrors))
    }
}

private struct McpFlows: ViewModifier {
    @Environment(AppModel.self) private var model
    @Bindable var flow: McpFlow
    let showsErrors: Bool

    func body(content: Content) -> some View {
        let mcp = model.mcp
        content
            .environment(flow)
            .sheet(item: $flow.detail) { McpServerPage(target: $0).environment(model) }
            .sheet(item: $flow.signIn, onDismiss: {
                guard let connection = flow.checkAfterSignIn else { return }
                flow.checkAfterSignIn = nil
                Task { await mcp.check(connection) }
            }) { page in
                WebPage(url: page.url, tint: nil) { flow.signIn = nil }.ignoresSafeArea()
            }
            .sheet(item: $flow.setup) { McpSetup(connection: $0).environment(model) }
            .confirmationDialog("Remove \(flow.remove?.name ?? "server")?",
                                isPresented: Binding(get: { flow.remove != nil }, set: { if !$0 { flow.remove = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let connection = flow.remove { Task { await mcp.remove(connection) } }
                    flow.remove = nil
                }
            } message: {
                Text("It's removed from Smithery right away, for every agent on this computer. Chats lose it on their next call to it.")
            }
            // A sheet covers the tabs, whose alert cannot show over it.
            .alert("Tools", isPresented: Binding(get: { showsErrors && mcp.error != nil }, set: { if !$0 { mcp.error = nil } })) {
                Button("OK", role: .cancel) { mcp.error = nil }
            } message: { Text(mcp.error ?? "") }
    }
}

/// Connecting this computer to a Smithery account, once.
private struct ConnectSmithery: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    var body: some View {
        let mcp = model.mcp
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.tint)
                    Text("Connect Smithery").font(.title2.weight(.bold))
                    Text("Tools are MCP servers that let agents do more: search the web, read a calendar, work in GitHub. Smithery hosts them and keeps each one's sign-ins and keys in your Smithery account.")
                    Text("Create an API key in Smithery and paste it here. It stays with Caboose's host and never reaches the computer.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 6)
                Link(destination: URL(string: "https://smithery.ai/account/api-keys")!) {
                    Label("Get an API Key from Smithery", systemImage: "arrow.up.right.square")
                }
            }
            Section {
                NativeTextInput("Smithery API key", text: $key, secure: true, capitalization: .none, correction: false, submit: connect)
                    .disabled(mcp.connecting)
            } footer: {
                if let error = mcp.accountError { Text(error).foregroundStyle(.red) }
                else { Text("Each computer connects to Smithery once, with its own servers.") }
            }
            Section {
                Button(action: connect) {
                    HStack {
                        Text("Connect")
                        if mcp.connecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mcp.connecting)
            }
        }
    }

    private func connect() {
        let entered = key
        guard !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { if await model.mcp.connect(apiKey: entered) { key = "" } }
    }
}

/// A server's icon from Smithery, through the host, or its initial.
private struct McpIcon: View {
    @Environment(AppModel.self) private var model
    let iconId: String?
    let name: String
    var size: StoreIconSize = .row

    var body: some View {
        StoreIcon(image: iconId.flatMap { model.mcp.icons[$0] }, size: size) {
            if let initial = name.first(where: \.isLetter) {
                Text(String(initial).uppercased()).font(.system(style, design: .rounded, weight: .semibold))
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(style))
            }
        }
        .task(id: iconId) { if let iconId { await model.mcp.loadIcon(iconId) } }
        .accessibilityHidden(true)
    }

    private var style: Font.TextStyle {
        switch size {
        case .tile: .title
        case .row: .body
        case .large: .largeTitle
        }
    }
}

private func usesLabel(_ uses: Int) -> String {
    uses == 1 ? "1 use" : "\(uses.formatted(.number.notation(.compactName))) uses"
}

private func toolsLabel(_ tools: Int) -> String { tools == 1 ? "1 tool" : "\(tools) tools" }

/// A server in a row: its icon, name and what it does, then Add or how it is doing.
private struct McpTile: View {
    @Environment(McpFlow.self) private var flow
    let server: McpServer

    var body: some View {
        StoreTile(name: server.name, summary: server.description, open: { flow.detail = McpDetailTarget(server) }) {
            McpIcon(iconId: server.iconId, name: server.name, size: .tile)
        } action: {
            McpServerAction(serverID: server.id, marked: server.connection != nil)
        }
    }
}

/// What a server's tile or row offers: Add, or the next step for a server this computer has.
private struct McpServerAction: View {
    @Environment(AppModel.self) private var model
    @Environment(McpFlow.self) private var flow
    let serverID: String
    /// The host's mark that this computer has the server, before its connections have loaded.
    var marked = false

    var body: some View {
        let mcp = model.mcp
        let connection = mcp.connection(for: serverID)
        if mcp.working.contains(serverID) || connection.map({ mcp.working.contains($0.id) }) == true {
            ProgressView().controlSize(.small)
        } else if let connection {
            switch connection.status {
            case .connected:
                Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            case .needsSignIn(let url):
                Button("Sign In") { flow.startSignIn(connection, url) }.buttonStyle(.borderedProminent).controlSize(.small)
            case .needsSetup:
                Button("Set Up") { flow.setup = connection }.buttonStyle(.borderedProminent).controlSize(.small)
            case .failed:
                Button("Check") { Task { await mcp.check(connection) } }.buttonStyle(.bordered).controlSize(.small)
            case .checking:
                ProgressView().controlSize(.small)
            }
        } else if marked {
            Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Add") { Task { if let added = await mcp.add(serverID) { flow.follow(added) } } }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(mcp.atLimit)
        }
    }
}

/// How one of the computer's servers is doing, in words.
private struct McpStatusLine: View {
    let status: McpConnectionStatus

    var body: some View {
        switch status {
        case .connected(let tools):
            Label("Connected · \(toolsLabel(tools))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsSignIn:
            Label("Sign in to finish connecting.", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
        case .needsSetup:
            Label("Add the settings this server needs to connect.", systemImage: "slider.horizontal.3").foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .checking:
            Label("Checking…", systemImage: "clock").foregroundStyle(.secondary)
        }
    }
}

/// One of the computer's servers: how it is doing, its next step, and Check Again and Remove.
private struct McpConnectionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(McpFlow.self) private var flow
    let connection: McpConnection

    var body: some View {
        let mcp = model.mcp
        StoreListRow(name: connection.name, summary: connection.server, open: { flow.detail = McpDetailTarget(connection) }) {
            McpIcon(iconId: connection.iconId, name: connection.name)
        } details: {
            McpStatusLine(status: connection.status).font(.caption2).lineLimit(3)
        } trailing: {
            McpServerAction(serverID: connection.server)
            Menu {
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await mcp.check(connection) } }
                Button("Remove", systemImage: "trash", role: .destructive) { flow.remove = connection }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .disabled(mcp.working.contains(connection.id))
            .accessibilityLabel("More for \(connection.name)")
        }
    }
}

/// A server in a list: who publishes it, Smithery's verified seal, its uses, and Add or how it
/// is doing.
private struct McpServerRow: View {
    @Environment(McpFlow.self) private var flow
    let server: McpServer

    var body: some View {
        StoreListRow(name: server.name, summary: server.description, open: { flow.detail = McpDetailTarget(server) }) {
            McpIcon(iconId: server.iconId, name: server.name)
        } details: {
            HStack(spacing: 4) {
                Text(server.id).lineLimit(1)
                if server.verified {
                    Image(systemName: "checkmark.seal.fill").imageScale(.small).foregroundStyle(.tint).accessibilityLabel("Verified")
                }
                Text("· \(usesLabel(server.uses))").lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } trailing: {
            McpServerAction(serverID: server.id, marked: server.connection != nil)
        }
    }
}

/// Smithery's matches for a search, as rows, a page at a time.
private struct McpResults: View {
    @Environment(AppModel.self) private var model
    let query: String

    var body: some View {
        let mcp = model.mcp
        List {
            ForEach(mcp.results) { server in
                McpServerRow(server: server)
                    .onAppear { if server.id == mcp.results.last?.id { Task { await mcp.loadMore() } } }
            }
            if let error = mcp.resultsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await mcp.retrySearch() } }
                }
            } else if mcp.resultsLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if mcp.resultsLoaded && mcp.results.isEmpty {
                Text("No servers found.").foregroundStyle(.secondary)
            }
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await mcp.search(query)
        }
        .refreshable { await mcp.search(query) }
    }
}

/// A front-page row in full, from See All, a page at a time.
private struct McpShelfList: View {
    @Environment(AppModel.self) private var model
    let shelfID: String

    var body: some View {
        let mcp = model.mcp
        let shelf = mcp.storefront.first { $0.id == shelfID }
        List {
            Section {
                ForEach(mcp.resultsGroup == shelfID ? mcp.results : []) { server in
                    McpServerRow(server: server)
                        .onAppear { if server.id == mcp.results.last?.id { Task { await mcp.loadMore() } } }
                }
                if let error = mcp.resultsError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await mcp.retrySearch() } }
                    }
                } else if mcp.resultsLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } footer: {
                if let note = shelf?.note { Text(note) }
            }
        }
        .navigationTitle(shelf?.title ?? "Servers")
        .task(id: shelfID) { await mcp.browse(shelfID) }
        .refreshable { await mcp.browse(shelfID) }
    }
}

/// A server's details: who publishes it, its uses, what it does and the tools Smithery lists,
/// with Add, or its status and Remove.
private struct McpServerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: McpDetailTarget
    @State private var flow = McpFlow()
    @State private var detail: McpServerDetail?
    @State private var failure: String?

    var body: some View {
        let mcp = model.mcp
        let server = detail?.server ?? target.server
        let connection = mcp.connection(for: target.id)
        NavigationStack {
            List {
                Section {
                    header(server)
                    status(connection)
                }
                if let server {
                    Section("About") {
                        Text(server.description)
                        if let homepage = server.homepageURL {
                            Link(destination: homepage) { Label(homepage.host() ?? "Website", systemImage: "safari") }
                        }
                    }
                }
                Section {
                    Label("Available to every agent on this computer, in new chats.", systemImage: "person.2")
                    Label("Smithery lists this server; Caboose hasn't reviewed it.", systemImage: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Section("Tools") { tools }
            }
            .navigationTitle(server?.name ?? target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
        .mcpFlows(flow, showsErrors: flow.idle)
    }

    private func load() async {
        failure = nil
        do {
            if let loaded = try await model.mcp.detail(target.id) { detail = loaded }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func header(_ server: McpServer?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            McpIcon(iconId: server?.iconId ?? target.iconId, name: server?.name ?? target.name, size: .large)
            VStack(alignment: .leading, spacing: 4) {
                Text(server?.name ?? target.name).font(.title2.weight(.bold))
                Text(target.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let server {
                    if server.verified {
                        Label("Verified publisher", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.tint)
                    }
                    Text("\(usesLabel(server.uses)) on Smithery").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func status(_ connection: McpConnection?) -> some View {
        let mcp = model.mcp
        if let connection {
            let working = mcp.working.contains(connection.id)
            McpStatusLine(status: connection.status).font(.subheadline)
            switch connection.status {
            case .needsSignIn(let url):
                Button("Sign In", systemImage: "person.crop.circle") { flow.startSignIn(connection, url) }.disabled(working)
            case .needsSetup:
                Button("Set Up", systemImage: "slider.horizontal.3") { flow.setup = connection }.disabled(working)
            case .failed, .connected:
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await mcp.check(connection) } }.disabled(working)
            case .checking:
                EmptyView()
            }
            if working { ProgressView().frame(maxWidth: .infinity) }
            Button("Remove from This Computer", systemImage: "trash", role: .destructive) { flow.remove = connection }.disabled(working)
        } else if mcp.atLimit {
            Label("This computer holds up to \(mcp.limit) servers. Remove one to add another.", systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.orange)
        } else if mcp.working.contains(target.id) {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            Button {
                Task { if let added = await mcp.add(target.id) { flow.follow(added) } }
            } label: {
                Label("Add to This Computer", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mcp.account?.connected != true)
        }
    }

    @ViewBuilder private var tools: some View {
        if let detail {
            if detail.tools.isEmpty {
                Text("Smithery lists no tools for this server.").foregroundStyle(.secondary)
            }
            ForEach(Array(detail.tools.enumerated()), id: \.offset) { _, tool in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.subheadline.monospaced().weight(.medium))
                    if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } else if let failure {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

/// The settings a server asked for, such as its API key. They go to Smithery, which keeps them
/// for the server; Caboose keeps no copy.
private struct McpSetup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: McpConnection
    @State private var form: McpSetupForm
    @State private var saving = false
    @State private var failure: String?
    @State private var showingSmithery = false
    private let smitheryPage: URL?

    init(connection: McpConnection) {
        self.connection = connection
        if case .needsSetup(let fields, let page) = connection.status {
            _form = State(initialValue: McpSetupForm(fields: fields))
            smitheryPage = page
        } else {
            _form = State(initialValue: McpSetupForm(fields: []))
            smitheryPage = nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(connection.name) needs these settings to connect. They go to Smithery, which keeps them for this server; Caboose keeps no copy.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(form.fields) { field in
                    Section {
                        NativeTextInput(field.label, text: value(field.key), secure: field.location == .header,
                                        capitalization: .none, correction: false)
                            .disabled(saving)
                    } header: {
                        Text(field.required ? field.label : "\(field.label) (optional)")
                    } footer: {
                        if !field.description.isEmpty { Text(field.description) }
                    }
                }
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                if smitheryPage != nil {
                    Section {
                        Button("Set Up on Smithery Instead", systemImage: "safari") { showingSmithery = true }
                    }
                }
            }
            .navigationTitle("Set Up \(connection.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(!form.isComplete) }
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .sheet(isPresented: $showingSmithery, onDismiss: checkAfterSmithery) {
            if let smitheryPage { WebPage(url: smitheryPage, tint: nil) { showingSmithery = false }.ignoresSafeArea() }
        }
    }

    private func value(_ key: String) -> Binding<String> {
        Binding(get: { form.values[key] ?? "" }, set: { form.values[key] = $0 })
    }

    private func save() {
        guard let values = form.submission else { return }
        let mcp = model.mcp
        saving = true; failure = nil
        Task {
            let saved = await mcp.configure(connection, values: values)
            saving = false
            if saved != nil { dismiss() } else { failure = mcp.error; mcp.error = nil }
        }
    }

    /// Smithery's page may have taken the settings; this sheet closes once the server no
    /// longer waits for them.
    private func checkAfterSmithery() {
        let mcp = model.mcp
        Task {
            await mcp.check(connection)
            if let now = mcp.connection(for: connection.server), case .needsSetup = now.status { return }
            dismiss()
        }
    }
}
