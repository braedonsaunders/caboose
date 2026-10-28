import XCTest
import UniformTypeIdentifiers
@testable import CabooseKit

final class DropPolicyTests: XCTestCase {
    // Keep selection tests independent of the OS's type-registration service.
    private func classify(_ ids: [String]) -> DropPolicy.Representation? {
        DropPolicy.representation(for: ids) { id, parent in
            id == parent || (id == "public.png" && parent == UTType.image.identifier)
                || (id == "public.utf8-plain-text" && parent == UTType.plainText.identifier)
        }
    }
    func testFileAndImageTakePrecedenceOverText() {
        XCTAssertEqual(classify([UTType.plainText.identifier, UTType.fileURL.identifier]), .fileURL)
        XCTAssertEqual(classify([UTType.plainText.identifier, UTType.png.identifier]), .file(UTType.png.identifier))
    }
    func testTextAndUnsupportedTypes() {
        XCTAssertEqual(classify([UTType.utf8PlainText.identifier]), .text)
        XCTAssertNil(classify([UTType.url.identifier]))
        XCTAssertNil(classify([]))
    }
}
