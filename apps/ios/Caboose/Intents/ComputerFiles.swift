import AppIntents
import CabooseKit
import Foundation

/// The home-relative file operations needed by Shortcuts. The host implements these
/// on the file-service branch; requests fail normally against an older host.
protocol ShortcutFileClient {
    func list(_ path: String) async throws -> [ShortcutFileEntry]
    func open(_ path: String) async throws
    func download(_ path: String) async throws -> URL
    func upload(_ path: String, from file: URL) async throws
}

struct ShortcutFileEntry: Decodable {
    var name: String
    var kind: String
}

struct HostShortcutFiles: ShortcutFileClient {
    let credentials: Credentials
    private func request(_ operation: String, path: String, method: String = "GET") async -> URLRequest {
        let host = await credentials.reachableURL()
        var components = URLComponents(url: host.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3600)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HostClient.Failure.server(status, nil) }
    }
    func list(_ path: String) async throws -> [ShortcutFileEntry] {
        struct List: Decodable { var items: [ShortcutFileEntry] }
        let (data, response) = try await URLSession.shared.data(for: request("list", path: path))
        try check(response)
        return try JSONDecoder().decode(List.self, from: data).items
    }
    func open(_ path: String) async throws {
        var request = await request("open", path: "", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response)
    }
    func download(_ path: String) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(for: request("content", path: path))
        try check(response)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    func upload(_ path: String, from file: URL) async throws {
        var request = await request("content", path: path, method: "PUT")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(response)
    }
}

private func shortcutFiles() throws -> any ShortcutFileClient {
    guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
    return HostShortcutFiles(credentials: credentials)
}

struct ComputerFileEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Computer File")
    static var defaultQuery = ComputerFileQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct ComputerFileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ComputerFileEntity] { identifiers.map { ComputerFileEntity(id: $0) } }
    func suggestedEntities() async throws -> [ComputerFileEntity] {
        try await shortcutFiles().list("").filter { $0.kind == "file" }.map { ComputerFileEntity(id: $0.name) }
    }
    func entities(matching string: String) async throws -> [ComputerFileEntity] {
        try await suggestedEntities().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
}

struct OpenComputerFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Open File on Computer"
    @Parameter(title: "File") var file: ComputerFileEntity
    func perform() async throws -> some IntentResult {
        try await shortcutFiles().open(file.id)
        ComputerSearch.indexFile(file.id)
        return .result()
    }
}

struct GetComputerFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get File from Computer"
    @Parameter(title: "File") var file: ComputerFileEntity
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let url = try await shortcutFiles().download(file.id)
        ComputerSearch.indexFile(file.id)
        var result = IntentFile(fileURL: url, filename: (file.id as NSString).lastPathComponent)
        result.removedOnCompletion = true
        return .result(value: result)
    }
}

struct SaveComputerFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Files to Computer"
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Folder", default: "Downloads") var folder: String
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let client = try shortcutFiles()
        var paths: [String] = []
        for file in files {
            guard let path = ShortcutPath.destination(folder: folder, filename: file.filename) else {
                throw HostClient.Failure.server(400, "Choose a valid folder and filename within your computer home.")
            }
            let temporary: URL?
            let source: URL
            if let url = file.fileURL { source = url; temporary = nil }
            else {
                source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try file.data.write(to: source, options: .atomic)
                temporary = source
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            try await client.upload(path, from: source)
            ComputerSearch.indexFile(path)
            paths.append(path)
        }
        return .result(value: paths)
    }
}
