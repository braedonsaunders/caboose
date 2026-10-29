import AppIntents
import SwiftUI

/// A Linux app's desktop action, as Spotlight and Shortcuts identify it.
enum AppActionIdentifier {
    /// Desktop action ids are [A-Za-z0-9-], so `#` separates the app's id from the action's.
    static func id(app: String, action: String) -> String { app + "#" + action }
    static func spotlight(app: String, action: String) -> String { "action:" + id(app: app, action: action) }

    /// The app and action ids of a Spotlight identifier or an entity id.
    static func parse(_ identifier: String) -> (app: String, action: String)? {
        let body = identifier.hasPrefix("action:") ? String(identifier.dropFirst(7)) : identifier
        guard let split = body.lastIndex(of: "#") else { return nil }
        let app = String(body[..<split]), action = String(body[body.index(after: split)...])
        guard !app.isEmpty, !action.isEmpty, action.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return (app, action)
    }
}

struct LinuxAppActionEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Linux App Action")
    static var defaultQuery = LinuxAppActionQuery()
    var id: String
    var app: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(app)") }
}

struct LinuxAppActionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LinuxAppActionEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [LinuxAppActionEntity] {
        guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
        let client = HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
        _ = try await client.wake()
        return try await client.apps().flatMap { app in
            (app.actions ?? []).map { LinuxAppActionEntity(id: AppActionIdentifier.id(app: app.id, action: $0.id), app: app.name, name: $0.name) }
        }
    }
    func entities(matching string: String) async throws -> [LinuxAppActionEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.app.localizedCaseInsensitiveContains(string) }
    }
}

struct OpenLinuxAppActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Linux App Action"
    static var description = IntentDescription("Run one of an app's actions on your computer, such as opening a new private window.")
    @Parameter(title: "Action") var action: LinuxAppActionEntity
    func perform() async throws -> some IntentResult {
        try await ComputerSearch.open("action:" + action.id)
        return .result()
    }
}

/// The context-menu items for a Linux app's desktop actions, for app icons and cards.
struct AppActionsMenu: View {
    let app: HostClient.App
    let host: HostClient?

    var body: some View {
        if let actions = app.actions, !actions.isEmpty, let host {
            Section(app.name) {
                ForEach(actions, id: \.id) { action in
                    Button {
                        Task { try? await host.launch(app, action: action) }
                    } label: {
                        Label(action.name, systemImage: Self.symbol(for: action))
                    }
                }
            }
        }
    }

    /// A symbol from what the action does, by its name or id.
    static func symbol(for action: HostClient.App.Action) -> String {
        let text = (action.id + " " + action.name).lowercased()
        if text.contains("private") || text.contains("incognito") { return "eyeglasses" }
        if text.contains("window") { return "macwindow.badge.plus" }
        if text.contains("tab") { return "plus.square.on.square" }
        if text.contains("document") || text.contains("file") || text.contains("writer") || text.contains("calc") || text.contains("impress") { return "doc.badge.plus" }
        if text.contains("compose") || text.contains("message") || text.contains("mail") { return "square.and.pencil" }
        if text.contains("preferences") || text.contains("settings") { return "gearshape" }
        return "bolt"
    }
}
