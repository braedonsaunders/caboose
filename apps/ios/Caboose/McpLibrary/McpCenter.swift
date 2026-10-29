import CabooseKit
import Foundation
import Observation
import UIKit

/// The computer's MCP Library: the Smithery account it uses, the servers it has added, which
/// every agent on it can use in new chats, and Smithery's listing to add more from
/// (docs/architecture.md, MCP Library). Every route answers from the host, so the Library
/// works while the computer is parked and never wakes it.
@MainActor @Observable
final class McpCenter {
    /// Whether this computer has a Smithery account, or nil until the host has said.
    private(set) var account: McpAccount?
    /// False when the host has no MCP Library: it predates it, or runs without one.
    private(set) var available = true
    private(set) var accountError: String?
    private(set) var connecting = false
    private(set) var disconnecting = false

    private(set) var connections: [McpConnection] = []
    /// How many servers a computer holds.
    private(set) var limit = 20
    private(set) var connectionsLoaded = false
    var atLimit: Bool { connections.count >= limit }

    /// The front page, a row at a time: Popular, Verified, then topics.
    private(set) var storefront: [McpShelf] = []
    private(set) var storefrontError: String?
    /// Why the rows are missing or old: Smithery could not be reached.
    private(set) var storefrontNotice: String?

    /// A search's matches, a page at a time.
    private(set) var results: [McpServer] = []
    private(set) var resultsQuery = ""
    private(set) var resultsLoading = false
    private(set) var resultsLoaded = false
    var resultsError: String?
    private var nextPage: Int?
    private var failedPage = 1
    private var searchGeneration = 0

    /// Servers and connections with an add, check, change or removal underway, by id.
    private(set) var working: Set<String> = []
    var error: String?

    private(set) var icons: [String: UIImage] = [:]
    private var iconsRequested: Set<String> = []

    private var hostGeneration = 0
    private var host: HostClient?

    /// A Library already showing loads again from the newly attached host.
    func attach(_ host: HostClient) {
        hostGeneration += 1
        let showing = account != nil
        let front = !storefront.isEmpty || storefrontError != nil
        let search = resultsLoaded || resultsLoading ? resultsQuery : nil
        clear(); self.host = host
        Task {
            if showing { await open() } else if front { await loadStorefront() }
            if let search { await self.search(search) }
        }
    }
    /// The Library works while the computer is parked, so it attaches before any wake has.
    func prepare(_ host: HostClient?) { if self.host == nil, let host { attach(host) } }
    func reset() { hostGeneration += 1; clear(); host = nil }
    private func clear() {
        clearResults()
        account = nil; available = true; accountError = nil; connecting = false; disconnecting = false
        connections = []; limit = 20; connectionsLoaded = false
        storefront = []; storefrontError = nil; storefrontNotice = nil
        working = []; error = nil; icons = [:]; iconsRequested = []
    }
    private func clearResults() {
        searchGeneration += 1; results = []; resultsQuery = ""; resultsLoading = false; resultsLoaded = false; resultsError = nil; nextPage = nil
    }

    /// Opening the Library: the account, the servers as the host last heard of them, then the
    /// front page and a fresh word from Smithery on each server.
    func open() async {
        await loadAccount()
        guard account?.connected == true else { if available { await loadStorefront() }; return }
        if !connectionsLoaded { await loadConnections(refresh: false) }
        async let front: Void = loadStorefront()
        async let servers: Void = loadConnections(refresh: true)
        _ = await (front, servers)
    }

    func loadAccount() async {
        guard let host else { return }
        let generation = hostGeneration
        do {
            let answer: McpAccount = try await host.request("GET", McpRoute.account, timeout: 30)
            guard hostGeneration == generation else { return }
            account = answer; available = true; accountError = nil
        } catch HostClient.Failure.server(404, _) {
            if hostGeneration == generation { available = false }
        } catch {
            if hostGeneration == generation { accountError = error.localizedDescription }
        }
    }

    /// Connects this computer to a Smithery account with one of its API keys. The key stays
    /// on the host; it never reaches the computer.
    func connect(apiKey: String) async -> Bool {
        guard let host, !connecting else { return false }
        let generation = hostGeneration
        connecting = true; accountError = nil
        defer { if hostGeneration == generation { connecting = false } }
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: McpAccount = try await host.request("PUT", McpRoute.account, body: ["apiKey": .string(key)], timeout: 60)
            guard hostGeneration == generation else { return false }
            account = answer
            await loadConnections(refresh: false)
            if storefront.isEmpty { await loadStorefront() }
            return answer.connected
        } catch {
            if hostGeneration == generation { accountError = error.localizedDescription }
            return false
        }
    }

    /// Removes this computer's servers from Smithery and forgets the account.
    func disconnect() async {
        guard let host else { return }
        let generation = hostGeneration
        disconnecting = true; error = nil
        defer { if hostGeneration == generation { disconnecting = false } }
        do {
            let answer: McpAccount = try await host.request("DELETE", McpRoute.account, timeout: 120)
            guard hostGeneration == generation else { return }
            account = answer
            apply(connections: [], limit: limit)
        } catch {
            if hostGeneration == generation { self.error = error.localizedDescription }
        }
    }

    /// The computer's servers. Answers apply in the order they arrive: each is the host's
    /// state when it answered, and a refresh's statuses are not announced again.
    func loadConnections(refresh: Bool) async {
        guard let host else { return }
        let generation = hostGeneration
        do {
            let answer: McpConnections = try await host.request("GET", McpRoute.connections(refresh: refresh), timeout: refresh ? 120 : 30)
            guard hostGeneration == generation else { return }
            if answer.account != (account?.connected ?? answer.account) { await loadAccount() }
            guard hostGeneration == generation else { return }
            apply(connections: answer.connections, limit: answer.limit)
            connectionsLoaded = true
        } catch {
            if hostGeneration == generation { self.error = error.localizedDescription }
        }
    }

    private func apply(connections: [McpConnection], limit: Int) {
        self.connections = connections; self.limit = limit
        remark()
    }
    private func upsert(_ connection: McpConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) { connections[index] = connection }
        else { connections.append(connection) }
        remark()
    }
    /// Marks the servers on show with this computer's connections.
    private func remark() {
        for index in storefront.indices { storefront[index].servers = storefront[index].servers.marking(connections) }
        results = results.marking(connections)
    }

    func connection(for server: String) -> McpConnection? { connections.first { $0.server == server } }

    func loadStorefront() async {
        guard let host else { return }
        let generation = hostGeneration
        do {
            let page: McpStorefront = try await host.request("GET", McpRoute.storefront, timeout: 60)
            guard hostGeneration == generation else { return }
            storefront = page.groups.map { group in var group = group; group.servers = group.servers.marking(connections); return group }
            storefrontNotice = page.error
            storefrontError = page.groups.isEmpty ? (page.error ?? "Smithery listed no servers.") : nil
        } catch {
            guard hostGeneration == generation else { return }
            storefrontError = error.localizedDescription
        }
    }

    /// The first page of Smithery's search for `text`.
    func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != resultsQuery { results = []; nextPage = nil; resultsLoaded = false }
        resultsQuery = text
        await load(page: 1)
    }
    func loadMore() async {
        guard !resultsLoading, resultsError == nil, let nextPage else { return }
        await load(page: nextPage)
    }
    func retrySearch() async { await load(page: failedPage) }
    private func load(page: Int) async {
        guard let host else { return }
        searchGeneration += 1
        let generation = searchGeneration, hostVersion = hostGeneration
        resultsLoading = true; resultsError = nil
        do {
            let answer: McpSearchPage = try await host.request("GET", McpRoute.discover(resultsQuery, page: page), timeout: 60)
            guard searchGeneration == generation && hostGeneration == hostVersion else { return }
            results = (answer.page <= 1 ? [] : results).appendingPage(answer.servers.marking(connections))
            nextPage = McpRoute.nextPage(after: answer.page, count: answer.servers.count, total: answer.total, pageSize: answer.pageSize)
            resultsLoading = false; resultsLoaded = true
        } catch {
            guard searchGeneration == generation && hostGeneration == hostVersion else { return }
            resultsError = error.localizedDescription; failedPage = page; resultsLoading = false
        }
    }

    /// One server with the tools Smithery lists for it, or nil when the computer changed
    /// while it loaded.
    func detail(_ id: String) async throws -> McpServerDetail? {
        guard let host else { return nil }
        let generation = hostGeneration
        var detail: McpServerDetail = try await host.request("GET", McpRoute.server(id), timeout: 60)
        guard hostGeneration == generation else { return nil }
        detail.server = [detail.server].marking(connections)[0]
        return detail
    }

    /// Adds a server to this computer. It reaches agents in their next new chat.
    @discardableResult
    func add(_ server: String) async -> McpConnection? {
        await change(server) { host in try await host.request("POST", McpRoute.connections, body: ["server": .string(server)], timeout: 120) }
    }
    /// Asks Smithery again how a server is, such as after signing in.
    func check(_ connection: McpConnection) async {
        await change(connection.id) { host in try await host.request("POST", McpRoute.check(connection.id), timeout: 120) }
    }
    /// Gives a server the settings it asked for. Returns its new status when the host took them.
    func configure(_ connection: McpConnection, values: [String: String]) async -> McpConnection? {
        await change(connection.id) { host in
            try await host.request("PATCH", McpRoute.connection(connection.id),
                                   body: ["values": .object(values.mapValues { .string($0) })], timeout: 120)
        }
    }
    /// Removes a server from Smithery and this computer. Chats lose it on their next call to it.
    func remove(_ connection: McpConnection) async {
        guard let host else { return }
        let generation = hostGeneration
        working.insert(connection.id); error = nil
        defer { if hostGeneration == generation { working.remove(connection.id) } }
        do {
            let _: [String: Bool] = try await host.request("DELETE", McpRoute.connection(connection.id), timeout: 120)
            guard hostGeneration == generation else { return }
            apply(connections: connections.filter { $0.id != connection.id }, limit: limit)
        } catch {
            if hostGeneration == generation { self.error = error.localizedDescription }
        }
    }

    @discardableResult
    private func change(_ id: String, _ work: (HostClient) async throws -> McpConnection) async -> McpConnection? {
        guard let host else { return nil }
        let generation = hostGeneration
        working.insert(id); error = nil
        defer { if hostGeneration == generation { working.remove(id) } }
        do {
            let connection = try await work(host)
            guard hostGeneration == generation else { return nil }
            upsert(connection)
            return connection
        } catch {
            if hostGeneration == generation { self.error = error.localizedDescription }
            return nil
        }
    }

    /// Loads a server's icon once, through the host, which fetches and checks it.
    func loadIcon(_ id: String) async {
        guard let host, !iconsRequested.contains(id) else { return }
        let generation = hostGeneration
        iconsRequested.insert(id)
        guard let data = try? await host.data(McpRoute.icon(id), accept: "image/png, image/jpeg", timeout: 30),
              hostGeneration == generation else { return }
        let image = await Task.detached(priority: .utility) { storeIconImage(data) }.value
        if hostGeneration == generation, let image { icons[id] = image }
    }

    func handle(_ type: String, _ event: [String: Any]) {
        guard type == "mcp.changed", host != nil, account != nil else { return }
        Task { await loadConnections(refresh: false) }
    }
}
