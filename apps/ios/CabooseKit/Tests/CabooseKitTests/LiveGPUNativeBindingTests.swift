import Foundation
import Darwin
import XCTest
@testable import CabooseKit

final class LiveGPUNativeBindingTests: XCTestCase {
    func testNegotiatedCompressedDataPreservesBytesAndNativeRetirement() throws {
        // Independent Python struct/zlib raw-DEFLATE fixture: sequence5, process1/stream1.
        let text = "43474c5a01000100c00f0000650000007376f7096364606768e06700034634c00e11666044a359a1fcfca294ccbcc4a24a8594d4e4fc94d41485e4fcdcdcc4bc1485a4ca92d4628651e9d160194d0ea3d960b474182d15476b83d14a72b47130da281a6d2b8eb69147fb06a35da6d1ae2215bac800"
        let chars = Array(text.utf8)
        let packed = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(bytes: chars[$0..<$0 + 2], encoding: .utf8)!, radix: 16)! })
        let runtime = LiveRuntimeProbe(), output = LiveOutputProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        // Expansion is charged even while CONFIG is waiting behind earlier work.
        XCTAssertEqual(try binding.ingressCharge(packed), packed.count + 4032 + 1)
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.transportConfig, sequence: 2, payload: LiveGPUCompression.offer))
        XCTAssertEqual(try output.frames().last?.kind, .transportReady)
        try binding.consume(wire(.processOpen, sequence: 3, process: 1))
        try binding.consume(wire(.streamOpen, sequence: 4, process: 1, stream: 1))
        try binding.consume(packed)
        try binding.consume(wire(.fin, sequence: 6, process: 1, stream: 1))
        XCTAssertTrue(output.waitForFINs(1))
        try binding.consume(wire(.processStop, sequence: 7, process: 1))
        try binding.consume(wire(.revoke, sequence: 8))
        try binding.finish()
        XCTAssertEqual(runtime.received[1], Data(String(repeating: "ordinary decoded command bytes\0", count: 128).utf8))
        XCTAssertNil(output.error)
        XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
    }

    func testZstdStreamRecordsDecodeInOrderAndRawDataIsRefused() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/live-zstd-binding-vectors.json")
        let vectors = try (JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: String]]).map {
            (envelope: hex($0["envelope"]!), record: hex($0["record"]!))
        }
        let runtime = LiveRuntimeProbe(), output = LiveOutputProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        binding.zstdWindowLog = { 26 }
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.transportConfig, sequence: 2, payload: LiveGPUCompression.offer(.zstdStream, windowLog: 27)))
        XCTAssertEqual(try output.frames().last?.kind, .transportReady)
        // The phone takes the window it holds, here 64 MiB of the 128 MiB offered.
        XCTAssertEqual(try output.frames().last?.payload, LiveGPUCompression.offer(.zstdStream, windowLog: 26))
        try binding.consume(wire(.processOpen, sequence: 3, process: 1))
        try binding.consume(wire(.streamOpen, sequence: 4, process: 1, stream: 1))
        for vector in vectors { try binding.consume(vector.record) }
        try binding.consume(wire(.fin, sequence: 9, process: 1, stream: 1))
        XCTAssertTrue(output.waitForFINs(1))
        try binding.consume(wire(.processStop, sequence: 10, process: 1))
        try binding.consume(wire(.revoke, sequence: 11))
        try binding.finish()
        XCTAssertEqual(runtime.received[1], vectors.map { $0.envelope.dropFirst(64) }.reduce(Data(), +))
        XCTAssertNil(output.error)

        // On a zstd stream every DATA envelope is a record: a raw one is a protocol error.
        let raw = try LiveGPUNativeBinding(backend: LiveRuntimeProbe())
        try raw.start(output: { _ in true }, failed: { _ in })
        try raw.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try raw.consume(wire(.transportConfig, sequence: 2, payload: LiveGPUCompression.offer(.zstdStream)))
        try raw.consume(wire(.processOpen, sequence: 3, process: 1))
        try raw.consume(wire(.streamOpen, sequence: 4, process: 1, stream: 1))
        XCTAssertThrowsError(try raw.consume(vectors[0].envelope))
        try? raw.revoke(); try? raw.finish()
    }

    func testSessionSelectsTheComputersCacheRootBeforeAnyProcess() throws {
        for root in [URL(fileURLWithPath: "/tmp/caboose-gpu-cache/computer-a"), nil] {
            let runtime = LiveRuntimeProbe()
            let binding = try LiveGPUNativeBinding(backend: runtime, cacheRoot: root)
            try binding.start(output: { _ in true }, failed: { _ in })
            XCTAssertTrue(runtime.cacheRoots.isEmpty)
            try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
            // A session without a root clears the previous computer's caches.
            XCTAssertEqual(runtime.cacheRoots, [root?.path])
            try binding.consume(wire(.processOpen, sequence: 2, process: 1))
            XCTAssertEqual(runtime.cacheRoots.count, 1)
            try binding.revoke(); try binding.finish()
        }
    }

    func testCacheRootIsOnePrivateDirectoryPerPairing() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try LiveGPUCacheRoot.directory(pairing: "computer-a", base: base)
        let b = try LiveGPUCacheRoot.directory(pairing: "computer-b", base: base)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "CabooseGPU")
        XCTAssertEqual(try a.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for bad in ["", ".", "..", "a/b"] {
            XCTAssertThrowsError(try LiveGPUCacheRoot.directory(pairing: bad, base: base))
        }
        LiveGPUCacheRoot.remove(pairing: "computer-a", base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testCompressionNegotiationCannotRepeatOrFollowProcessAdmission() throws {
        for late in [false, true] {
            let runtime = LiveRuntimeProbe()
            let binding = try LiveGPUNativeBinding(backend: runtime)
            try binding.start(output: { _ in true }, failed: { _ in })
            try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
            if late { try binding.consume(wire(.processOpen, sequence: 2, process: 1)) }
            else { try binding.consume(wire(.transportConfig, sequence: 2, payload: LiveGPUCompression.offer)) }
            XCTAssertThrowsError(try binding.consume(wire(.transportConfig, sequence: 3, payload: LiveGPUCompression.offer)))
            try binding.revoke(); try binding.finish()
            XCTAssertFalse(binding.retirementReceiptSent)
        }
    }

    func testRealSocketpairMultiprocessDuplexAndRetirement() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        var seq: UInt64 = 0
        func send(_ kind: LiveGPUEnvelope.Kind, _ p: UInt64 = 0, _ s: UInt64 = 0, _ data: Data = Data()) throws {
            seq += 1; try binding.consume(wire(kind, sequence: seq, process: p, stream: s, payload: data))
        }
        try send(.session, 0, 0, LiveGPUEnvelope.hello)
        for id: UInt64 in [1, 2] {
            try send(.processOpen, id); try send(.streamOpen, id, id)
            let bytes = Data([0, 0, 0, 0, UInt8(id), 0xff])
            try send(.data, id, id, bytes); try send(.fin, id, id)
        }
        XCTAssertTrue(output.waitForFINs(2))
        for id: UInt64 in [1, 2] { try send(.processStop, id) }
        try send(.revoke)
        try binding.finish()
        XCTAssertNil(output.error)
        let frames = try output.frames()
        XCTAssertEqual(frames.filter { $0.kind == .data }.reduce(Data()) { $0 + $1.payload }.count, 12)
        XCTAssertEqual(Set(frames.filter { $0.kind == .processRetired }.map(\.process)), [1,2])
        XCTAssertEqual(frames.last?.kind, .revoked)
        XCTAssertEqual(runtime.starts, 1)
        XCTAssertEqual(runtime.finishedTokens.sorted(), [1,2])
        XCTAssertEqual(runtime.received.values.reduce(0) { $0 + $1.count }, 12) // no hello/envelope leakage
        XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
    }
    func testStreamEOFWithEPROTODuringProcessExitDoesNotFailBinding() throws {
        let runtime = LiveRuntimeProbe(); runtime.runEprotoOnEOF = true
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.streamOpen, sequence: 3, process: 1, stream: 1))
        try binding.consume(wire(.data, sequence: 4, process: 1, stream: 1, payload: Data([0, 0, 0, 0])))
        try binding.consume(wire(.fin, sequence: 5, process: 1, stream: 1))
        XCTAssertTrue(output.waitForFINs(1))
        try binding.consume(wire(.processStop, sequence: 6, process: 1))
        try binding.consume(wire(.revoke, sequence: 7))
        try binding.finish()
        XCTAssertNil(output.error)
        XCTAssertEqual(runtime.finishedTokens, [1])
    }
    func testRapidHalfCloseAndRetirementAcrossManyStreamsNeverHangs() throws {
        for eprotoOnEOF in [false, true] {
            let runtime = LiveRuntimeProbe()
            runtime.runEprotoOnEOF = eprotoOnEOF
            let binding = try LiveGPUNativeBinding(backend: runtime)
            let output = LiveOutputProbe()
            try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
            var seq: UInt64 = 0
            func send(_ kind: LiveGPUEnvelope.Kind, _ p: UInt64 = 0, _ s: UInt64 = 0, _ data: Data = Data()) throws {
                seq += 1; try binding.consume(wire(kind, sequence: seq, process: p, stream: s, payload: data))
            }
            try send(.session, 0, 0, LiveGPUEnvelope.hello)
            var streamID: UInt64 = 0
            for procID: UInt64 in 1...16 {
                try send(.processOpen, procID)
                for _ in 1...4 {
                    streamID += 1
                    try send(.streamOpen, procID, streamID)
                    try send(.data, procID, streamID, Data([0x11, 0x22, 0x33, 0x44]))
                    try send(.fin, procID, streamID)
                }
                XCTAssertTrue(output.waitForFINs(4))
                try send(.processStop, procID)
            }
            try send(.revoke)
            try binding.finish()
            XCTAssertNil(output.error)
            XCTAssertEqual(runtime.finishedTokens.count, 16)
            XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
        }
    }
    func testDrainWaitsForSessionThenEmitsOnceWithoutInventingRetirement() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.requestDrain(); try binding.requestDrain()
        XCTAssertTrue(try output.frames().isEmpty)
        XCTAssertEqual(runtime.starts, 0)
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.requestDrain()
        XCTAssertEqual(try output.frames().map(\.kind), [.sessionReady, .executorDrain])
        XCTAssertTrue(runtime.finishedTokens.isEmpty)
        XCTAssertFalse(binding.retirementReceiptSent)
        // A process already in flight still requires its genuine lifecycle receipts.
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.processStop, sequence: 3, process: 1))
        try binding.consume(wire(.revoke, sequence: 4))
        XCTAssertEqual(try output.frames().map(\.kind),
                       [.sessionReady, .executorDrain, .processReady, .processRetired, .revoked])
        XCTAssertEqual(runtime.finishedTokens, [1])
        XCTAssertTrue(binding.retirementReceiptSent)
        try binding.finish()
    }

    func testPrestartRevokeAndMissingModuleFailClosed() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.revoke()
        XCTAssertThrowsError(try binding.start(output: { _ in true }, failed: { _ in }))
        try binding.finish(); XCTAssertEqual(runtime.starts, 0)
        #if !canImport(CabooseGPULive)
        XCTAssertThrowsError(try LiveGPUNativeBinding()) { XCTAssertEqual($0 as? LiveGPUError, .missingNativeBinding) }
        #endif
    }
    func testPriorModesAndUnknownFeatureBitsCannotInitializeIndexedRuntime() throws {
        for (version, mask): (UInt8, UInt8) in [(2, 0x10), (3, 0x30), (4, 0x71)] {
            let runtime = LiveRuntimeProbe()
            let binding = try LiveGPUNativeBinding(backend: runtime)
            try binding.start(output: { _ in true }, failed: { _ in })
            var incompatible = LiveGPUEnvelope.hello
            incompatible[8] = version; incompatible[12] = mask
            XCTAssertThrowsError(try binding.consume(wire(.session, sequence: 1, payload: incompatible)))
            XCTAssertEqual(runtime.starts, 0)
            try binding.finish()
        }
    }

    func testHelloMismatchNeverInitializesRuntime() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { _ in true }, failed: { _ in })
        var hello = LiveGPUEnvelope.hello; hello[16] ^= 1
        XCTAssertThrowsError(try binding.consume(wire(.session, sequence: 1, payload: hello)))
        XCTAssertEqual(runtime.starts, 0)
        try binding.finish()
    }
    func testNativeErrorsAndRetirementFencePersist() throws {
        let runtime = LiveRuntimeProbe(); runtime.finishCode = EIO
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { _ in true }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        // Retirement runs off the worker; its failure fails the session.
        try binding.consume(wire(.processStop, sequence: 3, process: 1))
        binding.waitForRetirements()
        XCTAssertEqual(output.lock.withLock { output.error } as? LiveGPUBindingError, .native(operation: "finish", code: EIO))
        XCTAssertThrowsError(try binding.finish()) {
            XCTAssertEqual($0 as? LiveGPUBindingError, .native(operation: "finish", code: EIO))
        }
        XCTAssertThrowsError(try binding.finish())
        XCTAssertEqual(runtime.finishedTokens, [1])
    }
    func testConcurrentRevokeUnblocksFullSocketWriter() throws {
        let runtime = LiveRuntimeProbe(); runtime.reads = false
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { _ in true }, failed: { _ in })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.streamOpen, sequence: 3, process: 1, stream: 1))
        XCTAssertEqual(runtime.entered.wait(timeout: .now() + 2), .success)
        // More than the socket holds: the stream's writer waits for room, the consumer does not.
        let released = DispatchSemaphore(value: 0)
        for sequence: UInt64 in 4...15 {
            try binding.consume(wire(.data, sequence: sequence, process: 1, stream: 1,
                payload: Data(repeating: 3, count: LiveGPUEnvelope.maxPayload)), release: { released.signal() })
        }
        XCTAssertEqual(released.wait(timeout: .now() + 0.1), .success, "what fits in the socket is released")
        var delivered = 1
        while released.wait(timeout: .now() + 0.1) == .success { delivered += 1 }
        XCTAssertLessThan(delivered, 12, "input still waiting for room keeps its charge")
        try binding.revoke()
        // Revocation ends the writer, and every charge it still held is released.
        for _ in 0..<(12 - delivered) { XCTAssertEqual(released.wait(timeout: .now() + 2), .success) }
        try binding.finish()
        XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
        XCTAssertEqual(runtime.finishedTokens, [1])
    }
    func testAStreamWhoseDecoderIsBusyHoldsBackNoOtherStream() throws {
        let runtime = LiveRuntimeProbe(); runtime.idleTokens = [1]
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        var seq: UInt64 = 0
        func send(_ kind: LiveGPUEnvelope.Kind, _ p: UInt64 = 0, _ s: UInt64 = 0, _ data: Data = Data()) throws {
            seq += 1; try binding.consume(wire(kind, sequence: seq, process: p, stream: s, payload: data))
        }
        try send(.session, 0, 0, LiveGPUEnvelope.hello)
        try send(.processOpen, 1); try send(.streamOpen, 1, 1)
        try send(.processOpen, 2); try send(.streamOpen, 2, 2)
        // Process 1's decoder reads nothing: four megabytes is more than its socket holds.
        let started = Date()
        for _ in 0..<16 { try send(.data, 1, 1, Data(repeating: 7, count: LiveGPUEnvelope.maxPayload)) }
        try send(.data, 2, 2, Data([1, 2, 3, 4])); try send(.fin, 2, 2)
        XCTAssertTrue(output.waitForFINs(1), "the other stream is decoded and answered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(runtime.lock.withLock { runtime.received[2] }, Data([1, 2, 3, 4]))
        try send(.processStop, 1); try send(.processStop, 2)
        try send(.revoke)
        try binding.finish()
        XCTAssertNil(output.error)
        XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
    }
    func testQueuedInputReachesTheDecoderInOrderBeforeItsEnd() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.streamOpen, sequence: 3, process: 1, stream: 1))
        var expected = Data()
        var released = 0
        let lock = NSLock()
        for index in 0..<40 {
            let chunk = Data((0..<(LiveGPUEnvelope.maxPayload - index)).map { UInt8(truncatingIfNeeded: $0 &+ index) })
            expected.append(chunk)
            try binding.consume(wire(.data, sequence: UInt64(4 + index), process: 1, stream: 1, payload: chunk),
                                release: { lock.withLock { released += 1 } })
        }
        try binding.consume(wire(.fin, sequence: 44, process: 1, stream: 1))
        XCTAssertTrue(output.waitForFINs(1))
        XCTAssertEqual(runtime.lock.withLock { runtime.received[1] }, expected)
        XCTAssertEqual(lock.withLock { released }, 40)
        try binding.consume(wire(.processStop, sequence: 45, process: 1))
        try binding.consume(wire(.revoke, sequence: 46))
        try binding.finish()
        XCTAssertNil(output.error)
    }
    func testOutputRejectionRevokesWorkers() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { _ in false }, failed: { _ in })
        XCTAssertThrowsError(try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))) {
            XCTAssertEqual($0 as? LiveGPUBindingError, .outputRejected)
        }
        try binding.finish()
    }
    func testAProcessWhoseCleanupHangsDoesNotStopOthersOpening() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        runtime.cleanupGate = DispatchSemaphore(value: 0)
        try binding.consume(wire(.processStop, sequence: 3, process: 1))
        XCTAssertEqual(runtime.cleaning.wait(timeout: .now() + 2), .success)  // native finish is stuck
        try binding.consume(wire(.processOpen, sequence: 4, process: 2))
        XCTAssertEqual(try output.frames().filter { $0.kind == .processReady }.map(\.process), [1, 2])
        XCTAssertFalse(try output.frames().contains { $0.kind == .processRetired })
        runtime.cleanupGate?.signal()
        binding.waitForRetirements()
        XCTAssertEqual(try output.frames().filter { $0.kind == .processRetired }.map(\.process), [1])
        runtime.cleanupGate = nil
        try binding.revoke(); try binding.finish()
    }
    func testOpeningsArrivingOutOfOrderAreServed() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 3))
        try binding.consume(wire(.processOpen, sequence: 3, process: 2))
        try binding.consume(wire(.streamOpen, sequence: 4, process: 3, stream: 5))
        try binding.consume(wire(.streamOpen, sequence: 5, process: 3, stream: 4))
        try binding.consume(wire(.streamOpen, sequence: 6, process: 3, stream: 4))  // a repeat is dropped
        let frames = try output.frames()
        XCTAssertEqual(frames.filter { $0.kind == .processReady }.map(\.process), [3, 2])
        XCTAssertEqual(frames.filter { $0.kind == .streamReady }.map(\.stream), [5, 4])
        try binding.revoke(); try binding.finish()
    }
    func testIDsCannotBeReusedAfterRetirement() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { _ in true }, failed: { _ in })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 2))
        try binding.consume(wire(.processStop, sequence: 3, process: 2))
        // A reused identity is not opened again, and nothing else ends.
        try binding.consume(wire(.processOpen, sequence: 4, process: 2))
        XCTAssertEqual(runtime.lock.withLock { runtime.next }, 1)
        try binding.consume(wire(.processOpen, sequence: 5, process: 3))
        XCTAssertEqual(runtime.lock.withLock { runtime.next }, 2)
        try? binding.finish()
    }
    func testRetiredWaitsForRealBackendCleanupAndCapacityReplenishes() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        for id: UInt64 in 1...16 { try binding.consume(wire(.processOpen, sequence: id + 1, process: id)) }
        runtime.cleanupGate = DispatchSemaphore(value: 0)
        let stop = try wire(.processStop, sequence: 18, process: 1)
        let retired = expectation(description: "retired after cleanup")
        DispatchQueue.global().async {
            defer { retired.fulfill() }
            do { try binding.consume(stop) } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(runtime.cleaning.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(try output.frames().contains { $0.kind == .processRetired })
        runtime.cleanupGate?.signal()
        wait(for: [retired], timeout: 2)
        runtime.cleanupGate = nil
        try binding.consume(wire(.processOpen, sequence: 19, process: 17))
        // Past capacity the opening goes unanswered; the executor stays.
        try binding.consume(wire(.processOpen, sequence: 20, process: 18))
        XCTAssertEqual(try output.frames().filter { $0.kind == .processReady }.count, 17)
        try binding.finish()
        XCTAssertEqual(runtime.finishedTokens.count, 17)
    }

    func testSuspendHoldsProcessMessagesUntilResumeAndAnswersQuiesce() throws {
        for cancelled in [false, true] {
            let runtime = LiveRuntimeProbe()
            let binding = try LiveGPUNativeBinding(backend: runtime)
            let output = LiveOutputProbe()
            try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
            var seq: UInt64 = 0
            func send(_ kind: LiveGPUEnvelope.Kind, _ p: UInt64 = 0, _ s: UInt64 = 0, _ data: Data = Data()) throws {
                seq += 1; try binding.consume(wire(kind, sequence: seq, process: p, stream: s, payload: data))
            }
            func kinds() throws -> [LiveGPUEnvelope.Kind] { try output.frames().map(\.kind) }
            try send(.session, 0, 0, LiveGPUEnvelope.hello)
            try send(.processOpen, 1); try send(.streamOpen, 1, 1)
            let quiesced = expectation(description: "quiesced")
            XCTAssertTrue(try binding.suspend(quiesced: { quiesced.fulfill() }))
            XCTAssertFalse(try binding.suspend(quiesced: {}))
            XCTAssertEqual(runtime.gate, ["suspend"])
            XCTAssertEqual(try kinds().last, .executorSuspend)
            // Held, not decoded, while suspended.
            try send(.data, 1, 1, Data([1, 2, 3, 4]))
            XCTAssertNil(runtime.lock.withLock { runtime.received[1] })
            if cancelled {
                // A suspend cancelled before QUIESCE decodes at once and resumes after answering it.
                try binding.resumeExecutor()
                XCTAssertEqual(runtime.gate, ["suspend", "resume"])
                try send(.quiesce)
                wait(for: [quiesced], timeout: 2)
                XCTAssertEqual(Array(try kinds().filter { $0 != .data }.suffix(2)), [.quiesced, .executorResume])
            } else {
                try send(.quiesce)
                wait(for: [quiesced], timeout: 2)
                XCTAssertEqual(try kinds().last, .quiesced)
                XCTAssertThrowsError(try send(.quiesce))
                try? binding.revoke(); try? binding.finish()
                continue
            }
            let deadline = Date().addingTimeInterval(2)
            while runtime.lock.withLock({ runtime.received[1]?.count ?? 0 }) < 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertEqual(runtime.lock.withLock { runtime.received[1] }, Data([1, 2, 3, 4]))
            try binding.revoke(); try binding.finish()
        }
        // Resumed after QUIESCED: EXECUTOR_RESUME first, then the held messages.
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        XCTAssertTrue(try binding.suspend(quiesced: {}))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.quiesce, sequence: 3))
        XCTAssertEqual(runtime.lock.withLock { runtime.next }, 0)
        try binding.resumeExecutor()
        let frames = try output.frames()
        XCTAssertEqual(frames.map(\.kind).suffix(4), [.executorSuspend, .quiesced, .executorResume, .processReady])
        XCTAssertEqual(frames.first { $0.kind == .executorResume }?.payload, Data(count: 8))
        try binding.revoke(); try binding.finish()
    }

    func testRuntimeThatCannotSuspendLeavesTheExecutorAsItWas() throws {
        let runtime = LiveRuntimeProbe(); runtime.suspendResult = ENOTSUP
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        XCTAssertFalse(try binding.suspend(quiesced: {}))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        XCTAssertEqual(try output.frames().map(\.kind), [.sessionReady, .processReady])
        XCTAssertThrowsError(try binding.consume(wire(.quiesce, sequence: 3)))
        try? binding.finish()
    }

    func testStatsRequestSendsTheExecutorsCountersAtItsInterval() throws {
        let runtime = LiveRuntimeProbe()
        let counters = LiveGPUExecutorStats(commands: 1200, decodeMicroseconds: 9000, readBytes: 4096,
            submitted: 30, completed: 29, gpuBusyMicroseconds: 400, outstanding: 1, outstandingMax: 3)
        runtime.stats = counters
        let binding = try LiveGPUNativeBinding(backend: runtime)
        let output = LiveOutputProbe()
        try binding.start(output: { output.accept($0) }, failed: { output.fail($0) })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        // Nothing until the computer asks.
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertFalse(try output.frames().contains { $0.kind == .executorStats })
        var interval = Data(count: 8); interval[0] = 100
        try binding.consume(wire(.statsRequest, sequence: 2, payload: interval))
        let deadline = Date().addingTimeInterval(3)
        var sent: [LiveGPUEnvelope] = []
        while sent.count < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            sent = try output.frames().filter { $0.kind == .executorStats }
        }
        XCTAssertGreaterThanOrEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.payload, counters.payload)
        XCTAssertEqual(sent.first?.payload.count, LiveGPUExecutorStats.size)
        // A second request is a protocol violation.
        XCTAssertThrowsError(try binding.consume(wire(.statsRequest, sequence: 3, payload: interval)))
        try? binding.revoke()
        let after = try output.frames().filter { $0.kind == .executorStats }.count
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(try output.frames().filter { $0.kind == .executorStats }.count, after)
    }

    func testExecutorStatsPayloadAndRequestedInterval() {
        let stats = LiveGPUExecutorStats(commands: 1, outstandingMax: 2)
        XCTAssertEqual(stats.payload.prefix(8), Data([96, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(stats.payload.suffix(8), Data([2, 0, 0, 0, 0, 0, 0, 0]))
        var request = Data(count: 8)
        request[0] = 0xe8; request[1] = 3
        XCTAssertEqual(LiveGPUExecutorStats.requestedInterval(request), 1000)
        request[0] = 50; request[1] = 0
        XCTAssertNil(LiveGPUExecutorStats.requestedInterval(request))
        XCTAssertNil(LiveGPUExecutorStats.requestedInterval(Data(count: 4)))
    }

    private func hex(_ text: String) -> Data {
        let chars = Array(text.utf8)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(bytes: chars[$0..<$0 + 2], encoding: .utf8)!, radix: 16)! })
    }

    private func wire(_ kind: LiveGPUEnvelope.Kind, sequence: UInt64, process: UInt64 = 0,
                      stream: UInt64 = 0, payload: Data = Data()) throws -> Data {
        try LiveGPUEnvelope(kind: kind, executor: Data(repeating: 1, count: 16), generation: 7,
            process: process, stream: stream, sequence: sequence, payload: payload).encoded()
    }
}

private final class LiveOutputProbe: @unchecked Sendable {
    let lock = NSLock()
    var bytes: [Data] = []
    var error: Error?
    let fin = DispatchSemaphore(value: 0)
    func accept(_ data: Data) -> Bool {
        lock.withLock { bytes.append(data) }
        if data[6] == 8 { fin.signal() }
        return true
    }
    func fail(_ error: Error) { lock.withLock { self.error = error } }
    func waitForFINs(_ count: Int) -> Bool { (0..<count).allSatisfy { _ in fin.wait(timeout: .now() + 2) == .success } }
    func frames() throws -> [LiveGPUEnvelope] {
        let decoder = try LiveGPUEnvelopeDecoder(executor: Data(repeating: 1, count: 16), generation: 7)
        var frames: [LiveGPUEnvelope] = []
        for data in lock.withLock({ bytes }) { try decoder.feed(data) { frames.append($0) } }
        try decoder.finish(); return frames
    }
}

private final class LiveRuntimeProbe: LiveGPURuntimeBackend, @unchecked Sendable {
    let lock = NSLock()
    let entered = DispatchSemaphore(value: 0)
    var starts = 0
    var next: UInt64 = 0
    var active: [UInt64: Int] = [:]
    var received: [UInt64: Data] = [:]
    var finishedTokens: [UInt64] = []
    var allRunsJoinedBeforeFinish = true
    var finishCode: Int32 = 0
    var runEprotoOnEOF = false
    var cleanupGate: DispatchSemaphore?
    let cleaning = DispatchSemaphore(value: 0)
    var reads = true
    /// Tokens whose decoder reads nothing until stopped (a decoder busy in the driver).
    var idleTokens: Set<UInt64> = []
    let stopped = DispatchSemaphore(value: 0)
    func start() -> Int32 { lock.withLock { starts += 1 }; return 0 }
    var cacheRoots: [String?] = []
    func setCacheRoot(_ path: String?) -> Int32 { lock.withLock { cacheRoots.append(path) }; return 0 }
    func open(_ token: inout UInt64) -> Int32 { lock.withLock { next += 1; token = next }; return 0 }
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32 {
        lock.withLock { active[token, default: 0] += 1 }; entered.signal()
        defer { lock.withLock { active[token, default: 0] -= 1 } }
        if !reads || lock.withLock({ idleTokens.contains(token) }) { stopped.wait(); return 0 }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return runEprotoOnEOF ? EPROTO : 0 }
            lock.withLock { received[token, default: Data()].append(contentsOf: bytes.prefix(count)) }
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, count) }
            if written != count { return EIO }
        }
    }
    func stop(_ token: UInt64) -> Int32 { stopped.signal(); return 0 }
    var stats: LiveGPUExecutorStats?
    func executorStats() -> LiveGPUExecutorStats? { lock.withLock { stats } }
    var suspendResult: Int32 = 0
    var gate: [String] = []
    func suspend(timeoutMilliseconds: UInt32) -> Int32 { lock.withLock { gate.append("suspend") }; return suspendResult }
    func resume() -> Int32 { lock.withLock { gate.append("resume") }; return 0 }
    func finish(_ token: UInt64) -> Int32 {
        if let cleanupGate { cleaning.signal(); cleanupGate.wait() }
        lock.withLock {
            if active[token, default: 0] != 0 { allRunsJoinedBeforeFinish = false }
            finishedTokens.append(token)
        }
        return finishCode
    }
}
