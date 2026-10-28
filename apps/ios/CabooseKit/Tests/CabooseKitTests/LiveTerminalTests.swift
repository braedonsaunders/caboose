import Foundation
import Testing
@testable import CabooseKit

/// Opens a terminal on a real computer through caboose-host, as the app does, over
/// URLSession: a new session that runs a command, a resize, a reattach that continues from
/// its offset, a second device taking the session over, and an exit:
///
///     CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… swift test --filter LiveTerminal
///
/// Skipped without `CABOOSE_HOST_URL`. Wakes a parked computer.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] != nil))
struct LiveTerminalTests {
    let host = URL(string: ProcessInfo.processInfo.environment["CABOOSE_HOST_URL"] ?? "http://127.0.0.1:1")!
    let token = ProcessInfo.processInfo.environment["CABOOSE_HOST_TOKEN"] ?? ""

    /// One connection and everything it reported.
    final class Probe: @unchecked Sendable {
        let connection: TerminalConnection
        private let lock = NSLock()
        private var output = ""
        private var hello: TerminalHello?
        private var end: TerminalEnd?

        init(_ url: URL, token: String) {
            connection = TerminalConnection(transport: URLSessionTerminalTransport(url: url, token: token))
            connection.start { [self] event in
                lock.withLock {
                    switch event {
                    case .connected(let value): hello = value
                    case .output(let data): output += String(decoding: data, as: UTF8.self)
                    case .ended(let value): end = value
                    }
                }
            }
        }

        var text: String { lock.withLock { output } }
        var greeting: TerminalHello? { lock.withLock { hello } }
        var ending: TerminalEnd? { lock.withLock { end } }

        func wait(_ what: String, seconds: Double = 60, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline { throw LiveError.timedOut(what, text.suffix(400).description) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        func run(_ command: String, until marker: String) async throws {
            connection.send(input: Data("\(command)\r".utf8))
            try await wait(command) { text.contains(marker) }
        }
    }

    enum LiveError: Error { case timedOut(String, String) }

    @Test func opensRunsResizesReattachesAndExits() async throws {
        let first = Probe(TerminalProtocol.url(base: host, columns: 80, rows: 24, session: nil, offset: nil, wake: true), token: token)
        try await first.wait("hello", seconds: 300) { first.greeting != nil }
        let session = try #require(first.greeting?.session)
        #expect(first.greeting?.reset == true)
        try await first.run("echo \"swift-$((6*7)) $TERM\"", until: "swift-42 xterm-256color")
        first.connection.resize(columns: 120, rows: 33)
        try await first.run("stty size", until: "33 120")

        first.connection.send(input: Data("sleep 1; echo \"later-$((40+2))\"\r".utf8))
        try await first.wait("typed") { first.text.contains("sleep 1") }
        let offset = first.connection.offset
        first.connection.close()
        try await Task.sleep(for: .seconds(2))

        let second = Probe(TerminalProtocol.url(base: host, columns: 90, rows: 20, session: session, offset: offset, wake: true), token: token)
        try await second.wait("reattach") { second.greeting != nil }
        #expect(second.greeting == TerminalHello(session: session, offset: offset, reset: false))
        try await second.wait("replay") { second.text.contains("later-42") }
        #expect(!second.text.contains("stty size"))

        // Another device takes the session; this one is told so.
        let third = Probe(TerminalProtocol.url(base: host, columns: 90, rows: 20, session: session, offset: nil, wake: true), token: token)
        try await third.wait("takeover") { third.greeting?.reset == true }
        try await second.wait("replaced") { second.ending != nil }
        #expect(second.ending == .replaced)

        third.connection.send(input: Data("exit 7\r".utf8))
        try await third.wait("exit") { third.ending != nil }
        #expect(third.ending == .exited(code: 7, signal: nil))

        let gone = Probe(TerminalProtocol.url(base: host, columns: 80, rows: 24, session: session, offset: nil, wake: true), token: token)
        try await gone.wait("ended session") { gone.ending != nil }
        #expect(gone.ending == .sessionEnded)

        let refused = Probe(TerminalProtocol.url(base: host, columns: 80, rows: 24, session: nil, offset: nil, wake: true), token: "wrong")
        try await refused.wait("refusal") { refused.ending != nil }
        #expect(refused.ending == .unauthorized)
    }
}
