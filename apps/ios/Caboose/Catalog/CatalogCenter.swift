import Foundation
import Observation
import UIKit

struct CatalogPack: Decodable, Identifiable { let id: String; let name: String }
struct CatalogProgress: Decodable { let id: String; let operation: String; let phase: String; let message: String?; let stage: String?; let value: Double? }
struct CatalogApp: Decodable, Identifiable {
    struct Source: Decodable { let kind: String; let size: Int? }
    let id: String
    let name: String
    let summary: String
    let category: String
    let packs: [String]
    let desktopId: String
    let iconData: String?
    let source: Source
    let installedVersion: String?
    let pinnedVersion: String?
    let updateAvailable: Bool
    let canRollback: Bool
    let lastError: String?
    let interrupted: Bool
    var progress: CatalogProgress?
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
    var error: String?
    private var host: HostClient?
    var onChange: (() async -> Void)?

    func attach(_ host: HostClient) { self.host = host; Task { await refresh() } }
    func reset() { host = nil; apps = []; packs = []; error = nil }
    func refresh() async {
        guard let host else { return }
        do {
            let catalog: CatalogResponse = try await host.request("GET", "/v1/catalog", timeout: 60)
            apps = catalog.apps; packs = catalog.packs
        } catch HostClient.Failure.server(404, _) { apps = []; packs = [] }
        catch { self.error = error.localizedDescription }
    }
    func perform(_ id: String, action: String, pack: Bool = false) async {
        guard let host else { return }
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
            apps[index].progress = CatalogProgress(id: id, operation: operation, phase: phase, message: event["message"] as? String, stage: event["stage"] as? String, value: event["value"] as? Double)
            if phase == "failed" { error = event["message"] as? String ?? "The application could not be installed." }
        }
        if type == "catalog.changed" { Task { await refresh(); await onChange?() } }
    }
}
