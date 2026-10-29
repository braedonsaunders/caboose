import Foundation
import Observation
import UIKit

struct CatalogPack: Decodable, Identifiable { let id: String; let name: String }
struct CatalogProgress: Decodable {
    let id: String
    let operation: String
    let phase: String
    let message: String?
    let stage: String?
    let value: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    var downloadFraction: Double? {
        guard phase == "installing", stage == "downloading", let downloadedBytes, let totalBytes,
              downloadedBytes >= 0, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
    var label: String {
        if phase == "queued" { return "Queued" }
        if phase == "failed" { return "Needs attention" }
        if let message, !message.isEmpty { return message }
        switch stage {
        case "downloading": return downloadFraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading"
        case "verifying": return "Verifying download"
        case "refreshing": return "Refreshing packages"
        case "configuring": return "Completing package setup"
        case "removing": return "Removing"
        case "preparing": return "Preparing"
        default: return operation == "remove" ? "Removing" : "Installing packages"
        }
    }
    var downloadDetail: String? {
        guard downloadFraction != nil, let downloadedBytes, let totalBytes else { return nil }
        let received = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(received) of \(total)"
    }
}
struct CatalogApp: Decodable, Identifiable {
    struct Source: Decodable { let kind: String; let size: Int? }
    struct FileTypes: Decodable { let extensions: [String]; let utTypes: [String] }
    let id: String
    let name: String
    let summary: String
    let category: String
    let packs: [String]
    let desktopId: String
    let categories: [String]?
    let license: String?
    let fileTypes: FileTypes
    let iconData: String?
    let source: Source
    let installedVersion: String?
    let pinnedVersion: String?
    let updateAvailable: Bool
    let canRollback: Bool
    let lastError: String?
    let interrupted: Bool
    var progress: CatalogProgress?
    var needsRecovery: Bool { !busy && (interrupted || lastError != nil || progress?.phase == "failed") }
    var busy: Bool { progress?.phase == "queued" || progress?.phase == "installing" }
    var icon: UIImage? {
        guard let iconData, let comma = iconData.firstIndex(of: ","), let data = Data(base64Encoded: String(iconData[iconData.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }
    var size: String? { source.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } }
}
struct CatalogResponse: Decodable { let packs: [CatalogPack]; let apps: [CatalogApp] }

@MainActor @Observable
final class CatalogCenter {
    private(set) var apps: [CatalogApp] = []
    private(set) var packs: [CatalogPack] = []
    private(set) var storeApps: [CatalogApp] = []
    private(set) var storeLoading = false
    var storeError: String?
    private var storeQuery = ""
    private var storeGeneration = 0
    private(set) var recentInstalls: Set<String> = []
    var error: String?
    private var host: HostClient?
    var onChange: (() async -> Void)?

    func attach(_ host: HostClient) { self.host = host; Task { await refresh(); await discover("") } }
    func reset() { storeGeneration += 1; storeLoading = false; host = nil; apps = []; packs = []; recentInstalls = []; storeApps = []; storeError = nil; storeQuery = ""; error = nil }
    func refresh() async {
        guard let host else { return }
        do {
            let catalog: CatalogResponse = try await host.request("GET", "/v1/catalog", timeout: 60)
            apps = catalog.apps; packs = catalog.packs; storeApps = storeApps.compactMap { item in catalog.apps.first { $0.id == item.id } }; error = nil
        } catch HostClient.Failure.server(404, _) { apps = []; packs = [] }
        catch { self.error = error.localizedDescription }
    }
    func discover(_ query: String) async {
        guard let host else { return }
        if storeQuery != query { storeApps = [] }
        storeQuery = query
        storeGeneration += 1
        let generation = storeGeneration
        storeLoading = true
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) else { return }
        do {
            struct Results: Decodable { let apps: [CatalogApp] }
            let results: Results = try await host.request("GET", "/v1/catalog/discover?q=\(encoded)", timeout: 90)
            guard storeGeneration == generation else { return }
            storeApps = results.apps; storeError = nil; storeLoading = false
            await refresh()
        } catch {
            guard storeGeneration == generation else { return }
            storeError = error.localizedDescription; storeLoading = false
        }
    }
    func perform(_ id: String, action: String, pack: Bool = false) async {
        guard let host else { return }
        error = nil
        let path = pack ? "/v1/catalog/packs/\(id)/install" : action == "remove" ? "/v1/catalog/\(id)" : "/v1/catalog/\(id)/\(action)"
        do {
            let _: [String: Bool] = try await host.request(action == "remove" ? "DELETE" : "POST", path, timeout: 30)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ type: String, _ event: [String: Any]) {
        guard type.hasPrefix("catalog.") else { return }
        if type == "catalog.progress", let id = event["id"] as? String,
           let operation = event["operation"] as? String, let phase = event["phase"] as? String,
           let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].progress = CatalogProgress(id: id, operation: operation, phase: phase, message: event["message"] as? String, stage: event["stage"] as? String, value: event["value"] as? Double, downloadedBytes: (event["downloadedBytes"] as? NSNumber)?.int64Value, totalBytes: (event["totalBytes"] as? NSNumber)?.int64Value)
            if let storeIndex = storeApps.firstIndex(where: { $0.id == id }) {
                storeApps[storeIndex].progress = apps[index].progress
            }
            if phase == "finished" && operation == "install" { recentInstalls.insert(id) }
            if phase == "failed" { error = event["message"] as? String ?? "The application could not be installed." }
        }
        if type == "catalog.changed" { Task { await refresh(); await onChange?() } }
    }
}
