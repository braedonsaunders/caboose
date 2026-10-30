import Foundation
import Testing
@testable import CabooseKit

struct AppListCacheTests {
    @Test func pairingsStaySeparateAndAnEmptyRefreshReplacesOldApps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppListCache(directory: root)
        let old = Data("[{\"id\":\"browser\"}]".utf8)
        try await cache.write(old, pairing: "one")
        #expect(await cache.read(pairing: "one") == old)
        #expect(await cache.read(pairing: "two") == nil)
        try await cache.write(Data("[]".utf8), pairing: "one")
        #expect(await cache.read(pairing: "one") == Data("[]".utf8))
        await cache.remove(pairing: "one")
        #expect(await cache.read(pairing: "one") == nil)
    }

    @Test func oversizedRefreshKeepsTheLastSuccessfulSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppListCache(directory: root)
        let original = Data("[]".utf8)
        try await cache.write(original, pairing: "../outside")
        await #expect(throws: AppListCache.Failure.self) {
            try await cache.write(Data(count: AppListCache.byteLimit + 1), pairing: "../outside")
        }
        #expect(await cache.read(pairing: "../outside") == original)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(files[0].deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        try Data(count: AppListCache.byteLimit + 1).write(to: files[0])
        #expect(await cache.read(pairing: "../outside") == nil)
    }
}
