import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import CabooseKit

private final class SurfaceOutput: @unchecked Sendable {
    let lock = NSLock()
    var messages: [LiveGPUSurfaceMessage] = []
    var errors: [Error] = []
    func append(_ message: LiveGPUSurfaceMessage) { lock.withLock { messages.append(message) } }
    func fail(_ error: Error) { lock.withLock { errors.append(error) } }
}
private final class TestSurfaceResource: LiveGPUSurfaceResource, @unchecked Sendable {
    var submissions: [LiveGPUSurfaceSubmission] = []
    var callbacks: [@Sendable (LiveGPUSurfaceMessage.Body) -> Void] = []
    var immediate: LiveGPUSurfaceMessage.Body?
    var retirementError: Int32 = 0
    var retired = 0
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
        (.init(nativeErrno: EIO, vkResult: -4), nil)
    }
    func present(_ request: LiveGPUSurfacePresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
        callbacks.append(event)
        if let immediate { event(immediate) }
        return submissions.removeFirst()
    }
    func retire() throws {
        retired += 1
        if retirementError != 0 { throw LiveGPUBindingError.native(operation: "retire", code: retirementError) }
        callbacks.removeAll()
    }
}
private final class SurfaceRuntime: LiveGPURuntimeBackend, @unchecked Sendable {
    var finishes = 0
    func start() -> Int32 { 0 }
    func open(_ token: inout UInt64) -> Int32 { token = 99; return 0 }
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32 { 0 }
    func stop(_ token: UInt64) -> Int32 { 0 }
    func finish(_ token: UInt64) -> Int32 { finishes += 1; return 0 }
}
private final class TestSurfaceBackend: LiveGPUSurfaceBackend, @unchecked Sendable {
    let resource = TestSurfaceResource()
    var customResource: (any LiveGPUSurfaceResource)?
    var bindings: [(UInt64, UInt64)] = []
    var bindError: Int32 = 0
    var throwsBindError = false
    var retainsFailedResource = false
    func bind(identity: LiveGPUSurfaceIdentity, processToken: UInt64, window: UInt64,
              instance: UInt64, width: UInt32, height: UInt32) throws -> LiveGPUSurfaceBinding {
        bindings.append((processToken, window))
        if throwsBindError { throw LiveGPUBindingError.native(operation: "bind", code: bindError) }
        let target = customResource ?? resource
        return .init(status: .init(nativeErrno: bindError, vkResult: nil),
                     resource: bindError == 0 || retainsFailedResource ? target : nil)
    }
}
final class LiveGPUSurfaceControllerTests: XCTestCase {
    private let identity = LiveGPUSurfaceIdentity(epoch: Data(repeating: 1, count: 16),
        grant: Data(repeating: 2, count: 16), generation: 1)
    private let queued = LiveGPUSurfaceSubmission(status: .init(nativeErrno: 0, vkResult: 0), disposition: .queued)
    private func request(_ serial: UInt64) -> LiveGPUSurfacePresent {
        .init(serial: serial, device: 10, queue: 11, image: 12, format: 44,
              width: 800, height: 600, layout: 1, queueFamily: 0, waits: [])
    }
    private func consume(_ controller: LiveGPUSurfaceController, _ body: LiveGPUSurfaceMessage.Body,
                         output: SurfaceOutput, process: UInt64 = 1,
                         identity: LiveGPUSurfaceIdentity? = nil) throws {
        try controller.consume(.init(identity: identity ?? self.identity, body: body),
            process: process, token: 99, output: { _, message in output.append(message) }, failed: { output.fail($0) })
    }
    private func bind(_ controller: LiveGPUSurfaceController, _ output: SurfaceOutput) throws {
        try consume(controller, .bind(window: 7, instance: 8, width: 800, height: 600), output: output)
    }
    func testProtocolDiagnosticDoesNotEchoArbitraryText() {
        XCTAssertEqual(LiveGPUProtocolDiagnostic.reason("surface unknown or foreign grant"), "surfaceUnknownGrant")
        XCTAssertEqual(LiveGPUProtocolDiagnostic.reason("surface unknown or foreign grant secret"), "other")
        XCTAssertEqual(LiveGPUProtocolDiagnostic.reason("user payload or path"), "other")
    }
    func testFailedBindRetainsOnlyExactIdentityUntilRetirement() throws {
        for throwsError in [false, true] {
            let backend = TestSurfaceBackend(), output = SurfaceOutput()
            backend.bindError = EAGAIN; backend.throwsBindError = throwsError
            let controller = LiveGPUSurfaceController(backend: backend)
            try bind(controller, output)
            XCTAssertEqual(output.messages.last?.body, .bound(.init(nativeErrno: EAGAIN, vkResult: nil)))
            XCTAssertEqual(controller.retainedCount, 1)
            XCTAssertThrowsError(try bind(controller, output))
            XCTAssertThrowsError(try consume(controller, .retire, output: output, process: 2))
            let stale = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: identity.grant, generation: 2)
            XCTAssertThrowsError(try consume(controller, .retire, output: output, identity: stale))
            XCTAssertThrowsError(try consume(controller, .query(request: 1, physicalDevice: 2), output: output))
            XCTAssertEqual(controller.retainedCount, 1)
            try consume(controller, .retire, output: output)
            XCTAssertEqual(output.messages.last?.body, .retired(.init(nativeErrno: 0, vkResult: nil)))
            XCTAssertEqual(controller.retainedCount, 0)
            XCTAssertEqual(backend.resource.retired, 0)
            XCTAssertThrowsError(try consume(controller, .retire, output: output))
            backend.bindError = 0; backend.throwsBindError = false
            let fresh = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: Data(repeating: 3, count: 16), generation: 2)
            try consume(controller, .bind(window: 7, instance: 8, width: 800, height: 600), output: output, identity: fresh)
            XCTAssertEqual(controller.retainedCount, 1)
            try controller.retireProcess(1)
            XCTAssertEqual(backend.resource.retired, 1)
        }
    }
    func testFailedBindWithResourceStillRequiresActualRetirement() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        backend.bindError = EIO; backend.retainsFailedResource = true
        backend.resource.retirementError = ETIMEDOUT
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        try consume(controller, .retire, output: output)
        XCTAssertEqual(output.messages.last?.body, .retired(.init(nativeErrno: ETIMEDOUT, vkResult: nil)))
        XCTAssertEqual(controller.retainedCount, 1)
        backend.resource.retirementError = 0
        try consume(controller, .retire, output: output)
        XCTAssertEqual(controller.retainedCount, 0)
    }
    func testRejectedGrantRetentionIsBounded() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend, limit: 1)
        backend.bindError = EAGAIN
        for n in 0..<256 {
            var grant = Data(repeating: 0, count: 16); grant[0] = UInt8(n); grant[1] = 1
            let id = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: grant, generation: 1)
            try consume(controller, .bind(window: 7, instance: 8, width: 800, height: 600), output: output, identity: id)
        }
        XCTAssertEqual(controller.retainedCount, 256)
        XCTAssertEqual(backend.bindings.count, 1)
        XCTAssertThrowsError(try bind(controller, output))
        XCTAssertEqual(controller.retainedCount, 256)
        try controller.retireProcess(1)
        XCTAssertEqual(controller.retainedCount, 0)
        XCTAssertEqual(backend.resource.retired, 0)
    }
    func testSynchronousFenceReceiptFollowsSubmissionAndLaterDeviceLossSurvives() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        backend.resource.submissions = [queued]
        backend.resource.immediate = .sourceReleased(serial: 1)
        try consume(controller, .present(request(1)), output: output)
        XCTAssertEqual(output.messages.map(\.kind), [.surfaceBound, .presentResult, .sourceReleased])
        backend.resource.callbacks[0](.presentResult(serial: 1, status: .init(nativeErrno: ENODEV, vkResult: -4),
                                                    disposition: .uncertain, event: .deviceLost))
        XCTAssertEqual(output.messages.last?.body, .presentResult(serial: 1,
            status: .init(nativeErrno: ENODEV, vkResult: -4), disposition: .uncertain, event: .deviceLost))
        XCTAssertTrue(output.errors.isEmpty)
    }
    func testForeignAndStaleIdentitiesNeverReachNative() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        XCTAssertEqual(backend.bindings.first?.0, 99)
        XCTAssertThrowsError(try consume(controller, .query(request: 1, physicalDevice: 2), output: output, process: 2))
        let stale = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: identity.grant, generation: 2)
        XCTAssertThrowsError(try consume(controller, .retire, output: output, identity: stale))
        XCTAssertThrowsError(try bind(controller, output))
        XCTAssertEqual(controller.retainedCount, 1)
        XCTAssertEqual(backend.resource.retired, 0)
    }
    func testFailedRetirementQuarantinesAndBlocksFurtherPresent() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        backend.resource.retirementError = ETIMEDOUT
        try consume(controller, .retire, output: output)
        XCTAssertEqual(output.messages.last?.body, .retired(.init(nativeErrno: ETIMEDOUT, vkResult: nil)))
        XCTAssertEqual(controller.retainedCount, 1)
        XCTAssertThrowsError(try consume(controller, .present(request(1)), output: output))
        XCTAssertThrowsError(try controller.retireProcess(1))
        XCTAssertEqual(controller.retainedCount, 1)
        backend.resource.retirementError = 0
        try controller.retireProcess(1)
        XCTAssertEqual(controller.retainedCount, 0)
    }
    func testProviderErrorIsPreservedWithoutPartialCapabilities() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        try consume(controller, .query(request: 8, physicalDevice: 9), output: output)
        XCTAssertEqual(output.messages.last?.body,
                       .capabilities(request: 8, status: .init(nativeErrno: EIO, vkResult: -4), value: nil))
    }
    func testRejectedNextPresentDoesNotDiscardPriorCallbacks() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        backend.resource.submissions = [queued, .init(status: .init(nativeErrno: EBUSY, vkResult: nil), disposition: .rejected)]
        try consume(controller, .present(request(1)), output: output)
        try consume(controller, .present(request(2)), output: output)
        backend.resource.callbacks[0](.sourceReleased(serial: 1))
        XCTAssertEqual(output.messages.last?.body, .sourceReleased(serial: 1))
        XCTAssertThrowsError(try consume(controller, .present(request(2)), output: output))
        XCTAssertTrue(output.errors.isEmpty)
    }
    func testNativeProcessFinishCannotBypassFailedSurfaceRetirement() throws {
        let backend = TestSurfaceBackend(), runtime = SurfaceRuntime()
        let controller = LiveGPUSurfaceController(backend: backend)
        let binding = try LiveGPUNativeBinding(backend: runtime, surfaces: controller)
        try binding.start(output: { _ in true }, failed: { _ in })
        let executor = Data(repeating: 9, count: 16)
        func frame(_ kind: LiveGPUEnvelope.Kind, _ seq: UInt64, process: UInt64 = 0, payload: Data = Data()) throws {
            try binding.consume(LiveGPUEnvelope(kind: kind, executor: executor, generation: 1,
                process: process, stream: 0, sequence: seq, payload: payload).encoded())
        }
        try frame(.session, 1, payload: LiveGPUEnvelope.hello)
        try frame(.processOpen, 2, process: 1)
        let bind = LiveGPUSurfaceMessage(identity: identity,
            body: .bind(window: 7, instance: 8, width: 800, height: 600))
        try frame(.surfaceBind, 3, process: 1, payload: bind.encoded())
        backend.resource.retirementError = ETIMEDOUT
        XCTAssertThrowsError(try frame(.processStop, 4, process: 1))
        XCTAssertEqual(runtime.finishes, 0)
        XCTAssertThrowsError(try binding.finish())
        XCTAssertEqual(runtime.finishes, 0)
        XCTAssertEqual(controller.retainedCount, 1)
    }
    func testOwnerRevokeIsIdempotentAndWaitsForActualPeerRetirement() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        try bind(controller, output)
        backend.resource.submissions = [queued]
        try consume(controller, .present(request(1)), output: output)
        let stale = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: identity.grant, generation: 2)
        try controller.requestRevocation(stale) { _, _ in XCTFail("stale local view revoked a live grant") }
        for _ in 0..<2 {
            try controller.requestRevocation(identity) { process, message in
                XCTAssertEqual(process, 1); output.append(message)
            }
        }
        XCTAssertEqual(output.messages.filter { $0.kind == .surfaceRevokeRequest }.count, 1)
        XCTAssertEqual(controller.retainedCount, 1)
        XCTAssertEqual(backend.resource.retired, 0)
        // Already-running copy/device callbacks survive the revoke request.
        backend.resource.callbacks[0](.sourceReleased(serial: 1))
        XCTAssertEqual(output.messages.last?.kind, .sourceReleased)
        try consume(controller, .query(request: 2, physicalDevice: 9), output: output)
        XCTAssertEqual(output.messages.last?.body,
            .capabilities(request: 2, status: .init(nativeErrno: ESTALE, vkResult: nil), value: nil))
        try consume(controller, .present(request(2)), output: output)
        XCTAssertEqual(output.messages.last?.body,
            .presentResult(serial: 2, status: .init(nativeErrno: ESTALE, vkResult: nil), disposition: .rejected, event: .submission))
        XCTAssertEqual(backend.resource.callbacks.count, 1)
        try consume(controller, .retire, output: output)
        XCTAssertEqual(controller.retainedCount, 0)
        XCTAssertEqual(backend.resource.retired, 1)
        try controller.requestRevocation(identity) { _, _ in XCTFail("retired local view emitted a revoke") }
        XCTAssertThrowsError(try consume(controller, .retire, output: output)) // Peer duplicates stay strict.
    }

    func testLocalSurfaceRevokePreservesNativeProcessUntilProcessStop() throws {
        let backend = TestSurfaceBackend(), runtime = SurfaceRuntime(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend)
        let binding = try LiveGPUNativeBinding(backend: runtime, surfaces: controller)
        let executor = Data(repeating: 9, count: 16)
        let parser = try LiveGPUEnvelopeDecoder(executor: executor, generation: 1)
        try binding.start(output: { bytes in
            do {
                try parser.feed(bytes) { frame in
                    if frame.kind.isSurface {
                        output.append(try LiveGPUSurfaceMessage.decode(kind: frame.kind, payload: frame.payload))
                    }
                }
                return true
            } catch { output.fail(error); return false }
        }, failed: { output.fail($0) })
        func frame(_ kind: LiveGPUEnvelope.Kind, _ seq: UInt64, process: UInt64 = 0, payload: Data = Data()) throws {
            try binding.consume(LiveGPUEnvelope(kind: kind, executor: executor, generation: 1,
                process: process, stream: 0, sequence: seq, payload: payload).encoded())
        }
        try frame(.session, 1, payload: LiveGPUEnvelope.hello)
        try frame(.processOpen, 2, process: 1)
        try frame(.surfaceBind, 3, process: 1, payload: LiveGPUSurfaceMessage(identity: identity,
            body: .bind(window: 7, instance: 8, width: 800, height: 600)).encoded())
        try binding.requestSurfaceRevocation(identity)
        XCTAssertEqual(output.messages.last?.kind, .surfaceRevokeRequest)
        XCTAssertEqual(runtime.finishes, 0)
        XCTAssertEqual(backend.resource.retired, 0)
        try frame(.surfaceRetire, 4, process: 1,
                  payload: LiveGPUSurfaceMessage(identity: identity, body: .retire).encoded())
        XCTAssertEqual(output.messages.last?.kind, .surfaceRetired)
        XCTAssertEqual(runtime.finishes, 0)
        try frame(.processStop, 5, process: 1)
        XCTAssertEqual(runtime.finishes, 1)
        try binding.finish()
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testBoundedSurfaceAdmission() throws {
        let backend = TestSurfaceBackend(), output = SurfaceOutput()
        let controller = LiveGPUSurfaceController(backend: backend, limit: 1)
        try bind(controller, output)
        let next = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: Data(repeating: 3, count: 16), generation: 1)
        try consume(controller, .bind(window: 8, instance: 8, width: 800, height: 600), output: output, identity: next)
        XCTAssertEqual(output.messages.last?.body, .bound(.init(nativeErrno: ENOSPC, vkResult: nil)))
        XCTAssertEqual(backend.bindings.count, 1)
        XCTAssertEqual(controller.retainedCount, 2)
        try consume(controller, .retire, output: output, identity: next)
        XCTAssertEqual(controller.retainedCount, 1)
        XCTAssertEqual(backend.resource.retired, 0)
    }

    #if canImport(UIKit)
    @MainActor
    func testPresentationOwnerInvalidationDetachesLayerViewImmediatelyAndRetainsLeaseUntilRelease() throws {
        let stream = MockStream()
        let decoder = FakeDecoder()
        let display = DisplayInfo(id: 0, width: 1600, height: 1200, scale: 2, refreshHz: 120)
        let session = CabooseDisplaySession(stream: { stream }, token: "wake", displays: [display],
                                            decoders: [.hevc, .h264], makeDecoder: { _ in decoder })
        let surface = WindowSurface()
        surface.resize(width: 800, height: 600)
        let window = RemoteWindow(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  overrideRedirect: false, surface: surface)
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        host.isHidden = false  // a UIWindow starts hidden: nothing in it is visible
        let view = RemoteWindowView(session: session, window: window)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.addSubview(view)

        var invalidatedIdentities: [LiveGPUSurfaceIdentity] = []
        let owners = LiveGPUPresentationOwners { invalidatedIdentities.append($0) }
        owners.update(epoch: identity.epoch, windows: [7: window])
        view.layoutLiveGPU()

        var claimed: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: identity, windowID: 7) { claimed = $0 }
        let lease = try XCTUnwrap(claimed?.get())
        let layerView = try XCTUnwrap(lease.content)
        XCTAssertTrue(layerView.superview === view)
        XCTAssertTrue(lease.isValid)

        // A view that stops showing the window parks the lease: the layer leaves the
        // view so the picture underneath is not covered, but the binding stays valid
        // and the guest is never asked to give up its surface.
        owners.withdraw(view)
        XCTAssertTrue(invalidatedIdentities.isEmpty)
        XCTAssertTrue(lease.isValid)
        XCTAssertTrue(lease.parked)
        XCTAssertNil(layerView.superview)
        XCTAssertNotNil(lease.layer)

        // A bound window takes no second claim while its lease is parked.
        let nextIdentity = LiveGPUSurfaceIdentity(epoch: identity.epoch, grant: Data(repeating: 4, count: 16), generation: 2)
        var busyClaim: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: nextIdentity, windowID: 7) { busyClaim = $0 }
        XCTAssertThrowsError(try XCTUnwrap(busyClaim).get())

        // Showing the window again restores the same layer, with its latest frame.
        view.layoutLiveGPU()
        XCTAssertFalse(lease.parked)
        XCTAssertTrue(layerView.superview === view)

        // A change of window identity ends the lease and asks the guest to retire it.
        let replacement = RemoteWindow(id: 7, frame: window.frame, overrideRedirect: false, surface: surface)
        owners.update(epoch: identity.epoch, windows: [7: replacement])
        XCTAssertEqual(invalidatedIdentities, [identity])
        XCTAssertFalse(lease.isValid)
        XCTAssertNil(layerView.superview)
        XCTAssertNotNil(lease.content)
        owners.update(epoch: identity.epoch, windows: [7: window])

        // While the old lease is still unreleased by native detach, a new claim is refused.
        var secondClaim: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: nextIdentity, windowID: 7) { secondClaim = $0 }
        XCTAssertThrowsError(try XCTUnwrap(secondClaim).get())

        // After native retirement releases the old lease, a new grant can claim and attach.
        owners.release(lease)
        XCTAssertNil(lease.content)
        owners.requestClaim(identity: nextIdentity, windowID: 7) { secondClaim = $0 }
        let nextLease = try XCTUnwrap(secondClaim?.get())
        let nextLayerView = try XCTUnwrap(nextLease.content)
        XCTAssertTrue(nextLayerView.superview === view)

        // Executor session revoke also immediately removes the GPU presentation view from RemoteWindowView.
        owners.revoke()
        XCTAssertFalse(nextLease.isValid)
        XCTAssertNil(nextLayerView.superview)
        XCTAssertNotNil(nextLease.content)
        owners.release(nextLease)
        XCTAssertNil(nextLease.content)
    }

    @MainActor
    func testHidingTheWindowParksTheLeaseAndShowingItRestoresTheLayer() throws {
        let stream = MockStream()
        let decoder = FakeDecoder()
        let display = DisplayInfo(id: 0, width: 1600, height: 1200, scale: 2, refreshHz: 120)
        let session = CabooseDisplaySession(stream: { stream }, token: "wake", displays: [display],
                                            decoders: [.hevc, .h264], makeDecoder: { _ in decoder })
        let surface = WindowSurface()
        surface.resize(width: 800, height: 600)
        let window = RemoteWindow(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  overrideRedirect: false, surface: surface)
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        host.isHidden = false  // a UIWindow starts hidden: nothing in it is visible
        let tab = UIView(frame: host.bounds)
        host.addSubview(tab)
        let view = RemoteWindowView(session: session, window: window)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.addSubview(view)

        var invalidatedIdentities: [LiveGPUSurfaceIdentity] = []
        let owners = LiveGPUPresentationOwners { invalidatedIdentities.append($0) }
        owners.update(epoch: identity.epoch, windows: [7: window])
        view.layoutLiveGPU()
        var claimed: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: identity, windowID: 7) { claimed = $0 }
        let lease = try XCTUnwrap(claimed?.get())
        let layerView = try XCTUnwrap(lease.content)

        // Another tab covers the desktop: the lease parks, still bound and presenting.
        tab.isHidden = true
        view.layoutLiveGPU()
        XCTAssertTrue(lease.parked)
        XCTAssertTrue(lease.isValid)
        XCTAssertNil(layerView.superview)
        XCTAssertNotNil(lease.layer)
        // The guest may still reconfigure its swapchain while hidden.
        XCTAssertEqual(lease.configurePresentationExtent(CGSize(width: 800, height: 600)) { _ in 0 }, 0)

        // The desktop tab's view is rebuilt: the new view takes the same layer.
        view.removeFromSuperview()
        let rebuilt = RemoteWindowView(session: session, window: window)
        rebuilt.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        tab.isHidden = false
        tab.addSubview(rebuilt)
        rebuilt.layoutLiveGPU()
        XCTAssertFalse(lease.parked)
        XCTAssertTrue(layerView.superview === rebuilt)
        XCTAssertTrue(invalidatedIdentities.isEmpty)
        owners.revoke()
        owners.release(lease)
    }

    @MainActor
    func testClaimWithNoViewShowingTheWindowBindsParkedAtTheServerExtent() throws {
        let surface = WindowSurface()
        surface.resize(width: 800, height: 600)
        let window = RemoteWindow(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  overrideRedirect: false, surface: surface)
        let owners = LiveGPUPresentationOwners { _ in XCTFail("no invalidation expected") }
        owners.update(epoch: identity.epoch, windows: [7: window])
        var claimed: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: identity, windowID: 7) { claimed = $0 }
        let lease = try XCTUnwrap(claimed?.get())
        XCTAssertTrue(lease.parked)
        XCTAssertEqual(lease.extent, CGSize(width: 800, height: 600))
        XCTAssertEqual(lease.layer?.drawableSize, CGSize(width: 800, height: 600))
        owners.release(lease)
    }

    @MainActor
    func testPresentationOwnerGeometryResizePreservesLeaseAndFitsLayerViewWithoutRevokingSurface() throws {
        let stream = MockStream()
        let decoder = FakeDecoder()
        let display = DisplayInfo(id: 0, width: 1356, height: 932, scale: 2, refreshHz: 120)
        let session = CabooseDisplaySession(stream: { stream }, token: "wake", displays: [display],
                                            decoders: [.hevc, .h264], makeDecoder: { _ in decoder })
        let surface = WindowSurface()
        surface.resize(width: 1356, height: 932)
        let window = RemoteWindow(id: 7, frame: CGRect(x: 0, y: 0, width: 1356, height: 932),
                                  overrideRedirect: false, surface: surface)
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 678, height: 466))
        host.isHidden = false  // a UIWindow starts hidden: nothing in it is visible
        let view = RemoteWindowView(session: session, window: window)
        view.frame = CGRect(x: 0, y: 0, width: 678, height: 466)
        host.addSubview(view)

        var invalidatedIdentities: [LiveGPUSurfaceIdentity] = []
        let owners = LiveGPUPresentationOwners { invalidatedIdentities.append($0) }
        owners.update(epoch: identity.epoch, windows: [7: window])
        view.layoutLiveGPU()

        var claimed: Result<LiveGPULayerLease, Error>?
        owners.requestClaim(identity: identity, windowID: 7) { claimed = $0 }
        let lease = try XCTUnwrap(claimed?.get())
        let layerView = try XCTUnwrap(lease.content)
        XCTAssertEqual(lease.extent, CGSize(width: 1356, height: 932))
        XCTAssertTrue(lease.isValid)

        // Simulate Chrome configuring its swapchain at a different drawable size (e.g., 943x648),
        // then the user rotating/resizing the window and view (1356x932 -> 1021x691).
        XCTAssertEqual(lease.configurePresentationExtent(CGSize(width: 943, height: 648)) { _ in 0 }, 0)
        window.frame = CGRect(x: 0, y: 0, width: 1021, height: 691)
        view.frame = CGRect(x: 0, y: 0, width: 510.5, height: 345.5)
        owners.update(epoch: identity.epoch, windows: [7: window])
        view.layoutLiveGPU()

        XCTAssertTrue(lease.isValid)
        XCTAssertTrue(invalidatedIdentities.isEmpty)
        XCTAssertEqual(lease.extent, CGSize(width: 1021, height: 691))
        XCTAssertEqual(layerView.frame.size, CGSize(width: 510.5, height: 345.5))
        XCTAssertTrue(layerView.superview === view)
        // Swapchain recreation at the new size succeeds on the preserved lease.
        XCTAssertEqual(lease.configurePresentationExtent(CGSize(width: 1021, height: 691)) { _ in 0 }, 0)
        XCTAssertEqual(lease.layer?.drawableSize, CGSize(width: 1021, height: 691))

        // Invalid/zero geometry still invalidates the lease and detaches the layer view.
        window.frame = .zero
        owners.update(epoch: identity.epoch, windows: [7: window])
        XCTAssertFalse(lease.isValid)
        XCTAssertEqual(invalidatedIdentities, [identity])
        XCTAssertNil(layerView.superview)
        owners.release(lease)
    }
    #endif
}
