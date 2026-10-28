import Foundation
import FileProvider
import UniformTypeIdentifiers

final class FileProvider: NSObject, NSFileProviderReplicatedExtension {
    private let index: ItemIndex
    private let domain: NSFileProviderDomainIdentifier
    required init(domain: NSFileProviderDomain) { index = ItemIndex.forDomain(domain); self.domain = domain.identifier; super.init() }
    func invalidate() {}
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        try FileEnumerator(container: containerItemIdentifier, index: index, domain: domain)
    }
    private func run(_ work: @escaping (Progress) async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task { await work(progress); progress.completedUnitCount = 100 }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let path = try self.index.path(identifier)
                completionHandler(FileItem(path: path, remote: try await FileService(domain: self.domain).stat(path), index: self.index), nil)
            } catch { completionHandler(nil, providerError(error)) }
        }
    }
    func fetchContents(for identifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let path = try self.index.path(identifier), service = try FileService(domain: self.domain)
                let version = requestedVersion.flatMap { String(data: $0.contentVersion, encoding: .utf8) }
                let remote = try await service.stat(path)
                if let version, version != remote.etag { throw NSFileProviderError(.localVersionConflictingWithServer) }
                let file = try await service.content(path, version: remote.etag, progress: progress)
                guard try await service.stat(path).etag == remote.etag else {
                    try? FileManager.default.removeItem(at: file)
                    throw NSFileProviderError(.localVersionConflictingWithServer)
                }
                completionHandler(file, FileItem(path: path, remote: remote, index: self.index), nil)
            } catch { completionHandler(nil, nil, providerError(error)) }
        }
    }
    func createItem(basedOn template: NSFileProviderItem, fields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let parent = try self.index.path(template.parentItemIdentifier)
                let path = parent.isEmpty ? template.filename : parent + "/" + template.filename
                let service = try FileService(domain: self.domain), remote: RemoteItem
                if template.contentType?.conforms(to: .folder) == true {
                    remote = try JSONDecoder().decode(RemoteItem.self, from: await service.request("mkdir", path: path, method: "POST"))
                } else if let contents { remote = try await service.upload(path, file: contents, match: nil, progress: progress) }
                else {
                    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try Data().write(to: empty)
                    defer { try? FileManager.default.removeItem(at: empty) }
                    remote = try await service.upload(path, file: empty, match: nil, progress: progress)
                }
                completionHandler(FileItem(path: path, remote: remote, index: self.index), [], false, nil)
            } catch { completionHandler(nil, [], false, providerError(error)) }
        }
    }
    func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let index = self.index, service = try FileService(domain: self.domain)
                var path = try index.path(item.itemIdentifier)
                guard let base = String(data: baseVersion.contentVersion, encoding: .utf8) else {
                    throw NSFileProviderError(.localVersionConflictingWithServer)
                }
                var remote = try await service.stat(path)
                if let contents { remote = try await service.upload(path, file: contents, match: base, progress: progress) }
                else if remote.etag != base { throw NSFileProviderError(.localVersionConflictingWithServer) }
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let parent = try index.path(item.parentItemIdentifier)
                    let destination = parent.isEmpty ? item.filename : parent + "/" + item.filename
                    if destination != path {
                        let data = try JSONEncoder().encode(["destination": destination])
                        let moved = try await service.request("move", path: path, method: "POST", data: data, match: remote.etag)
                        remote = try JSONDecoder().decode(RemoteItem.self, from: moved)
                        index.move(path, to: destination); path = destination
                    }
                }
                completionHandler(FileItem(path: path, remote: remote, index: self.index), [], false, nil)
            } catch { completionHandler(nil, [], false, providerError(error)) }
        }
    }
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        run { progress in
            do {
                let path = try self.index.path(identifier)
                guard let version = String(data: baseVersion.contentVersion, encoding: .utf8) else { throw NSFileProviderError(.localVersionConflictingWithServer) }
                _ = try await FileService(domain: self.domain).request("item", path: path, method: "DELETE", match: version)
                _ = self.index.remove(path)
                completionHandler(nil)
            } catch { completionHandler(providerError(error)) }
        }
    }
}
