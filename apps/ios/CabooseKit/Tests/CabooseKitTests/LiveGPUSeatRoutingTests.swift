import Foundation
import XCTest
@testable import CabooseKit

/// One executor serves both of the computer's seats (docs/gpu-live.md, "Seats"): each bind
/// carries its seat, presents in that seat's display session only, and is answered and dropped
/// while that seat has no session.
final class LiveGPUSeatRoutingTests: XCTestCase {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var messages: [LiveGPUSurfaceMessage] = []
        var errors: [Error] = []
        func append(_ message: LiveGPUSurfaceMessage) { lock.withLock { messages.append(message) } }
        func fail(_ error: Error) { lock.withLock { errors.append(error) } }
    }
    private final class Resource: LiveGPUSurfaceResource, @unchecked Sendable {
        var retired = 0
        func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
            (.init(nativeErrno: 0, vkResult: -1), nil)
        }
        func present(_ request: LiveGPUSurfacePresent,
                     event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
            .init(status: .init(nativeErrno: 0, vkResult: 0), disposition: .queued)
        }
        func retire() throws { retired += 1 }
    }
    /// One seat's display session: records what it was asked to show.
    private final class SeatDisplay: LiveGPUSurfaceBackend, @unchecked Sendable {
        let resource = Resource()
        var windows: [UInt64] = []
        var seats: [LiveGPUSeat] = []
        func bind(identity: LiveGPUSurfaceIdentity, processToken: UInt64, window: UInt64,
                  instance: UInt64, width: UInt32, height: UInt32, seat: LiveGPUSeat) throws -> LiveGPUSurfaceBinding {
            windows.append(window); seats.append(seat)
            return .init(status: .init(nativeErrno: 0, vkResult: nil), resource: resource)
        }
    }

    private func identity(_ grant: UInt8) -> LiveGPUSurfaceIdentity {
        .init(epoch: Data(repeating: 1, count: 16), grant: Data(repeating: grant, count: 16), generation: 1)
    }
    private func consume(_ controller: LiveGPUSurfaceController, _ message: LiveGPUSurfaceMessage,
                         _ output: Output) throws {
        try controller.consume(message, process: 1, token: 9,
                               output: { _, reply in output.append(reply) }, failed: { output.fail($0) })
    }
    private func boundErrno(_ output: Output, _ grant: UInt8) -> Int32? {
        for message in output.messages where message.identity.grant == Data(repeating: grant, count: 16) {
            if case .bound(let status) = message.body { return status.nativeErrno }
        }
        return nil
    }

    func testABindCarriesItsSeatInSeventyTwoBytes() throws {
        let agent = LiveGPUSurfaceMessage(identity: identity(2),
            body: .bind(window: 7, instance: 8, width: 640, height: 480, seat: LiveGPUSeat.agent.rawValue))
        let bytes = try agent.encoded()
        XCTAssertEqual(bytes.count, 72)
        XCTAssertEqual(bytes.suffix(8), Data([1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: bytes), agent)

        // The owner's seat keeps the 64-byte record, and a 64-byte record is the owner's.
        let owner = LiveGPUSurfaceMessage(identity: identity(2), body: .bind(window: 7, instance: 8, width: 640, height: 480))
        let short = try owner.encoded()
        XCTAssertEqual(short.count, 64)
        XCTAssertEqual(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: short).body,
                       .bind(window: 7, instance: 8, width: 640, height: 480, seat: 0))

        // An unknown seat, a reserved word that is not zero, or any other length is refused.
        var unknown = bytes; unknown[64] = 2
        XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: unknown))
        var reserved = bytes; reserved[68] = 1
        XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: reserved))
        XCTAssertThrowsError(try LiveGPUSurfaceMessage.decode(kind: .surfaceBind, payload: bytes.prefix(68)))
    }

    func testEachBindPresentsInItsOwnSeatsDisplay() throws {
        let owner = SeatDisplay(), agent = SeatDisplay()
        let seats = LiveGPUSeatSurfaces(owner: owner)
        seats.attach(agent, seat: .agent)
        let controller = LiveGPUSurfaceController(backend: seats)
        let output = Output()
        try consume(controller, .init(identity: identity(2), body: .bind(window: 7, instance: 8, width: 0, height: 0)), output)
        try consume(controller, .init(identity: identity(3),
            body: .bind(window: 9, instance: 8, width: 0, height: 0, seat: LiveGPUSeat.agent.rawValue)), output)
        XCTAssertEqual(owner.windows, [7]); XCTAssertEqual(owner.seats, [.owner])
        XCTAssertEqual(agent.windows, [9]); XCTAssertEqual(agent.seats, [.agent])
        XCTAssertEqual(boundErrno(output, 2), 0)
        XCTAssertEqual(boundErrno(output, 3), 0)
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testAnAgentSeatWindowWithNoSessionIsAnsweredAndNeverShownToTheOwner() throws {
        let owner = SeatDisplay(), agent = SeatDisplay()
        let seats = LiveGPUSeatSurfaces(owner: owner)
        let controller = LiveGPUSurfaceController(backend: seats)
        let output = Output()
        try consume(controller, .init(identity: identity(3),
            body: .bind(window: 9, instance: 8, width: 0, height: 0, seat: LiveGPUSeat.agent.rawValue)), output)
        XCTAssertEqual(boundErrno(output, 3), ENOENT)
        XCTAssertTrue(owner.windows.isEmpty, "an agent-seat window never presents in the owner's display")
        // Its grant retires like any failed bind.
        try consume(controller, .init(identity: identity(3), body: .retire), output)
        XCTAssertTrue(output.messages.contains { if case .retired = $0.body { return true }; return false })

        // Once the Watch view opens the agent seat, its next bind presents there; closing it again
        // refuses the binds after it.
        seats.attach(agent, seat: .agent)
        try consume(controller, .init(identity: identity(4),
            body: .bind(window: 9, instance: 8, width: 0, height: 0, seat: LiveGPUSeat.agent.rawValue)), output)
        XCTAssertEqual(agent.windows, [9])
        seats.attach(nil, seat: .agent)
        try consume(controller, .init(identity: identity(5),
            body: .bind(window: 10, instance: 8, width: 0, height: 0, seat: LiveGPUSeat.agent.rawValue)), output)
        XCTAssertEqual(boundErrno(output, 5), ENOENT)
        XCTAssertEqual(agent.windows, [9])
        XCTAssertTrue(owner.windows.isEmpty)
        XCTAssertTrue(output.errors.isEmpty)
    }
}
