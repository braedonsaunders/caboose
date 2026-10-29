import Foundation
import Testing
@testable import CabooseKit

@Suite @MainActor struct WebviewOriginTests {
    @Test func originsPersistAndAreSeparate() throws {
        let name = "CabooseOriginTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try #require(WebviewOriginStore(defaults: defaults).origin(computer: "one", app: "notes"))
        let again = try #require(WebviewOriginStore(defaults: defaults).origin(computer: "one", app: "notes"))
        let other = try #require(WebviewOriginStore(defaults: defaults).origin(computer: "one", app: "tasks"))
        let computer = try #require(WebviewOriginStore(defaults: defaults).origin(computer: "two", app: "notes"))
        #expect(first == again)
        #expect(Set([first.port, other.port, computer.port]).count == 3)
        #expect(Set([first.token, other.token, computer.token]).count == 3)
    }
    @Test func corruptRegistryDoesNotAllocateANewOrigin() throws {
        let name = "CabooseOriginTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("broken", forKey: "Caboose.WebviewOrigins.v1")
        #expect(WebviewOriginStore(defaults: defaults).origin(computer: "one", app: "notes") == nil)
    }

}
