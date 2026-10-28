import XCTest
@testable import CabooseKit

final class PhoneEventTests: XCTestCase {
    private func decode(_ json: String) -> PhoneEvent? { try? JSONDecoder().decode(PhoneEvent.self, from: Data(json.utf8)) }
    func testOpenValidation() {
        XCTAssertEqual(decode(#"{"type":"phone.open","url":"tel:123"}"#), .open(URL(string: "tel:123")!))
        XCTAssertNil(decode(#"{"type":"phone.open","url":"file:///etc/passwd"}"#))
        XCTAssertNil(decode(#"{"type":"phone.open","url":"javascript:alert(1)"}"#))
    }
    func testFilesAreBoundToStagingAndLimited() {
        let id = String(repeating: "a", count: 32)
        let json = #"{"type":"phone.share","id":"\#(id)","path":"/home/caboose/.cache/caboose/phone/files/\#(id)","name":"photo.png","size":3,"contentType":"image/png"}"#
        guard case .share(let file) = decode(json) else { return XCTFail("valid file was rejected") }
        XCTAssertEqual(file.name, "photo.png")
        XCTAssertNil(decode(json.replacingOccurrences(of: "photo.png", with: "../secret")))
        XCTAssertNil(decode(json.replacingOccurrences(of: "\"size\":3", with: "\"size\":10485761")))
        XCTAssertNil(decode(json.replacingOccurrences(of: "phone.share", with: "phone.print")))
    }
}
