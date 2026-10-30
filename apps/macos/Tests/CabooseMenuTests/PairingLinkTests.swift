import Foundation
import XCTest
@testable import CabooseMenu

final class PairingLinkTests: XCTestCase {
    func testCarriesPrimaryAndRepeatedAlternatesWithoutBearer() throws {
        let link = PairingLink.make(addresses: ["https://example.ts.net/", "http://192.0.2.1:7310", "http://[2001:db8::1]:7310"], code: "ABCD1234")
        let parts = try XCTUnwrap(URLComponents(string: link))
        XCTAssertEqual(parts.scheme, "caboose")
        XCTAssertEqual(parts.host, "connect")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["host", "alt", "alt", "code"])
        XCTAssertEqual(parts.queryItems?.map(\.value), ["https://example.ts.net", "http://192.0.2.1:7310", "http://[2001:db8::1]:7310", "ABCD1234"])
    }

    func testNoLinkWithoutReachabilityOrCode() {
        XCTAssertEqual(PairingLink.make(addresses: [], code: "ABCD1234"), "")
        XCTAssertEqual(PairingLink.make(addresses: ["https://example.test"], code: ""), "")
    }

    func testServerDatesWithAndWithoutMilliseconds() {
        XCTAssertEqual(PairingLink.expiry("2026-10-29T12:00:00.000Z"), PairingLink.expiry("2026-10-29T12:00:00Z"))
        XCTAssertNotNil(PairingLink.expiry("2026-10-29T12:00:00Z"))
        XCTAssertNil(PairingLink.expiry("invalid"))
    }
}
