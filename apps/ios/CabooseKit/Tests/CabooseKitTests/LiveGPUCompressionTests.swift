import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUCompressionTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        let chars = Array(text.utf8)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(bytes: chars[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
        })
    }
    private func vectors() throws -> [String: [[String: Any]]] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("guest/gpu/broker/live-compression-vectors.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return object.compactMapValues { $0 as? [[String: Any]] }
    }
    func testIndependentPythonRecordsDecodeExactlyAndRemainBounded() throws {
        for item in try vectors()["valid"]! {
            let wire = hex(item["wire_hex"] as! String), expected = hex(item["decoded_hex"] as! String)
            XCTAssertEqual(try LiveGPUCompression.decode(wire), expected, item["name"] as! String)
            let charge = try LiveGPUCompression.admissionCharge(wire)
            XCTAssertEqual(charge, wire.count + expected.count + 1)
            XCTAssertLessThanOrEqual(charge, LiveGPUBudget.messageLimit)
            let budget = LiveGPUBudget()
            let admitted = min(LiveGPUBudget.countLimit, LiveGPUBudget.byteLimit / charge)
            for _ in 0..<admitted { XCTAssertNil(budget.admit(charge)) }
            XCTAssertEqual(budget.admit(charge), .overflow)
            for _ in 0..<admitted { budget.release(charge) }
            XCTAssertEqual(budget.retained.bytes, 0)
        }
    }
    func testStrictEOSSizeInnerTypeAndNoConcatenation() throws {
        for item in try vectors()["invalid"]! {
            XCTAssertThrowsError(try LiveGPUCompression.decode(hex(item["wire_hex"] as! String)), item["name"] as! String)
        }
        for item in try vectors()["valid"]! {
            let wire = hex(item["wire_hex"] as! String)
            for length in 0..<wire.count {
                XCTAssertThrowsError(try LiveGPUCompression.decode(Data(wire.prefix(length))))
            }
        }
    }
    func testNegotiationGoldensAtEverySplitAndScopeRejection() throws {
        for item in try vectors()["controls"]! {
            let wire = hex(item["wire_hex"] as! String)
            for split in 0...wire.count {
                let decoder = try LiveGPUEnvelopeDecoder(executor: Data(1...16), generation: 1)
                var frames: [LiveGPUEnvelope] = []
                try decoder.feed(Data(wire.prefix(split))) { frames.append($0) }
                try decoder.feed(Data(wire.dropFirst(split))) { frames.append($0) }
                try decoder.finish()
                XCTAssertEqual(frames.count, 1)
                XCTAssertEqual(frames.first?.payload, LiveGPUCompression.offer)
            }
            for offset in [12, 40, 48, 64, 68] {
                var bad = wire; bad[offset] ^= 1
                let decoder = try LiveGPUEnvelopeDecoder(executor: Data(1...16), generation: 1)
                XCTAssertThrowsError(try decoder.feed(bad) { _ in XCTFail("invalid control delivered") })
            }
        }
    }
}
