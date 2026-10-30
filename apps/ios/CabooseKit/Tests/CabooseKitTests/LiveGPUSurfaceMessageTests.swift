import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUSurfaceMessageTests: XCTestCase {
    private let identity = LiveGPUSurfaceIdentity(epoch: Data(1...16), grant: Data(17...32), generation: 7)
    private let ok = LiveGPUSurfaceStatus(nativeErrno: 0, vkResult: 0)
    private var common: Data { Data(1...32) + le(UInt64(7)) }
    private func le<T: FixedWidthInteger>(_ value: T) -> Data {
        Data((0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func status(_ error: Int32, _ result: Int32?) -> Data {
        le(error) + le(UInt32(result == nil ? 0 : 1)) + le(result ?? 0) + le(UInt32(0))
    }
    private func replacing(_ bytes: Data, at: Int, with value: UInt32) -> Data {
        var copy = bytes; copy.replaceSubrange(at..<(at + 4), with: le(value)); return copy
    }
    private var capsPayload: Data {
        // Independent wire construction: surface caps have 13 scalar fields then 3 counts.
        var bytes = common + le(UInt64(41)) + status(0, 0)
        for v: UInt32 in [2, 0, UInt32.max, UInt32.max, 1, 1, 4096, 4096, 1, 1, 1, 1, 0x12] { bytes += le(v) }
        for v: UInt32 in [1, 2, 1, 44, 0, 2, 3, 5, 3, 2, 1] { bytes += le(v) }
        return bytes
    }
    private var presentPayload: Data {
        var bytes = common
        for v: UInt64 in [8, 9, 10, 11] { bytes += le(v) }
        for v: UInt32 in [44, 640, 480, 1, 5, 2] { bytes += le(v) }
        bytes += le(UInt64(12)); bytes += le(UInt64(13))
        return bytes
    }

    func testInitialExtentRequestUsesZeroPairOnly() throws {
        let identity = LiveGPUSurfaceIdentity(epoch: Data(repeating: 1, count: 16),
            grant: Data(repeating: 2, count: 16), generation: 1)
        let request = LiveGPUSurfaceMessage(identity: identity,
            body: .bind(window: 7, instance: 8, width: 0, height: 0))
        let bytes = try request.encoded()
        XCTAssertEqual(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: bytes), request)
        for size: (UInt32, UInt32) in [(0, 480), (640, 0)] {
            let mixed = LiveGPUSurfaceMessage(identity: identity,
                body: .bind(window: 7, instance: 8, width: size.0, height: size.1))
            XCTAssertThrowsError(try mixed.encoded())
        }
    }

    func testIndependentPythonGoldenVectorsAtEverySplit() throws {
        let executor = Data([0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255])
        for hex in Self.surfaceVectors {
            let chars = Array(hex.utf8)
            let wire = Data(stride(from: 0, to: chars.count, by: 2).map {
                UInt8(String(decoding: chars[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
            })
            for split in 0...wire.count {
                let decoder = try LiveGPUEnvelopeDecoder(executor: executor, generation: 7)
                var frames: [LiveGPUEnvelope] = []
                try decoder.feed(Data(wire.prefix(split))) { frames.append($0) }
                try decoder.feed(Data(wire.dropFirst(split))) { frames.append($0) }
                try decoder.finish()
                XCTAssertEqual(frames.count, 1)
                let frame = try XCTUnwrap(frames.first)
                let message = try LiveGPUSurfaceMessage.decode(kind: frame.kind, payload: frame.payload)
                XCTAssertEqual(try message.encoded(), frame.payload)
                XCTAssertEqual(try frame.encoded(), wire)
            }
        }
    }

    func testIndependentBindAndProviderCapabilitiesWire() throws {
        let bytes = common + le(UInt64(31)) + le(UInt64(0x0102030405060708)) + le(UInt32(640)) + le(UInt32(480))
        let bind = try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: bytes)
        XCTAssertEqual(bind.identity, identity)
        XCTAssertEqual(bind.body, .bind(window: 31, instance: 0x0102030405060708, width: 640, height: 480))
        XCTAssertEqual(try bind.encoded(), bytes)
        let caps = try LiveGPUSurfaceMessage.decode(kind: .surfaceCaps, payload: capsPayload)
        guard case let .capabilities(request, result, value?) = caps.body else { return XCTFail("missing actual capability fields") }
        XCTAssertEqual(request, 41); XCTAssertEqual(result, ok)
        XCTAssertEqual(value.currentWidth, UInt32.max) // Undefined extent is a valid provider value.
        XCTAssertEqual(value.maxImageCount, 0) // No artificial image-count limit.
        XCTAssertEqual(value.supportedUsageFlags, 0x12)
        XCTAssertEqual(value.formats, [.init(format: 44, colorSpace: 0)])
        XCTAssertEqual(value.modes, [2, 3])
        XCTAssertEqual(value.queues, [.init(family: 5, flags: 3, count: 2, supported: true)])
        XCTAssertEqual(try caps.encoded(), capsPayload)
    }

    func testEverySurfaceKindAndErrorResultPreservation() throws {
        let wires: [(LiveGPUEnvelope.Kind, Data)] = [
            (.surfaceBind, common + le(UInt64(1)) + le(UInt64(2)) + le(UInt32(640)) + le(UInt32(480))),
            (.surfaceBound, common + status(16, nil)),
            (.surfaceQuery, common + le(UInt64(42)) + le(UInt64(3))),
            (.surfaceCaps, common + le(UInt64(42)) + status(0, -4)),
            (.present, presentPayload),
            (.presentResult, common + le(UInt64(8)) + status(0, -4) + le(UInt32(2)) + le(UInt32(1))),
            (.sourceReleased, common + le(UInt64(8))),
            (.surfaceRetire, common),
            (.surfaceRetired, common + status(110, nil))
        ]
        for (kind, bytes) in wires {
            let parsed = try LiveGPUSurfaceMessage.decode(kind: kind, payload: bytes)
            XCTAssertEqual(parsed.kind, kind); XCTAssertEqual(try parsed.encoded(), bytes)
            var wire = Data([0x43, 0x47, 0x4c, 0x56]) + le(UInt16(1)) + le(kind.rawValue) + le(UInt32(bytes.count)) + le(UInt32(0))
            wire += Data(1...16); wire += le(UInt64(2)); wire += le(UInt64(3)); wire += le(UInt64(0)); wire += le(UInt64(1)); wire += bytes
            let decoder = try LiveGPUEnvelopeDecoder(executor: Data(1...16), generation: 2)
            var frames: [LiveGPUEnvelope] = []
            for b in wire { try decoder.feed(Data([b])) { frames.append($0) } }
            try decoder.finish()
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(try frames[0].encoded(), wire)
            for length in 0..<bytes.count {
                XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: kind, payload: Data(bytes.prefix(length))))
            }
        }
        let failure = try LiveGPUSurfaceMessage.decode(kind: .surfaceRetired, payload: common + status(110, nil))
        XCTAssertEqual(failure.body, .retired(.init(nativeErrno: 110, vkResult: nil)))
        // Native errno-only failure must not be converted into a fictional VkResult.
        XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: .surfaceRetired,
            payload: replacing(common + status(110, nil), at: 48, with: UInt32(bitPattern: -4))))
    }

    func testActualDriverStatusRemainsSeparateFromNativeError() throws {
        let suboptimal = common + le(UInt64(8)) + status(0, 1000001003) + le(UInt32(1)) + le(UInt32(0))
        let parsed = try LiveGPUSurfaceMessage.decode(kind: .presentResult, payload: suboptimal)
        XCTAssertEqual(parsed.body, .presentResult(serial: 8, status: .init(nativeErrno: 0, vkResult: 1000001003), disposition: .queued, event: .submission))
        for result: Int32? in [5, -4] {
            let bytes = common + le(UInt64(41)) + status(0, result)
            let caps = try LiveGPUSurfaceMessage.decode(kind: .surfaceCaps, payload: bytes)
            XCTAssertEqual(caps.body, .capabilities(request: 41, status: .init(nativeErrno: 0, vkResult: result), value: nil))
        }
    }

    func testMalformedCountsEnumsScopeAndIdentityFailClosed() throws {
        let malformed: [(LiveGPUEnvelope.Kind, Data)] = [
            (.surfaceBound, replacing(common + status(0, 0), at: 44, with: 2)),
            (.surfaceBound, replacing(common + status(0, nil), at: 52, with: 1)),
            (.surfaceBound, replacing(common + status(0, nil), at: 40, with: UInt32.max)),
            (.surfaceCaps, replacing(capsPayload, at: 116, with: 4097)),
            (.surfaceCaps, replacing(capsPayload, at: 120, with: UInt32.max)),
            (.surfaceCaps, replacing(capsPayload, at: capsPayload.count - 4, with: 2)),
            (.surfaceCaps, common + le(UInt64(41)) + status(0, 0)), // Success without fields.
            (.surfaceCaps, common + le(UInt64(41)) + status(0, nil)), // No provider query result.
            (.surfaceCaps, replacing(capsPayload, at: 52, with: 0)), // No actual VkResult for purported caps.
            (.surfaceCaps, replacing(capsPayload, at: 56, with: 5)), // VK_INCOMPLETE cannot publish a partial list.
            (.surfaceCaps, capsPayload + le(UInt32(0))),
            (.present, replacing(presentPayload, at: 72, with: 0)),
            (.present, replacing(presentPayload, at: 104, with: 12)), // Duplicate binary wait.
            (.present, replacing(presentPayload, at: 84, with: 1000001002)), // PRESENT_SRC is not GENERAL.
            (.present, replacing(presentPayload, at: 92, with: 65)),
            (.present, replacing(presentPayload, at: 92, with: 1)),
            (.presentResult, common + le(UInt64(1)) + status(0, nil) + le(UInt32(3)) + le(UInt32(0))),
            (.presentResult, common + le(UInt64(1)) + status(0, nil) + le(UInt32(0)) + le(UInt32(3))),
            (.presentResult, common + le(UInt64(1)) + status(104, nil) + le(UInt32(2)) + le(UInt32(1)))
        ]
        for (kind, bytes) in malformed {
            XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: kind, payload: bytes), "kind \(kind)")
        }
        for range in [0..<16, 16..<32, 32..<40] {
            var bytes = common; bytes.replaceSubrange(range, with: Data(repeating: 0, count: range.count))
            XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: .surfaceRetire, payload: bytes))
        }
        for (process, stream): (UInt64, UInt64) in [(0, 0), (1, 1)] {
            XCTAssertThrowsError(try LiveGPUEnvelope(kind: .surfaceRetire, executor: Data(1...16), generation: 1,
                process: process, stream: stream, sequence: 1, payload: common).encoded())
        }
        XCTAssertNil(LiveGPUEnvelope.Kind(rawValue: 14)); XCTAssertNil(LiveGPUEnvelope.Kind(rawValue: 15))
    }

    func testMaximumCountsAndWaitsRemainBounded() throws {
        var payload = common + le(UInt64(1)) + status(0, 0)
        for _: Int in 0..<13 { payload += le(UInt32(1)) }
        for _: Int in 0..<3 { payload += le(UInt32(4096)) }
        for _: Int in 0..<4096 { payload += le(UInt32(44)); payload += le(UInt32(0)) }
        for _: Int in 0..<4096 { payload += le(UInt32(2)) }
        for i in 0..<4096 { for v: UInt32 in [UInt32(i), 3, 1, 1] { payload += le(v) } }
        XCTAssertEqual(payload.count, 114816)
        XCTAssertEqual(try LiveGPUSurfaceMessage.decode(kind: .surfaceCaps, payload: payload).encoded(), payload)
        var present = Data(presentPayload.prefix(96))
        present = replacing(present, at: 92, with: 64)
        for i in 1...64 { present += le(UInt64(i)) }
        XCTAssertEqual(try LiveGPUSurfaceMessage.decode(kind: .present, payload: present).encoded(), present)
    }

    func testMalformedPayloadPoisonsEnvelopeBeforeDelivery() throws {
        var frame = try LiveGPUEnvelope(kind: .surfaceBound, executor: Data(1...16), generation: 1,
            process: 2, stream: 0, sequence: 1, payload: common + status(0, nil)).encoded()
        frame[64 + 52] = 1
        let decoder = try LiveGPUEnvelopeDecoder(executor: Data(1...16), generation: 1)
        XCTAssertThrowsError(try decoder.feed(frame) { _ in XCTFail("invalid status delivered") })
        XCTAssertEqual(decoder.bufferedBytes, 0)
        XCTAssertThrowsError(try decoder.feed(Data()) { _ in XCTFail() })
    }
    // Verbatim independent complete wire vectors from parent c198c91c.
    private static let surfaceVectors: [String] = [
        "43474c5601001000400000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2003000000000000000500000000000000070000000000000080020000e0010000", // bind
        "43474c5601001100380000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000000000000010000000000000000000000", // bound
        "43474c5601001200380000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000009000000000000000b00000000000000", // query
        "43474c56010013009c0000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000090000000000000000000000010000000000000000000000020000000400000080020000e00100000100000001000000001000000010000001000000010000000100000001000000020000000100000001000000010000002c000000000000000200000000000000070000000100000001000000", // caps
        "43474c5601001300400000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000009000000000000000000000001000000fcffffff00000000", // caps-error
        "43474c5601001300400000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000090000000000000016000000000000000000000000000000", // caps-local-error
        "43474c5601001400700000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000004000000000000000b000000000000000d000000000000000f000000000000002c00000080020000e001000001000000000000000200000011000000000000001300000000000000", // present
        "43474c5601001500480000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2003000000000000000400000000000000000000000100000000000000000000000100000000000000", // queued
        "43474c5601001500480000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000004000000000000000000000001000000fcffffff000000000200000001000000", // device-lost
        "43474c5601001600300000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2003000000000000000400000000000000", // released
        "43474c5601001700280000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f200300000000000000", // retire
        "43474c5601001800380000000000000000112233445566778899aabbccddeeff07000000000000000b00000000000000000000000000000001000000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20030000000000000000000000000000000000000000000000", // retired
    ]

}
