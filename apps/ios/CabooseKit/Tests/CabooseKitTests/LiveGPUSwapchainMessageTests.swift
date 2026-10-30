import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUSwapchainMessageTests: XCTestCase {
    private let executor = Data([0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255])
    private func bytes(_ name: String) -> Data {
        let chars = Array(Self.vectors[name]!.utf8)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(decoding: chars[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
        })
    }
    func testIndependentIndexedGoldenWiresAtEverySplit() throws {
        for name in Self.vectors.keys {
            let wire = bytes(name)
            for split in 0...wire.count {
                let parser = try LiveGPUEnvelopeDecoder(executor: executor, generation: 7)
                var frames: [LiveGPUEnvelope] = []
                try parser.feed(Data(wire.prefix(split))) { frames.append($0) }
                try parser.feed(Data(wire.dropFirst(split))) { frames.append($0) }
                try parser.finish()
                XCTAssertEqual(frames.count, 1, name)
                let frame = try XCTUnwrap(frames.first)
                let message = try LiveGPUSurfaceMessage.decode(kind: frame.kind, payload: frame.payload)
                XCTAssertEqual(try message.encoded(), frame.payload, name)
                XCTAssertEqual(try frame.encoded(), wire, name)
            }
            let kind = try XCTUnwrap(LiveGPUEnvelope.Kind(rawValue: UInt16(wire[6]) | UInt16(wire[7]) << 8))
            let payload = Data(wire.dropFirst(64))
            for n in 0..<payload.count {
                XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: kind, payload: Data(payload.prefix(n))), name)
            }
            XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: kind, payload: payload + Data([0])), name)
        }
    }
    func testInvalidIndicesCountsAndResultProvenanceNeverDeliver() throws {
        let mutations: [(String, Int, UInt64, Int)] = [
            ("create",40,0,8),("create",80,0,4),("create",108,2,4),("create",112,1,4),
            ("created",60,0,4),("created",72,257,4),("create-error",48,5,8),
            ("map",64,15,8),("map",52,1,4),("acquire",56,0,8),("acquire",80,2,4),
            ("acquired",60,0,4),("acquired",76,256,4),("acquire-not-ready",72,1,4),
            ("acquire-local-timeout",56,0,4),("acquire-local-timeout",80,0,4),
            ("acquired",80,1,4),("indexed-present",72,1000001002,4),("indexed-present",88,29,8)
        ]
        for (name, offset, value, count) in mutations {
            var wire = bytes(name)
            for i in 0..<count { wire[64 + offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
            let parser = try LiveGPUEnvelopeDecoder(executor: executor, generation: 7)
            XCTAssertThrowsError(try parser.feed(wire) { _ in XCTFail("invalid control delivered: " + name) })
            XCTAssertEqual(parser.bufferedBytes, 0)
            XCTAssertThrowsError(try parser.feed(Data()) { _ in XCTFail() })
        }
    }
    func testActualAcquireAndLocalDeadlineStayDistinct() throws {
        func decode(_ name: String) throws -> LiveGPUSwapchainMessage {
            let wire = bytes(name)
            let value = try LiveGPUSurfaceMessage.decode(kind: .swapchainAcquired, payload: Data(wire.dropFirst(64)))
            guard case .swapchain(let result) = value.body else { throw LiveGPUBindingError.protocolViolation("test") }
            return result
        }
        guard case let .acquired(_, _, status, index, reason) = try decode("acquire-local-timeout") else { return XCTFail() }
        XCTAssertGreaterThan(status.nativeErrno, 0); XCTAssertNil(status.vkResult)
        XCTAssertNil(index); XCTAssertEqual(reason, .deadline)
        guard case let .acquired(_, _, actual, actualIndex, actualReason) = try decode("acquire-not-ready") else { return XCTFail() }
        XCTAssertEqual(actual.nativeErrno, 0); XCTAssertEqual(actual.vkResult, 1)
        XCTAssertNil(actualIndex); XCTAssertEqual(actualReason, .none)
        var payload = Data(bytes("acquired").dropFirst(64))
        let suboptimal: UInt32 = 1000001003
        for i in 0..<4 { payload[64+i] = UInt8(truncatingIfNeeded: suboptimal >> (i*8)) }
        guard case let .swapchain(.acquired(_, _, result, acquiredIndex, local)) =
            try LiveGPUSurfaceMessage.decode(kind: .swapchainAcquired, payload: payload).body else { return XCTFail() }
        XCTAssertEqual(result.vkResult, 1000001003); XCTAssertNotNil(acquiredIndex); XCTAssertEqual(local, .none)
    }
    func testHeaderBoundsAndForeignScopeRejectBeforeBody() throws {
        for name in Self.vectors.keys {
            let wire = bytes(name)
            for offset in [40,48] {
                var invalid = wire
                if offset == 40 { for i in 0..<8 { invalid[offset+i] = 0 } }
                else { invalid[offset] = 1 }
                let parser = try LiveGPUEnvelopeDecoder(executor: executor, generation: 7)
                XCTAssertThrowsError(try parser.feed(Data(invalid.prefix(64))) { _ in XCTFail() })
            }
        }
        for kind: LiveGPUEnvelope.Kind in [.swapchainCreate,.swapchainMap,.swapchainPresent] {
            XCTAssertThrowsError(try LiveGPUSurfaceMessage.validateLength(262080, kind: kind))
        }
    }
    // Independent complete vectors copied verbatim from parent ba47b120.
    private static let vectors: [String: String] = [
        "create": "43474c5601001900780000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000013000000000000000b00000000000000000000000000000000000000020000002c0000000000000080020000e00100000100000003000000010000000100000002000000010000000000000000000000",
        "created": "43474c5601001a00500000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000013000000000000000500000000000000000000000100000000000000000000000300000000000000",
        "create-error": "43474c5601001a00500000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000130000000000000000000000000000005f0000000000000000000000000000000000000000000000",
        "map": "43474c5601001b00500000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000003000000000000000f0000000000000011000000000000001300000000000000",
        "mapped": "43474c5601001c00400000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000000000000000000000000000000000000",
        "acquire": "43474c5601001d00580000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000017000000000000001900000000000000000000000000000000ca9a3b000000000100000000000000",
        "acquired": "43474c5601001e00580000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000017000000000000000000000001000000000000000000000001000000020000000000000000000000",
        "acquire-not-ready": "43474c5601001e00580000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000017000000000000000000000001000000010000000000000000000000000000000000000000000000",
        "acquire-local-timeout": "43474c5601001e00580000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000017000000000000006e00000000000000000000000000000000000000000000000100000000000000",
        "cancel-acquire": "43474c5601001f00380000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000005000000000000001700000000000000",
        "retire-swapchain": "43474c5601002000300000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2003000000000000000500000000000000",
        "retired-swapchain": "43474c5601002100400000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000050000000000000000000000000000000000000000000000",
        "indexed-present": "43474c5601002200600000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000005000000000000001b000000000000000d00000000000000020000000000000001000000020000001d000000000000001f00000000000000",
        "owner-revoke": "43474c5601002300280000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000",
    ]
}
