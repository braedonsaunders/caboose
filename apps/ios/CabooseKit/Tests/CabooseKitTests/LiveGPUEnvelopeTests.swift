import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUEnvelopeTests: XCTestCase {
    private let identity = Data([0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255])
    func testFrozenGoldenVectors() throws {
        for (index, wire) in Self.vectors.enumerated() {
            let bytes = hex(wire)
            let decoder = try LiveGPUEnvelopeDecoder(executor: identity, generation: 7)
            var result: [LiveGPUEnvelope] = []
            // Every byte boundary, including empty control payloads.
            for byte in bytes { try decoder.feed(Data([byte])) { result.append($0) } }
            try decoder.finish()
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].kind.rawValue, UInt16(index + 1))
            XCTAssertEqual(try result[0].encoded(), bytes)
            if index < 2 { XCTAssertEqual(result[0].payload, LiveGPUEnvelope.hello) }
        }
    }
    func testFragmentationCoalescingAndMaximumPayload() throws {
        let decoder = try LiveGPUEnvelopeDecoder()
        let hello = hex(Self.vectors[0])
        let data = try LiveGPUEnvelope(kind: .data, executor: identity, generation: 7, process: 1, stream: 1,
            sequence: 2, payload: Data(repeating: 73, count: LiveGPUEnvelope.maxPayload)).encoded()
        let combined = hello + data
        var frames: [LiveGPUEnvelope] = []
        for offset in stride(from: 0, to: combined.count, by: 997) {
            try decoder.feed(combined.subdata(in: offset..<min(offset + 997, combined.count))) { frames.append($0) }
            XCTAssertLessThanOrEqual(decoder.bufferedBytes, LiveGPUEnvelope.maxPayload)
        }
        try decoder.finish()
        XCTAssertEqual(frames.count, 2); XCTAssertEqual(frames[1].payload.count, LiveGPUEnvelope.maxPayload)
    }
    func testMalformedHeadersIdentitySequenceAndPoisoning() throws {
        for (offset, replacement) in [(0, 0), (4, 2), (6, 99), (8, 49), (12, 1), (32, 0), (56, 0)] {
            let decoder = try LiveGPUEnvelopeDecoder()
            var bytes = hex(Self.vectors[0]); bytes[offset] = UInt8(replacement)
            XCTAssertThrowsError(try decoder.feed(bytes) { _ in XCTFail() })
            XCTAssertThrowsError(try decoder.feed(hex(Self.vectors[0])) { _ in XCTFail() })
            XCTAssertEqual(decoder.bufferedBytes, 0)
        }
        for offset in [16, 32, 56] {
            let decoder = try LiveGPUEnvelopeDecoder()
            try decoder.feed(hex(Self.vectors[0])) { _ in }
            var second = hex(Self.vectors[2]); second[56] = 2
            second[offset] ^= 1
            XCTAssertThrowsError(try decoder.feed(second) { _ in XCTFail() })
        }
    }
    func testTruncationOversizeAndDeliveryFailure() throws {
        let bytes = hex(Self.vectors[0])
        for size in 1..<bytes.count {
            let decoder = try LiveGPUEnvelopeDecoder()
            try decoder.feed(bytes.prefix(size)) { _ in XCTFail() }
            XCTAssertThrowsError(try decoder.finish())
        }
        let decoder = try LiveGPUEnvelopeDecoder()
        XCTAssertThrowsError(try decoder.feed(Data(repeating: 0, count: 262145)) { _ in })
        let rejected = try LiveGPUEnvelopeDecoder()
        XCTAssertThrowsError(try rejected.feed(bytes) { _ in throw LiveGPUError.closed })
        XCTAssertThrowsError(try rejected.feed(bytes) { _ in })
    }
    private func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { i in
            let start = value.index(value.startIndex, offsetBy: i)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    // Verbatim wires from parent a413b85e (live v4/0x70, including EXECUTOR_DRAIN).
    static let vectors: [String] = [
        "43474c5601000100300000000000000000112233445566778899aabbccddeeff07000000000000000000000000000000000000000000000001000000000000004342474c52454631040000007000000020d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0",
        "43474c5601000200300000000000000000112233445566778899aabbccddeeff07000000000000000000000000000000000000000000000001000000000000004342474c52454631040000007000000020d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0",
        "43474c5601000300000000000000000000112233445566778899aabbccddeeff07000000000000000b0000000000000000000000000000000100000000000000",
        "43474c5601000400000000000000000000112233445566778899aabbccddeeff07000000000000000b0000000000000000000000000000000100000000000000",
        "43474c5601000500000000000000000000112233445566778899aabbccddeeff07000000000000000b000000000000000d000000000000000100000000000000",
        "43474c5601000600000000000000000000112233445566778899aabbccddeeff07000000000000000b000000000000000d000000000000000100000000000000",
        "43474c5601000700090000000000000000112233445566778899aabbccddeeff07000000000000000b000000000000000d00000000000000010000000000000000ff7061796c6f6164",
        "43474c5601000800000000000000000000112233445566778899aabbccddeeff07000000000000000b000000000000000d000000000000000100000000000000",
        "43474c5601000900000000000000000000112233445566778899aabbccddeeff07000000000000000b0000000000000000000000000000000100000000000000",
        "43474c5601000a00000000000000000000112233445566778899aabbccddeeff07000000000000000b0000000000000000000000000000000100000000000000",
        "43474c5601000b00000000000000000000112233445566778899aabbccddeeff0700000000000000000000000000000000000000000000000100000000000000",
        "43474c5601000c00000000000000000000112233445566778899aabbccddeeff0700000000000000000000000000000000000000000000000100000000000000",
        "43474c5601000d00000000000000000000112233445566778899aabbccddeeff0700000000000000000000000000000000000000000000000100000000000000",
    ]
}
