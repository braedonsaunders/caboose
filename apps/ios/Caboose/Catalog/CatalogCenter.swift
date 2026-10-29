import CabooseKit
import Foundation
import ImageIO
import Observation
import UIKit

struct CatalogPack: Decodable, Hashable, Identifiable { let id: String; let name: String }
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
    let curated: Bool?
    let developer: String?
    /// Flathub's verified publishers.
    let verified: Bool?
    let fileTypes: FileTypes
    let iconData: String?
    let source: Source
    var installedVersion: String?
    var updateAvailable: Bool
    var lastError: String?
    var interrupted: Bool
    var progress: CatalogProgress?
    var needsRecovery: Bool { !busy && (interrupted || lastError != nil || progress?.phase == "failed") }
    var busy: Bool { progress?.phase == "queued" || progress?.phase == "installing" }
    var icon: UIImage? { iconData.flatMap(Self.decodeIcon) }
    var size: String? { source.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } }
    /// `GET /v1/catalog` lists every app that is curated, installed, being changed or failed,
    /// so an app from discover that it leaves out has none of that state.
    var settled: CatalogApp {
        var app = self
        app.installedVersion = nil; app.updateAvailable = false; app.lastError = nil; app.interrupted = false; app.progress = nil
        return app
    }

    private static let icons = NSCache<NSString, UIImage>()
    /// A PNG data URL, decoded once and at most 128 pixels on a side: a small file can name
    /// huge dimensions.
    private static func decodeIcon(_ url: String) -> UIImage? {
        if let cached = icons.object(forKey: url as NSString) { return cached }
        guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let icon = UIImage(cgImage: image)
        icons.setObject(icon, forKey: url as NSString)
        return icon
    }
}
struct CatalogResponse: Decodable { let packs: [CatalogPack]; let apps: [CatalogApp] }

@MainActor @Observable
final class CatalogCenter {
    private(set) var apps: [CatalogApp] = []
    private(set) var packs: [CatalogPack] = []
    /// The Library: one ranked list from discover, curated apps first, a page at a time.
    private(set) var library: [CatalogApp] = []
    /// Discover's categories, in its order.
    private(set) var categories: [String] = []
    private(set) var libraryQuery = LibraryQuery()
    private(set) var libraryLoading = false
    private(set) var libraryLoaded = false
    var libraryError: String?
    private var nextOffset: Int?
    private var failedOffset = 0
    private var libraryGeneration = 0
    private(set) var recentInstalls: Set<String> = []
    var error: String?
    private var hostGeneration = 0
    private var host: HostClient?
    var onChange: (() async -> Void)?

    /// A Library already showing loads its search again from the newly attached host.
    func attach(_ host: HostClient) {
        hostGeneration += 1
        let showing = libraryLoaded || libraryLoading ? libraryQuery : nil
        clearLibrary(); self.host = host
        Task { await refresh(); if let showing { await discover(showing) } }
    }
    /// The Library works while the computer is parked, so it attaches before any wake has.
    func prepare(_ host: HostClient?) { if self.host == nil, let host { attach(host) } }
    func reset() { hostGeneration += 1; clearLibrary(); host = nil; apps = []; packs = []; recentInstalls = []; categories = []; error = nil }
    private func clearLibrary() {
        libraryGeneration += 1; libraryLoading = false; libraryLoaded = false; library = []; libraryError = nil; nextOffset = nil; libraryQuery = LibraryQuery()
    }
    func refresh() async {
        guard let host else { return }
        let generation = hostGeneration
        do {
            let catalog: CatalogResponse = try await host.request("GET", "/v1/catalog", timeout: 60)
            guard hostGeneration == generation else { return }
            apps = catalog.apps; packs = catalog.packs; error = nil
            let live = Dictionary(catalog.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            library = library.map { live[$0.id] ?? $0.settled }
        } catch HostClient.Failure.server(404, _) { if hostGeneration == generation { apps = []; packs = [] } }
        catch { if hostGeneration == generation { self.error = error.localizedDescription } }
    }
    /// The first page for a search and category. Discover answers from the host's own index,
    /// so it works while the computer is parked and never wakes it.
    func discover(_ query: LibraryQuery) async {
        if query != libraryQuery { library = []; nextOffset = nil; libraryLoaded = false }
        libraryQuery = query
        await load(offset: 0)
    }
    func loadMore() async {
        guard !libraryLoading, libraryError == nil, let nextOffset else { return }
        await load(offset: nextOffset)
    }
    func retryLibrary() async { await load(offset: failedOffset) }
    private func load(offset: Int) async {
        guard let host else { return }
        libraryGeneration += 1
        let generation = libraryGeneration, hostVersion = hostGeneration
        libraryLoading = true; libraryError = nil
        do {
            struct Page: Decodable { let apps: [CatalogApp]; let total: Int; let offset: Int; let categories: [String] }
            let page: Page = try await host.request("GET", libraryQuery.path(offset: offset), timeout: 60)
            guard libraryGeneration == generation && hostGeneration == hostVersion else { return }
            let live = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let fresh = page.apps.map { live[$0.id] ?? $0 }
            library = (page.offset == 0 ? [] : library).appendingPage(fresh)
            categories = page.categories
            nextOffset = LibraryQuery.nextOffset(after: page.offset, count: page.apps.count, total: page.total)
            libraryLoading = false; libraryLoaded = true
        } catch {
            guard libraryGeneration == generation && hostGeneration == hostVersion else { return }
            libraryError = error.localizedDescription; failedOffset = offset; libraryLoading = false
        }
    }
    func perform(_ id: String, action: String, pack: Bool = false) async {
        guard let host else { return }
        error = nil
        let encoded = HostClient.pathComponent(id)
        let path = pack ? "/v1/catalog/packs/\(encoded)/install" : action == "remove" ? "/v1/catalog/\(encoded)" : "/v1/catalog/\(encoded)/\(action)"
        do {
            let _: [String: Bool] = try await host.request(action == "remove" ? "DELETE" : "POST", path, timeout: 30)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ type: String, _ event: [String: Any]) {
        guard type.hasPrefix("catalog.") else { return }
        if type == "catalog.progress", let id = event["id"] as? String,
           let operation = event["operation"] as? String, let phase = event["phase"] as? String {
            let progress = CatalogProgress(id: id, operation: operation, phase: phase, message: event["message"] as? String, stage: event["stage"] as? String, value: event["value"] as? Double, downloadedBytes: (event["downloadedBytes"] as? NSNumber)?.int64Value, totalBytes: (event["totalBytes"] as? NSNumber)?.int64Value)
            if let index = apps.firstIndex(where: { $0.id == id }) { apps[index].progress = progress }
            if let index = library.firstIndex(where: { $0.id == id }) { library[index].progress = progress }
            if phase == "finished" && operation == "install" { recentInstalls.insert(id) }
            if phase == "failed" { error = event["message"] as? String ?? "The application could not be installed." }
        }
        if type == "catalog.changed" { Task { await refresh(); await onChange?() } }
    }
}
