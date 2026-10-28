import Foundation
import CryptoKit
import FileProvider

/// One external document and the last version synchronized with its computer copy.
struct OpenDocumentRecord: Codable, Identifiable {
    let id: String
    let domain: String
    let name: String
    let path: String
    var bookmark: Data
    var localHash: String
    var remoteETag: String
}

enum OpenDocumentStore {
    static let group = "group.com.braedonsaunders.caboose"
    static func directory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw HostClient.Failure.unreachable("The shared document storage is unavailable.")
        }
        let dir = root.appendingPathComponent("OpenDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func save(_ record: OpenDocumentRecord) throws {
        try JSONEncoder().encode(record).write(to: directory().appendingPathComponent(record.id + ".json"), options: .atomic)
    }
    static func records(domain: String) throws -> [OpenDocumentRecord] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(OpenDocumentRecord.self, from: Data(contentsOf: $0)) }
            .filter { $0.domain == domain }
    }
    static func existing(bookmark: Data, domain: String) throws -> OpenDocumentRecord? {
        var stale = false
        let requested = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
        if stale { return nil }
        return try records(domain: domain).first { record in
            var oldStale = false
            guard let old = try? URL(resolvingBookmarkData: record.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &oldStale), !oldStale else { return false }
            return old.standardizedFileURL == requested
        }
    }
    static func directPath(_ url: URL, domain: String) async throws -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let (id, foundDomain) = try? await NSFileProviderManager.identifierForUserVisibleFile(at: url), foundDomain.rawValue == domain else { return nil }
        guard let paths = UserDefaults(suiteName: group)?.dictionary(forKey: "file-provider-index-v1-" + domain) as? [String: String],
              let path = paths.first(where: { $0.value == id.rawValue })?.key else {
            throw HostClient.Failure.unreachable("The computer file's location is not available yet. Reopen it from Files after reconnecting.")
        }
        return path
    }
}

enum CoordinatedDocument {
    /// Make a stable snapshot while the provider coordinates its original.
    static func snapshot(_ url: URL) throws -> (URL, String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            do { try FileManager.default.copyItem(at: source, to: copy) } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
        do { return (copy, try hash(copy)) } catch { try? FileManager.default.removeItem(at: copy); throw error }
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Check the original again under a write coordination before replacing it.
    static func replace(_ original: URL, with source: URL, expectedHash: String) throws -> String {
        let accessing = original.startAccessingSecurityScopedResource()
        defer { if accessing { original.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, operationError: Error?, result: String?
        NSFileCoordinator().coordinate(writingItemAt: original, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try hash(target) == expectedHash else { throw HostClient.Failure.unreachable("The original changed while syncing. Review the conflict.") }
                let fm = FileManager.default
                let replacementDirectory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                defer { try? fm.removeItem(at: replacementDirectory) }
                let staged = replacementDirectory.appendingPathComponent(target.lastPathComponent)
                try fm.copyItem(at: source, to: staged)
                _ = try fm.replaceItemAt(target, withItemAt: staged)
                result = try hash(target)
            } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
        guard let result else { throw HostClient.Failure.unreachable("The original could not be updated.") }
        return result
    }
}

struct OpenRemoteItem: Decodable { let etag: String; let kind: String }

extension HostClient {
    private func fileRequest(_ operation: String, path: String, method: String = "GET", match: String? = nil, create: Bool = false) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3600)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let match { request.setValue(match, forHTTPHeaderField: "If-Match") }
        if create { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        return request
    }
    private func checkFileResponse(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.server(status, "The computer could not access the document (\(status)).") }
    }
    func openDocumentStat(_ path: String) async throws -> OpenRemoteItem {
        let (data, response) = try await URLSession.shared.data(for: fileRequest("stat", path: path))
        try checkFileResponse(response)
        return try JSONDecoder().decode(OpenRemoteItem.self, from: data)
    }
    func openDocumentMkdir(_ path: String, allowExisting: Bool = false) async throws {
        let (_, response) = try await URLSession.shared.data(for: fileRequest("mkdir", path: path, method: "POST"))
        if allowExisting, (response as? HTTPURLResponse)?.statusCode == 409 { return }
        try checkFileResponse(response)
    }
    func openDocumentUpload(_ file: URL, path: String, match: String? = nil) async throws -> OpenRemoteItem {
        let (data, response) = try await URLSession.shared.upload(for: fileRequest("content", path: path, method: "PUT", match: match, create: match == nil), fromFile: file)
        try checkFileResponse(response)
        return try JSONDecoder().decode(OpenRemoteItem.self, from: data)
    }
    func openDocumentDownload(_ path: String, match: String) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(for: fileRequest("content", path: path, match: match))
        try checkFileResponse(response)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: copy)
        return copy
    }
    func openDocumentLaunch(_ path: String, desktopID: String) async throws {
        let _: [String: Bool] = try await request("POST", "/v1/fs/open", body: ["path": .string(path), "app": .string(desktopID)], timeout: 120)
    }
}
