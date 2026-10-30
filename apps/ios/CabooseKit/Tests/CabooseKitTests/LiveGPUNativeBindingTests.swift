import Foundation
import Darwin
import XCTest
@testable import CabooseKit

final class LiveGPUNativeBindingTests: XCTestCase {
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
        // A process already in flight still requires its genuine lifecycle receipts.
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        try binding.consume(wire(.processStop, sequence: 3, process: 1))
        try binding.consume(wire(.revoke, sequence: 4))
        XCTAssertEqual(try output.frames().map(\.kind),
                       [.sessionReady, .executorDrain, .processReady, .processRetired, .revoked])
        XCTAssertEqual(runtime.finishedTokens, [1])
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
        try binding.start(output: { _ in true }, failed: { _ in })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 1))
        XCTAssertThrowsError(try binding.consume(wire(.processStop, sequence: 3, process: 1))) {
            XCTAssertEqual($0 as? LiveGPUBindingError, .native(operation: "finish", code: EIO))
        }
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
        let done = expectation(description: "writer unblocked")
        let writing = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let payload = try wire(.data, sequence: 4, process: 1, stream: 1,
            payload: Data(repeating: 3, count: LiveGPUEnvelope.maxPayload))
        DispatchQueue.global().async {
            defer { returned.signal(); done.fulfill() }
            writing.signal()
            do { try binding.consume(payload); XCTFail("cancelled write succeeded") } catch {}
        }
        XCTAssertEqual(runtime.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(writing.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(returned.wait(timeout: .now() + 0.05), .timedOut)
        try binding.revoke()
        wait(for: [done], timeout: 2)
        try binding.finish()
        XCTAssertTrue(runtime.allRunsJoinedBeforeFinish)
        XCTAssertEqual(runtime.finishedTokens, [1])
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
    func testIDsCannotBeReusedAfterRetirement() throws {
        let runtime = LiveRuntimeProbe()
        let binding = try LiveGPUNativeBinding(backend: runtime)
        try binding.start(output: { _ in true }, failed: { _ in })
        try binding.consume(wire(.session, sequence: 1, payload: LiveGPUEnvelope.hello))
        try binding.consume(wire(.processOpen, sequence: 2, process: 2))
        try binding.consume(wire(.processStop, sequence: 3, process: 2))
        XCTAssertThrowsError(try binding.consume(wire(.processOpen, sequence: 4, process: 2)))
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
        XCTAssertThrowsError(try binding.consume(wire(.processOpen, sequence: 20, process: 18)))
        try binding.finish()
        XCTAssertEqual(runtime.finishedTokens.count, 17)
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
    var cleanupGate: DispatchSemaphore?
    let cleaning = DispatchSemaphore(value: 0)
    var reads = true
    let stopped = DispatchSemaphore(value: 0)
    func start() -> Int32 { lock.withLock { starts += 1 }; return 0 }
    func open(_ token: inout UInt64) -> Int32 { lock.withLock { next += 1; token = next }; return 0 }
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32 {
        lock.withLock { active[token, default: 0] += 1 }; entered.signal()
        defer { lock.withLock { active[token, default: 0] -= 1 } }
        if !reads { stopped.wait(); return 0 }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return 0 }
            lock.withLock { received[token, default: Data()].append(contentsOf: bytes.prefix(count)) }
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, count) }
            if written != count { return EIO }
        }
    }
    func stop(_ token: UInt64) -> Int32 { stopped.signal(); return 0 }
    func finish(_ token: UInt64) -> Int32 {
        if let cleanupGate { cleaning.signal(); cleanupGate.wait() }
        lock.withLock {
            if active[token, default: 0] != 0 { allRunsJoinedBeforeFinish = false }
            finishedTokens.append(token)
        }
        return finishCode
    }
}
