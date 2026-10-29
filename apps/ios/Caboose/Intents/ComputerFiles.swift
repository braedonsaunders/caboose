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
    var mtime: Double
    var etag: String?
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
    /// Metadata only: no disk download, redirects, cookies or persistent cache.
    func desktopShortcutData(_ path: String, etag: String? = nil) async throws -> Data {
        var request = await request("content", path: path)
        request.timeoutInterval = 15
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: DesktopShortcutRedirectPolicy())
        try check(response)
        guard response.expectedContentLength <= Int64(DesktopAppShortcut.maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        return try await DesktopAppShortcut.read(bytes)
    }

    func mkdir(_ path: String, allowExisting: Bool = false) async throws {
        let (_, response) = try await URLSession.shared.data(for: request("mkdir", path: path, method: "POST"))
        if allowExisting, (response as? HTTPURLResponse)?.statusCode == 409 { return }
        try check(response)
    }
    func remove(_ path: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: request("item", path: path, method: "DELETE"))
        try check(response)
    }
    func move(_ path: String, to destination: String, etag: String) async throws {
        var request = await request("move", path: path, method: "POST")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["destination": destination])
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response)
    }
    func trash(_ path: String, etag: String) async throws {
        var request = await request("item", path: path, method: "DELETE")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response)
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


/// Traverse the service's home tree; the service excludes symlinks and special files.
func computerFiles(_ client: any ShortcutFileClient) async throws -> [RecentFile] {
    try await RecentFiles.scan { path in
        do {
            return try await client.list(path).filter { !(path.isEmpty && $0.name == ".caboose-jobs") }.map { FileListingEntry(name: $0.name, isDirectory: $0.kind == "directory", mtime: $0.mtime) }
        } catch HostClient.Failure.server(let status, _) where !path.isEmpty && (status == 403 || status == 404) {
            return [] // A removed or unreadable directory cannot be searched.
        }
    }
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
        try await computerFiles(shortcutFiles()).prefix(200).map { ComputerFileEntity(id: $0.path) }
    }
    func entities(matching string: String) async throws -> [ComputerFileEntity] {
        try await computerFiles(shortcutFiles()).filter { $0.path.localizedCaseInsensitiveContains(string) }.map { ComputerFileEntity(id: $0.path) }
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

private final class DesktopShortcutRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
