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
    func testDropTypesFollowTheItems() {
        let jpeg = "public.jpeg", png = UTType.png.identifier, pdf = "com.adobe.pdf"
        let conforms: (String, String) -> Bool = { id, parent in
            id == parent || ([png, jpeg].contains(id) && parent == UTType.image.identifier)
                || (id == "public.utf8-plain-text" && parent == UTType.plainText.identifier)
                || (id == pdf && parent == UTType.data.identifier)
        }
        XCTAssertEqual(DropPolicy.dropTypes(for: [[png]], conforms: conforms), [ClipboardPolicy.png, ClipboardPolicy.uriList])
        XCTAssertEqual(DropPolicy.dropTypes(for: [[jpeg]], conforms: conforms), [ClipboardPolicy.jpeg, ClipboardPolicy.uriList])
        // Two images go as files only: one clipboard copy carries one image.
        XCTAssertEqual(DropPolicy.dropTypes(for: [[png], [jpeg]], conforms: conforms), [ClipboardPolicy.uriList])
        XCTAssertEqual(DropPolicy.dropTypes(for: [["public.utf8-plain-text"], [pdf]], conforms: conforms),
                       [ClipboardPolicy.text, ClipboardPolicy.uriList])
        XCTAssertEqual(DropPolicy.dropTypes(for: [[UTType.fileURL.identifier]], conforms: conforms), [ClipboardPolicy.uriList])
        XCTAssertEqual(DropPolicy.dropTypes(for: [["public.url"]], conforms: conforms), [])
    }
    func testTextAndUnsupportedTypes() {
        XCTAssertEqual(classify([UTType.utf8PlainText.identifier]), .text)
        XCTAssertNil(classify([UTType.url.identifier]))
        XCTAssertNil(classify([]))
    }
}
