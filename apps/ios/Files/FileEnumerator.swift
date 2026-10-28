import Foundation
import FileProvider

final class FileEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let path: String
    private let index: ItemIndex
    private let domain: NSFileProviderDomainIdentifier
    init(container: NSFileProviderItemIdentifier, index: ItemIndex, domain: NSFileProviderDomainIdentifier) throws {
        self.domain = domain
        self.container = container
        self.index = index
        self.path = container == .workingSet ? "" : try index.path(container)
    }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let service = try FileService(domain: domain)
                let offset = Int(String(data: page.rawValue, encoding: .utf8) ?? "") ?? 0
                var seen = 0, hasMore = false
                var pending = [path], result: [NSFileProviderItem] = []
                while !pending.isEmpty && !hasMore {
                    let parent = pending.removeFirst()
                    for item in try await service.list(parent).sorted(by: { $0.name < $1.name }) {
                        let child = parent.isEmpty ? item.name : parent + "/" + item.name
                        if container == .workingSet && item.kind == "directory" { pending.append(child) }
                        if seen < offset { seen += 1; continue }
                        if result.count == 200 { hasMore = true; break }
                        if let old = index.candidate(for: child, identity: item.identity) {
                            do { _ = try await service.stat(old) }
                            catch let error as NSFileProviderError where error.code == .noSuchItem { index.move(old, to: child) }
                        }
                        result.append(FileItem(path: child, remote: item, index: index))
                        seen += 1
                    }
                }
                observer.didEnumerate(result)
                observer.finishEnumerating(upTo: hasMore ? NSFileProviderPage(Data(String(offset + result.count).utf8)) : nil)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            let anchor = try? await FileService(domain: domain).changes().anchor
            completionHandler(anchor.map { NSFileProviderSyncAnchor(Data($0.utf8)) })
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let service = try FileService(domain: domain)
                let changes = try await service.changes(String(data: anchor.rawValue, encoding: .utf8) ?? "")
                if changes.reset { throw NSFileProviderError(.syncAnchorExpired) }
                let index = self.index
                var sources: [Int: String] = [:], renamed: Set<String> = []
                for event in changes.events where event.cookie != 0 {
                    if event.removed { sources[event.cookie] = event.path }
                    else if let old = sources[event.cookie] { index.move(old, to: event.path); renamed.insert(old) }
                }
                var last: [String: Bool] = [:]
                for event in changes.events where !event.path.isEmpty && !renamed.contains(event.path) { last[event.path] = event.removed }
                var deleted: [NSFileProviderItemIdentifier] = [], updated: [NSFileProviderItem] = []
                for (changedPath, _) in last {
                    let parent = (changedPath as NSString).deletingLastPathComponent
                    if container != .workingSet && (parent == "." ? "" : parent) != path { continue }
                    do {
                        updated.append(FileItem(path: changedPath, remote: try await service.stat(changedPath), index: index))
                    } catch let error as NSFileProviderError where error.code == .noSuchItem {
                        deleted.append(contentsOf: index.remove(changedPath))
                    }
                }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(changes.anchor.utf8)), moreComing: false)
            } catch { observer.finishEnumeratingWithError(providerError(error)) }
        }
    }
}
