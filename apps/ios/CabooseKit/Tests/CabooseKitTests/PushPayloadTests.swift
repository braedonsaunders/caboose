import Foundation
import XCTest
@testable import CabooseKit

final class PushPayloadTests: XCTestCase {
    func testRoutingFieldsIgnoreAPNsEnvelope() throws {
        let data = #"{"aps":{"alert":"Ready"},"taskId":"task","approvalId":"approval"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(PushPayload.self, from: data), PushPayload(taskId: "task", approvalId: "approval"))
    }
    func testWindowAndInvalidField() throws {
        XCTAssertEqual(try JSONDecoder().decode(PushPayload.self, from: Data(#"{"windowId":42}"#.utf8)), PushPayload(windowId: 42))
        XCTAssertThrowsError(try JSONDecoder().decode(PushPayload.self, from: Data(#"{"windowId":"42"}"#.utf8)))
    }
}
