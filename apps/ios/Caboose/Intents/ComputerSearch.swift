import CabooseKit
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum ComputerSearch {
    private static let appsDomain = "computer-apps"
    private static let filesDomain = "computer-files"
    static func indexApps(_ apps: [HostClient.App]) {
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [appsDomain]) { error in
            guard error == nil else { return }
            let items = apps.map { app in
                let attributes = CSSearchableItemAttributeSet(contentType: .application)
                attributes.title = app.name
                attributes.contentDescription = "Open on your computer"
                attributes.thumbnailData = app.iconData
                return CSSearchableItem(uniqueIdentifier: "app:" + app.id, domainIdentifier: appsDomain, attributeSet: attributes)
            }
            // Each app's desktop actions ("New Private Window") are found and run the same way.
            let actions = apps.flatMap { app in
                (app.actions ?? []).map { action in
                    let attributes = CSSearchableItemAttributeSet(contentType: .application)
                    attributes.title = action.name
                    attributes.contentDescription = app.name
                    attributes.thumbnailData = app.iconData
                    return CSSearchableItem(uniqueIdentifier: AppActionIdentifier.spotlight(app: app.id, action: action.id), domainIdentifier: appsDomain, attributeSet: attributes)
                }
            }
            index.indexSearchableItems(items + actions, completionHandler: nil)
        }
    }
    static func indexFile(_ path: String) {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = (path as NSString).lastPathComponent
        attributes.contentDescription = "Computer file: \(path)"
        CSSearchableIndex.default().indexSearchableItems([
            CSSearchableItem(uniqueIdentifier: "file:" + path, domainIdentifier: filesDomain, attributeSet: attributes)
        ], completionHandler: nil)
    }
    @discardableResult
    static func refreshFiles(credentials: Credentials) async throws -> [RecentFile] {
        let files = try await computerFiles(HostShortcutFiles(credentials: credentials))
        try Task.checkCancellation()
        let index = CSSearchableIndex.default()
        try await index.deleteSearchableItems(withDomainIdentifiers: [filesDomain])
        try Task.checkCancellation()
        let items = files.prefix(200).map { file in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = (file.path as NSString).lastPathComponent
            attributes.contentDescription = "Computer file: \(file.path)"
            return CSSearchableItem(uniqueIdentifier: "file:" + file.path, domainIdentifier: filesDomain, attributeSet: attributes)
        }
        try await index.indexSearchableItems(items)
        return files
    }
    static func invalidateFiles() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [filesDomain], completionHandler: nil)
    }
    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [appsDomain, filesDomain], completionHandler: nil)
    }
    static func open(_ identifier: String) async throws {
        if identifier.hasPrefix("file:") {
            guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
            try await HostShortcutFiles(credentials: credentials).open(String(identifier.dropFirst(5)))
        } else if let (appID, actionID) = AppActionIdentifier.parse(identifier) {
            guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
            let client = HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
            _ = try await client.wake()
            guard let app = try await client.apps().first(where: { $0.id == appID }),
                  let action = app.actions?.first(where: { $0.id == actionID }) else { throw HostClient.Failure.server(404, "That action is no longer available.") }
            try await client.launch(app, action: action)
        } else if identifier.hasPrefix("app:") {
            guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
            let client = HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
            _ = try await client.wake()
            let id = String(identifier.dropFirst(4))
            guard let app = try await client.apps().first(where: { $0.id == id }) else { throw HostClient.Failure.server(404, "App no longer installed.") }
            try await client.launch(app)
        }
    }
}
