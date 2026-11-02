import Foundation
import Testing
@testable import CabooseKit

/// Where a computer's routes are for each kind of sign-in: unscoped for a sign-in bound to
/// one computer and the owner token, `/v1/computers/<id>/…` for a host sign-in.
@Suite struct ComputerRouteTests {
    let scoped = ComputerRoute(computer: "c-0123456789")

    @Test func unscopedRoutesAreUnchanged() {
        for path in ["/v1/session", "/v1/display", "/v1/fs/list?path=%2F", "/v1/computer/settings"] {
            #expect(ComputerRoute.unscoped.path(path) == path)
        }
        #expect(ComputerRoute(computer: "") == .unscoped)
    }

    @Test func computerRoutesAreScoped() {
        #expect(scoped.path("/v1/session") == "/v1/computers/c-0123456789/session")
        #expect(scoped.path("/v1/session/park") == "/v1/computers/c-0123456789/session/park")
        #expect(scoped.path("/v1/computer") == "/v1/computers/c-0123456789/computer")
        #expect(scoped.path("/v1/computer/settings") == "/v1/computers/c-0123456789/computer/settings")
        #expect(scoped.path("/v1/fs/list?path=%2Fhome") == "/v1/computers/c-0123456789/fs/list?path=%2Fhome")
        #expect(scoped.path("/v1/display") == "/v1/computers/c-0123456789/display")
        #expect(ComputerRoute(computer: "owner").path("/v1/apps") == "/v1/computers/owner/apps")
    }

    @Test func hostRoutesAreNeverScoped() {
        for path in ["/v1/computers", "/v1/computers?x=1", "/v1/computers/c-1/boot", "/v1/host/settings", "/v1/host",
                     "/v1/health", "/v1/pair"] {
            #expect(ComputerRoute.isHostRoute(path))
            #expect(scoped.path(path) == path)
        }
        #expect(!ComputerRoute.isHostRoute("/v1/computer"))
        #expect(!ComputerRoute.isHostRoute("/v1/hosted"))
        // Mapping an already scoped path again changes nothing.
        #expect(scoped.path(scoped.path("/v1/session")) == "/v1/computers/c-0123456789/session")
    }

    @Test func pathsOutsideTheAPIAreUnchanged() {
        #expect(scoped.path("/health") == "/health")
        #expect(scoped.path("v1/session") == "v1/session")
    }

    @Test func idsAreOneSegment() {
        #expect(ComputerRoute(computer: "a/b?c").path("/v1/session") == "/v1/computers/a%2Fb%3Fc/session")
    }

    @Test func urlsKeepTheHostPrefix() {
        let base = URL(string: "https://box.example/caboose/")!
        #expect(scoped.url(base: base, "/v1/session").absoluteString == "https://box.example/caboose/v1/computers/c-0123456789/session")
        #expect(ComputerRoute.unscoped.url(base: base, "/v1/session").absoluteString == "https://box.example/caboose/v1/session")
        #expect(scoped.socketURL(base: URL(string: "https://box.example")!, "/v1/display").absoluteString
            == "wss://box.example/v1/computers/c-0123456789/display")
        #expect(scoped.socketURL(base: URL(string: "http://10.0.0.2:7310")!, "/v1/gpu").absoluteString
            == "ws://10.0.0.2:7310/v1/computers/c-0123456789/gpu")
    }

    @Test func splitFindsTheScope() throws {
        let plain = try #require(ComputerRoute.split("/caboose/v1/display"))
        #expect(plain.prefix == "/caboose" && plain.route == .unscoped && plain.path == "/v1/display")
        let computer = try #require(ComputerRoute.split("/caboose/v1/computers/c-1/display"))
        #expect(computer.prefix == "/caboose" && computer.route == ComputerRoute(computer: "c-1") && computer.path == "/v1/display")
        let encoded = try #require(ComputerRoute.split("/v1/computers/a%2Fb/display"))
        #expect(encoded.route.computer == "a/b" && encoded.prefix == "")
        #expect(ComputerRoute.split("/display") == nil)
    }

    @Test func gameFilesFollowAScopedDisplay() throws {
        let access = try #require(GameHostAccess(displayURL: URL(string: "wss://box.example/v1/computers/c-1/display")!, token: "tok"))
        #expect(access.baseURL.absoluteString == "https://box.example")
        #expect(access.route == ComputerRoute(computer: "c-1"))
        #expect(access.fileURL("stat", path: "a b").absoluteString == "https://box.example/v1/computers/c-1/fs/stat?path=a%20b")
        // One host sign-in reaches several computers: their game caches stay apart.
        let other = try #require(GameHostAccess(displayURL: URL(string: "wss://box.example/v1/computers/c-2/display")!, token: "tok"))
        #expect(access.computerKey != other.computerKey)
        // An unscoped display keeps the key it always had.
        let unscoped = try #require(GameHostAccess(displayURL: URL(string: "wss://box.example/v1/display")!, token: "tok"))
        #expect(unscoped.computerKey == GameHostAccess(baseURL: URL(string: "https://box.example")!, token: "tok").computerKey)
        #expect(unscoped.fileURL("stat", path: "x").absoluteString == "https://box.example/v1/fs/stat?path=x")
    }

    @Test func terminalAndGPUSocketsAreScoped() throws {
        let terminal = TerminalProtocol.url(base: URL(string: "https://box.example")!, route: scoped, columns: 80, rows: 24,
                                            session: nil, offset: nil, wake: false)
        #expect(terminal.absoluteString == "wss://box.example/v1/computers/c-0123456789/terminal?cols=80&rows=24")
        let gpu = try LiveGPUConnection.makeRequest(hostURL: URL(string: "https://box.example")!, phoneToken: "phone", route: scoped)
        #expect(gpu.url?.absoluteString == "wss://box.example/v1/computers/c-0123456789/gpu")
    }
}
