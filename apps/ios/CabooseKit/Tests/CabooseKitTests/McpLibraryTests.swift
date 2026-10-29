import Foundation
import Testing
@testable import CabooseKit

/// The MCP Library's routes, the host's answers, and the setup form a server asks for.
struct McpLibraryTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func aQualifiedNameKeepsItsOneSlashAsASeparator() {
        #expect(McpRoute.server("brave") == "/v1/mcp/servers/brave")
        #expect(McpRoute.server("upstash/context7-mcp") == "/v1/mcp/servers/upstash/context7-mcp")
        #expect(McpRoute.server("@smithery/hello world") == "/v1/mcp/servers/@smithery/hello%20world")
    }

    @Test func aSegmentCannotAddAQueryOrAnEscape() {
        #expect(McpRoute.server("a?b#c/d%2Fe") == "/v1/mcp/servers/a%3Fb%23c/d%252Fe")
        #expect(McpRoute.connection("cb-0123456789ab-0123456789abcdef") == "/v1/mcp/connections/cb-0123456789ab-0123456789abcdef")
        #expect(McpRoute.check("x/y") == "/v1/mcp/connections/x%2Fy/check")
        #expect(McpRoute.icon("0f0f") == "/v1/mcp/icons/0f0f")
    }

    @Test func searchesAreQueryValuesOnOneBasedPages() {
        #expect(McpRoute.discover("") == "/v1/mcp/discover?q=&page=1")
        #expect(McpRoute.discover("  web & search/c++  ", page: 3) == "/v1/mcp/discover?q=web%20%26%20search%2Fc%2B%2B&page=3")
        #expect(McpRoute.discover("x", page: 0) == "/v1/mcp/discover?q=x&page=1")
        #expect(McpRoute.connections(refresh: true) == "/v1/mcp/connections?refresh=1")
        #expect(McpRoute.connections(refresh: false) == "/v1/mcp/connections")
    }

    @Test func pagingStopsAtTheTotalAnEmptyPageOrTheLastPage() {
        #expect(McpRoute.nextPage(after: 1, count: 40, total: 100, pageSize: 40) == 2)
        #expect(McpRoute.nextPage(after: 3, count: 20, total: 100, pageSize: 40) == nil)
        #expect(McpRoute.nextPage(after: 2, count: 40, total: 80, pageSize: 40) == nil)
        #expect(McpRoute.nextPage(after: 2, count: 0, total: 1000, pageSize: 40) == nil)
        #expect(McpRoute.nextPage(after: 250, count: 40, total: 100_000, pageSize: 40) == nil)
    }

    @Test func serversDecodeWithAndWithoutAConnection() throws {
        let detail = try decode(McpServerDetail.self, """
        {"id":"upstash/context7-mcp","name":"Context7","description":"Docs for any library.","uses":120345,"verified":true,
         "homepage":"https://context7.com","iconId":"0123456789abcdef0123456789abcdef","connection":null,
         "tools":[{"name":"resolve-library-id","description":"Finds a library."}]}
        """)
        #expect(detail.server.id == "upstash/context7-mcp")
        #expect(detail.server.connection == nil)
        #expect(detail.server.verified)
        #expect(detail.server.homepageURL?.host == "context7.com")
        #expect(detail.tools.map(\.name) == ["resolve-library-id"])
        let front = try decode(McpStorefront.self, """
        {"groups":[{"id":"popular","title":"Popular","note":"Ranked by uses on Smithery","servers":[
          {"id":"brave","name":"Brave Search","description":"Search the web.","uses":9,"verified":false,"homepage":null,"iconId":null,"connection":"cb-0123456789ab-0123456789abcdef"}]}],
         "error":null}
        """)
        #expect(front.groups.first?.note == "Ranked by uses on Smithery")
        #expect(front.groups.first?.servers.first?.connection == "cb-0123456789ab-0123456789abcdef")
    }

    @Test func everyStatusDecodes() throws {
        let list = try decode(McpConnections.self, """
        {"account":true,"limit":20,"connections":[
          {"id":"a","server":"brave","name":"Brave","iconId":null,"addedAt":"2026-10-01T00:00:00Z","status":{"state":"connected","tools":6}},
          {"id":"b","server":"gmail","name":"Gmail","iconId":null,"addedAt":"","status":{"state":"needs-sign-in","setupUrl":"https://auth.smithery.ai/x"}},
          {"id":"c","server":"exa","name":"Exa","iconId":null,"addedAt":"","status":{"state":"needs-setup","setupUrl":null,
            "fields":[{"key":"exaApiKey","where":"header","label":"Exa API key","description":"From exa.ai","required":true}]}},
          {"id":"d","server":"x","name":"X","iconId":null,"addedAt":"","status":{"state":"failed","message":"The server disconnected."}},
          {"id":"e","server":"y","name":"Y","iconId":null,"addedAt":"","status":{"state":"checking"}}]}
        """)
        #expect(list.limit == 20)
        let statuses = list.connections.map(\.status)
        #expect(statuses[0] == .connected(tools: 6))
        #expect(statuses[1] == .needsSignIn(URL(string: "https://auth.smithery.ai/x")!))
        #expect(statuses[2] == .needsSetup(fields: [McpSetupField(key: "exaApiKey", location: .header, label: "Exa API key", description: "From exa.ai", required: true)], setupURL: nil))
        #expect(statuses[3] == .failed("The server disconnected."))
        #expect(statuses[4] == .checking)
    }

    @Test func onlySmitheryPagesOpenForSignIn() throws {
        #expect(McpConnectionStatus.smitheryPage("https://smithery.ai/connect") != nil)
        #expect(McpConnectionStatus.smitheryPage("https://auth.smithery.ai/x") != nil)
        #expect(McpConnectionStatus.smitheryPage("http://smithery.ai/connect") == nil)
        #expect(McpConnectionStatus.smitheryPage("https://smithery.ai.example.com/") == nil)
        #expect(McpConnectionStatus.smitheryPage("https://evilsmithery.ai/") == nil)
        #expect(McpConnectionStatus.smitheryPage("https://user:pw@smithery.ai/") == nil)
        let status = try decode(McpConnectionStatus.self, #"{"state":"needs-sign-in","setupUrl":"https://example.com/login"}"#)
        guard case .failed = status else { Issue.record("an outside sign-in page must not open"); return }
        let unknown = try decode(McpConnectionStatus.self, #"{"state":"paused"}"#)
        guard case .failed = unknown else { Issue.record("an unknown state reads as failed"); return }
    }

    @Test func theSetupFormNeedsEveryRequiredSetting() {
        var form = McpSetupForm(fields: [
            McpSetupField(key: "apiKey", location: .header, label: "API key", required: true),
            McpSetupField(key: "region", location: .query, label: "Region", required: false),
        ])
        #expect(!form.isComplete)
        #expect(form.missing.map(\.key) == ["apiKey"])
        #expect(form.submission == nil)
        form.values["apiKey"] = "   \n"
        #expect(form.submission == nil)
        form.values["apiKey"] = " sk-123\n"
        #expect(form.submission == ["apiKey": "sk-123"])
        form.values["region"] = "eu"
        #expect(form.submission == ["apiKey": "sk-123", "region": "eu"])
    }

    @Test func theSetupFormSendsOnlyDeclaredKeys() {
        var form = McpSetupForm(fields: [McpSetupField(key: "token", location: .header, label: "Token", required: false)])
        form.values = ["token": "t", "other": "x", "": "y"]
        #expect(form.isComplete)
        #expect(form.submission == ["token": "t"])
        form.values = [:]
        #expect(form.submission == [:])
    }

    @Test func connectionsMarkTheServersTheyAdded() {
        let servers = [
            McpServer(id: "brave", name: "Brave", description: "d"),
            McpServer(id: "exa", name: "Exa", description: "d", connection: "stale"),
        ]
        let marked = servers.marking([McpConnection(id: "cb-1", server: "brave", name: "Brave", status: .checking)])
        #expect(marked.map(\.connection) == ["cb-1", nil])
    }
}
