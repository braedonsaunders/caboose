import AppIntents
import Foundation

private enum IntentConnectionError: LocalizedError {
    case notPaired
    var errorDescription: String? { "Open Caboose and connect to your computer first." }
}

private func intentClient() async throws -> HostClient {
    guard let credentials = Credentials.load() else { throw IntentConnectionError.notPaired }
    return HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
}

struct LinuxAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Linux App")
    static var defaultQuery = LinuxAppQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LinuxAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LinuxAppEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [LinuxAppEntity] {
        let client = try await intentClient()
        _ = try await client.wake()
        return try await client.apps().map { LinuxAppEntity(id: $0.id, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [LinuxAppEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct OpenLinuxAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Linux App"
    static var description = IntentDescription("Open an app on your computer.")
    @Parameter(title: "App") var app: LinuxAppEntity
    init() {}
    init(app: LinuxAppEntity?) { if let app { self.app = app } }
    func perform() async throws -> some IntentResult {
        let client = try await intentClient()
        _ = try await client.wake()
        guard let selected = try await client.apps().first(where: { $0.id == app.id }) else {
            throw HostClient.Failure.server(404, "This app is no longer installed on your computer.")
        }
        try await client.launch(selected)
        return .result()
    }
}

struct WakeComputerIntent: AppIntent {
    static var title: LocalizedStringResource = "Wake Computer"
    func perform() async throws -> some IntentResult {
        _ = try await intentClient().wake()
        return .result()
    }
}

struct ParkComputerIntent: AppIntent {
    static var title: LocalizedStringResource = "Park Computer"
    func perform() async throws -> some IntentResult {
        try await intentClient().park()
        return .result()
    }
}

struct OpenComputerURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Open URL on Computer"
    @Parameter(title: "URL") var url: URL
    func perform() async throws -> some IntentResult {
        let client = try await intentClient()
        _ = try await client.wake()
        try await client.open(url)
        return .result()
    }
}

struct AskComputerAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Computer Agent"
    static var description = IntentDescription("Start an agent task and return its link.")
    @Parameter(title: "Prompt") var prompt: String
    @Parameter(title: "Agent ID") var agent: String?
    @Parameter(title: "Files") var files: [IntentFile]?
    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let client = try await intentClient()
        _ = try await client.wake()
        let attachments = (files ?? []).map { file in
            AgentAttachment(name: file.filename, type: file.type?.preferredMIMEType ?? "application/octet-stream", data: file.data)
        }
        let id = try await client.startAgentTask(prompt: prompt, agent: agent, approvals: "ask", attachments: attachments)
        guard let link = URL(string: "caboose://task/\(id)") else { throw HostClient.Failure.server(500, "Invalid task ID.") }
        return .result(value: link)
    }
}

struct CabooseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeComputerIntent(), phrases: ["Wake my computer with \(.applicationName)", "Wake \(.applicationName)"], shortTitle: "Wake Computer", systemImageName: "power")
        AppShortcut(intent: ParkComputerIntent(), phrases: ["Park my computer with \(.applicationName)"], shortTitle: "Park Computer", systemImageName: "pause.circle")
        AppShortcut(intent: OpenLinuxAppIntent(), phrases: ["Open a Linux app with \(.applicationName)"], shortTitle: "Open Linux App", systemImageName: "app")
        AppShortcut(intent: AskComputerAgentIntent(), phrases: ["Ask my computer with \(.applicationName)"], shortTitle: "Ask Agent", systemImageName: "sparkles")
        #if CABOOSE_APP
        AppShortcut(intent: OpenComputerURLIntent(), phrases: ["Open a website on my computer with \(.applicationName)"], shortTitle: "Open Website", systemImageName: "globe")
        AppShortcut(intent: OpenComputerFileIntent(), phrases: ["Open a computer file with \(.applicationName)"], shortTitle: "Open File", systemImageName: "doc")
        AppShortcut(intent: PhotoCraftConvertIntent(), phrases: ["Convert images with \(.applicationName)"], shortTitle: "Convert Images", systemImageName: "photo")
        AppShortcut(intent: PDFCraftCombineIntent(), phrases: ["Combine PDFs with \(.applicationName)"], shortTitle: "Combine PDFs", systemImageName: "doc.on.doc")
        AppShortcut(intent: LightCraftRenderIntent(), phrases: ["Develop a photo with \(.applicationName)"], shortTitle: "Develop Photo", systemImageName: "camera")
        AppShortcut(intent: FilmCraftExportIntent(), phrases: ["Export a film with \(.applicationName)"], shortTitle: "Export Film", systemImageName: "film")
        #endif
    }
}
