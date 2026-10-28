import XCTest
@testable import CabooseKit

final class ShortcutPathTests: XCTestCase {
    func testDestinationsStayRelativeAndDoNotTraverse() {
        XCTAssertEqual(ShortcutPath.destination(folder: "Downloads/Work", filename: "photo.png"), "Downloads/Work/photo.png")
        XCTAssertEqual(ShortcutPath.destination(folder: "", filename: "photo.png"), "photo.png")
        for folder in ["/tmp", "../Downloads", "Downloads/../etc", "Downloads//Work", "Downloads/"] {
            XCTAssertNil(ShortcutPath.destination(folder: folder, filename: "photo.png"))
        }
        for name in ["", ".", "..", "../photo", "a/b", "a\0b"] {
            XCTAssertNil(ShortcutPath.destination(folder: "Downloads", filename: name))
        }
    }
}
