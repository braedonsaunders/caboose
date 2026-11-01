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
        let stream = try LiveGPUZstdStream(windowLog: 27)
        for vector in sequence {
            XCTAssertEqual(try stream.decode(hex(vector["wire_hex"]!)), hex(vector["decoded_hex"]!), vector["name"]!)
        }
    }

    func testEveryInvalidRecordFailsAsTheFirstOfAStream() throws {
        let invalid = try vectors()["invalid"] as! [[String: String]]
        XCTAssertEqual(invalid.count, 11)
        for vector in invalid {
            XCTAssertThrowsError(try LiveGPUZstdStream(windowLog: 27).decode(hex(vector["wire_hex"]!)), vector["name"]!)
        }
    }

    func testARecordAfterAFailureOrOutOfOrderDoesNotDecode() throws {
        let sequence = try vectors()["sequence"] as! [[String: String]]
        // A later record refers back into the stream before it.
        XCTAssertThrowsError(try LiveGPUZstdStream(windowLog: 27).decode(hex(sequence[1]["wire_hex"]!)))
        // A failed record ends the stream: even a good one after it is refused.
        let stream = try LiveGPUZstdStream(windowLog: 27)
        let trailing = try (vectors()["invalid"] as! [[String: String]]).first { $0["name"] == "trailing-byte" }!
        XCTAssertThrowsError(try stream.decode(hex(trailing["wire_hex"]!)))
        XCTAssertThrowsError(try stream.decode(hex(sequence[0]["wire_hex"]!)))
    }

    func testOnlyTheTwoOffersAreAccepted() {
        XCTAssertEqual(LiveGPUCompression.algorithm(ofOffer: LiveGPUCompression.offer(.deflate)), .deflate)
        XCTAssertEqual(LiveGPUCompression.offer(.deflate).count, 8)
        XCTAssertEqual(LiveGPUCompression.configuration(ofOffer: LiveGPUCompression.offer(.zstdStream))?.windowLog, 27)
        // {3, 65600}, {2, 65601}, an algorithm 2 offer without its window, algorithm 1 with one.
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([3, 0, 0, 0, 0x40, 0, 1, 0])))
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([2, 0, 0, 0, 0x41, 0, 1, 0])))
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([2, 0, 0, 0, 0x40, 0, 1, 0])))
        XCTAssertNil(LiveGPUCompression.algorithm(ofOffer: Data([1, 0, 0, 0, 0x40, 0, 1, 0, 27, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testTheWindowTakenIsTheBrokersVectorsAndNeverMoreThanOffered() throws {
        let transport = try vectors()["transport"] as! [String: [[String: Any]]]
        for vector in transport["valid"]! {
            let log = UInt32(vector["window_log"] as! Int)
            let answer = try XCTUnwrap(LiveGPUCompression.answer(toOffer: hex(vector["config_hex"] as! String), windowLog: log))
            XCTAssertEqual(answer.payload, hex(vector["ready_hex"] as! String))
            XCTAssertEqual(answer.windowLog, log)
        }
        // The phone never answers more than offered, nor a window below 1 MiB.
        let offer = LiveGPUCompression.offer(.zstdStream, windowLog: 27)
        XCTAssertEqual(LiveGPUCompression.answer(toOffer: offer, windowLog: 28)?.windowLog, 27)
        XCTAssertNil(LiveGPUCompression.answer(toOffer: offer, windowLog: 19))
        for vector in transport["invalid"]! {
            let ready = hex(vector["ready_hex"] as! String)
            let name = vector["name"] as! String
            switch name {
            case "larger-window", "algorithm-1":
                // Valid payloads in themselves, never the answer to this offer.
                XCTAssertNotEqual(LiveGPUCompression.answer(toOffer: hex(vector["config_hex"] as! String), windowLog: 30)?.payload, ready, name)
            default:
                XCTAssertNil(LiveGPUCompression.configuration(ofOffer: ready), name)
            }
        }
        XCTAssertEqual(LiveGPUCompression.preferredWindowLog(available: 4 << 30), 27)
        XCTAssertEqual(LiveGPUCompression.preferredWindowLog(available: 1 << 30), 26)
        XCTAssertEqual(LiveGPUCompression.preferredWindowLog(available: 256 << 20), 23)
        XCTAssertThrowsError(try LiveGPUZstdStream(windowLog: 31))
    }

    private func hex(_ text: String) -> Data {
        let chars = Array(text.utf8)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(bytes: chars[$0..<$0 + 2], encoding: .utf8)!, radix: 16)! })
    }
}
