import Foundation
import Testing
@testable import CabooseKit

@Suite struct LiveGPUDisplayIdentityTests {
    private func hello(_ value: CBOR?) -> ServerHello {
        var fields: [(CBOR, CBOR)] = [(.text("version"), .unsigned(0)),
                                      (.text("epoch"), .text("ordinary-display-epoch"))]
        if let value { fields.append((.text("gpu_live_epoch"), value)) }
        return ServerHello(.map(fields))
    }

    @Test func absentOrMalformedIdentityDoesNotAuthorizeLiveSurfaces() {
        for value: CBOR? in [nil, .null, .bool(true), .unsigned(1),
                            .text("00112233445566778899aabbccddeeff"),
                            .bytes(Data()), .bytes(Data(repeating: 1, count: 15)),
                            .bytes(Data(repeating: 1, count: 17)),
                            .bytes(Data(repeating: 0, count: 16))] {
            let parsed = hello(value)
            #expect(parsed.gpuLiveEpoch == nil)
            #expect(parsed.epoch == "ordinary-display-epoch")
        }
    }

    @Test func independentGuestGoldenVectorMatchesTypedIdentity() throws {
        let vector = try DisplayVectorTests.vector("server-hello-gpu-live")
        var parser = DisplayFrameParser()
        let frames = try parser.append(vector.wire)
        let first = try #require(frames.first)
        guard case .hello(let hello) = ServerMessage(first) else {
            Issue.record("expected server hello"); return
        }
        #expect(hello.gpuLiveEpoch == Data(1...16))
        #expect(hello.epoch == "5f3a9c01d2e4b678")
    }

    @Test func identityUsesExactBytesAndParticipatesInHelloChanges() {
        var first = Data(repeating: 0, count: 16)
        first[15] = 1
        var second = first
        second[15] = 2
        let one = hello(.bytes(first))
        let two = hello(.bytes(second))
        #expect(one.gpuLiveEpoch == first)
        #expect(two.gpuLiveEpoch == second)
        #expect(one != two)
        #expect(one.epoch == two.epoch)
    }
}
