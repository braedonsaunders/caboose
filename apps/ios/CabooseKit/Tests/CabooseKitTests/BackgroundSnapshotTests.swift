import Foundation
import XCTest
@testable import CabooseKit

final class BackgroundSnapshotTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSelectedPictureSurvivesCacheRemovalAndReload() throws {
        let cache = root.appendingPathComponent("Caches/Wallpapers")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: cache.appendingPathComponent("29.jpg"))
        let file = root.appendingPathComponent("Application Support/Background/library.plist")
        try BackgroundSnapshot(id: 29, image: bytes).save(to: file)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Caches"))
        XCTAssertEqual(BackgroundSnapshot.load(from: file, choice: .photo(29))?.image, bytes)
        XCTAssertEqual(BackgroundSnapshot.load(from: file, choice: .rotating)?.id, 29)
    }

    func testNeverRestoresAnotherSelectionOrOverridesCustomAndGradient() throws {
        let file = root.appendingPathComponent("library.plist")
        try BackgroundSnapshot(id: 29, image: Data([1])).save(to: file)
        XCTAssertNil(BackgroundSnapshot.load(from: file, choice: .photo(110)))
        XCTAssertNil(BackgroundSnapshot.load(from: file, choice: .custom))
        XCTAssertNil(BackgroundSnapshot.load(from: file, choice: .gradient))
    }

    func testFailedReplacementKeepsPreviousPictureAndSuccessfulReplacementCommitsIdentity() throws {
        let file = root.appendingPathComponent("library.plist")
        let first = BackgroundSnapshot(id: 29, image: Data([1]))
        try first.save(to: file)
        XCTAssertThrowsError(try BackgroundSnapshot(id: 110, image: Data()).save(to: file))
        XCTAssertEqual(BackgroundSnapshot.load(from: file, choice: .photo(29)), first)
        let replacement = BackgroundSnapshot(id: 110, image: Data([2]))
        try replacement.save(to: file)
        XCTAssertEqual(BackgroundSnapshot.load(from: file, choice: .photo(110)), replacement)
        XCTAssertNil(BackgroundSnapshot.load(from: file, choice: .photo(29)))
    }

    func testCorruptSnapshotDoesNotPreventRecovery() throws {
        let file = root.appendingPathComponent("library.plist")
        try Data("broken".utf8).write(to: file)
        XCTAssertNil(BackgroundSnapshot.load(from: file, choice: .rotating))
        try BackgroundSnapshot(id: 29, image: Data([1])).save(to: file)
        XCTAssertNotNil(BackgroundSnapshot.load(from: file, choice: .photo(29)))
    }
}
