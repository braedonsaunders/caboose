import Foundation
import XCTest
@testable import CabooseKit

/// Algorithm 2 (zstd-stream): one zstd stream per session, a record per DATA envelope, each
/// ending at a flush point. The vectors are the broker's (Fixtures/README.md).
final class LiveGPUZstdTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/live-zstd-stream-vectors.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testSequenceDecodesInOrderOnOneStream() throws {
        let sequence = try vectors()["sequence"] as! [[String: String]]
        XCTAssertEqual(sequence.count, 5)
        let stream = try LiveGPUZstdStream()
        for vector in sequence {
            XCTAssertEqual(try stream.decode(hex(vector["wire_hex"]!)), hex(vector["decoded_hex"]!), vector["name"]!)
        }
    }

    func testEveryInvalidRecordFailsAsTheFirstOfAStream() throws {
        let invalid = try vectors()["invalid"] as! [[String: String]]
        XCTAssertEqual(invalid.count, 11)
        for vector in invalid {
            XCTAssertThrowsError(try LiveGPUZstdStream().decode(hex(vector["wire_hex"]!)), vector["name"]!)
        }
    }

    func testARecordAfterAFailureOrOutOfOrderDoesNotDecode() throws {
        let sequence = try vectors()["sequence"] as! [[String: String]]
        // A later record refers back into the stream before it.
        XCTAssertThrowsError(try LiveGPUZstdStream().decode(hex(sequence[1]["wire_hex"]!)))
        // A failed record ends the stream: even a good one after it is refused.
        let stream = try LiveGPUZstdStream()
        let trailing = try (vectors()["invalid"] as! [[String: String]]).first { $0["name"] == "trailing-byte" }!
        XCTAssertThrowsError(try stream.decode(hex(trailing["wire_hex"]!)))
        XCTAssertThrowsError(try stream.decode(hex(sequence[0]["wire_hex"]!)))
    }

    func testOnlyTheTwoOffersAreAccepted() {
        XCTAssertEqual(LiveGPUCompression.algorithm(ofOffer: LiveGPUCompression.offer(.deflate)), .deflate)
        XCTAssertEqual(LiveGPUCompression.algorithm(ofOffer: LiveGPUCompression.offer(.zstdStream)), .zstdStream)
        // The broker's invalid control vectors: {3, 65600} and {2, 65601}.
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([3, 0, 0, 0, 0x40, 0, 1, 0])))
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([2, 0, 0, 0, 0x41, 0, 1, 0])))
    }

    private func hex(_ text: String) -> Data {
        let chars = Array(text.utf8)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(bytes: chars[$0..<$0 + 2], encoding: .utf8)!, radix: 16)! })
    }
}
