import XCTest
@testable import CabooseKit

final class RecentFilesTests: XCTestCase {
    func testNestedFilesAreOrderedByModificationThenPath() async throws {
        let listings: [String: [FileListingEntry]] = [
            "": [.init(name: "Documents", isDirectory: true, mtime: 1), .init(name: "old", isDirectory: false, mtime: 1)],
            "Documents": [.init(name: "nested", isDirectory: true, mtime: 1), .init(name: "b", isDirectory: false, mtime: 3)],
            "Documents/nested": [.init(name: "a", isDirectory: false, mtime: 3)]
        ]
        let files = try await RecentFiles.scan { listings[$0] ?? [] }
        XCTAssertEqual(files.map(\.path), ["Documents/b", "Documents/nested/a", "old"])
    }
    func testFailureDoesNotReturnPartialListing() async {
        enum Offline: Error { case disconnected }
        do {
            _ = try await RecentFiles.scan { path in
                if path.isEmpty { return [.init(name: "child", isDirectory: true, mtime: 1)] }
                throw Offline.disconnected
            }
            XCTFail("expected an error")
        } catch { XCTAssertTrue(error is Offline) }
    }
}
