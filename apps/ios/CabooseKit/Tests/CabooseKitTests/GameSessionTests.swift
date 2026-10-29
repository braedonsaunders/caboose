import Foundation
import Testing
@testable import CabooseKit

/// A display session's side of game handoff (docs/display.md, "Game handoff"): the hello
/// says the client runs games, `game.create` and `game.destroy` set and clear the window's
/// game, and a resumed connection keeps a game the server still has.
@MainActor @Suite(.serialized) struct GameSessionTests {
    let resume = DisplayResumeTests()
    var helpers: CabooseDisplaySessionTests { resume.helpers }

    func game(_ id: Int, window: Int, saves: Bool = true) -> CBOR {
        var pairs: [(CBOR, CBOR)] = [("id", CBOR(id)), ("window", CBOR(window)), ("root", "Games/powder/web"), ("entry", "index.html")]
        if saves { pairs.append(("saves", [["mount": "/powder", "path": ".local/share/The Powder Toy"]])) }
        return .map(pairs)
    }

    func makeSession(runsGames: Bool = true) -> CabooseDisplaySession {
        let session = resume.makeSession()
        session.runsGames = runsGames
        return session
    }

    @Test func runningGamesNeedsWebKit() {
        #expect(resume.makeSession().runsGames == RemoteGame.isSupported)
    }

    @Test func theHelloSaysWhetherTheClientRunsGames() async throws {
        for runs in [true, false] {
            let session = makeSession(runsGames: runs)
            session.connect()
            let stream = resume.streams.last
            stream.deliver(.opened)
            try await helpers.until("hello") { session.state == .authenticating }
            let hello = try #require(stream.take().first)
            #expect(hello.body["wasm"] == (runs ? .bool(true) : nil))
            session.disconnect()
        }
    }

    @Test func gameCreateAndDestroySetAndClearTheWindowsGame() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7, 8])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        #expect(game.descriptor == GameDescriptor(id: 1, window: 7, root: "Games/powder/web", entry: "index.html",
                                                  saves: [GameSave(mount: "/powder", path: ".local/share/The Powder Toy")]))
        #expect(game.picture === session.windows[7]?.surface)
        #expect(session.windows[8]?.game == nil)

        resume.streams.last.server([(.gameDestroy, ["id": 2])]) // not this one
        resume.streams.last.server([(.gameDestroy, ["id": 1])])
        try await helpers.until("game over") { session.windows[7]?.game == nil }
        #expect(game.isEnded)
        #expect(session.windows[7] != nil) // the window stays until the server withdraws it
    }

    @Test func aClientThatDoesNotRunGamesIgnoresThem() async throws {
        let session = makeSession(runsGames: false)
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7)), (.gameCreate, game(2, window: 99))])
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.windows[7]?.game == nil)
    }

    @Test func aGameForAnUnknownWindowIsIgnored() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(2, window: 99)), (.gameCreate, game(3, window: 7, saves: false))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        #expect(session.windows[7]?.game?.id == 3 && session.windows[7]?.game?.descriptor.saves == [])
    }

    @Test func anotherGameInTheWindowReplacesTheFirst() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let first = try #require(session.windows[7]?.game)
        resume.streams.last.server([(.gameCreate, game(1, window: 7))]) // the same again: kept
        resume.streams.last.server([(.gameCreate, game(2, window: 7))])
        try await helpers.until("second") { session.windows[7]?.game?.id == 2 }
        #expect(first.isEnded)
    }

    @Test func theWindowGoingEndsItsGame() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        resume.streams.last.server([(.windowDestroy, ["id": 7])])
        try await helpers.until("window gone") { session.windows[7] == nil }
        #expect(game.isEnded)
    }

    @Test func disconnectingEndsEveryGame() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        session.disconnect()
        #expect(game.isEnded)
    }

    /// A lost connection keeps the game running; the same server announcing it again keeps
    /// its object (and with it the running page).
    @Test func theSameEpochKeepsTheGameItAnnouncesAgain() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7, 8])
        resume.streams.last.server([(.gameCreate, game(1, window: 7)), (.gameCreate, game(2, window: 8))])
        try await helpers.until("games") { session.windows[7]?.game != nil && session.windows[8]?.game != nil }
        let kept = try #require(session.windows[7]?.game), ended = try #require(session.windows[8]?.game)
        try await resume.dropAndResume(session)
        #expect(session.windows[7]?.game === kept && !kept.isEnded)

        let marker = try #require(try await resume.handshake(session, epoch: "e1", windows: [7, 8]))
        resume.streams.last.server([(.gameCreate, game(1, window: 7)), (.pong, ["t_us": CBOR(marker)])])
        try await helpers.until("announced") { session.windowsAnnounced == 1 }
        #expect(session.windows[7]?.game === kept && !kept.isEnded)
        #expect(session.windows[8] != nil && session.windows[8]?.game == nil && ended.isEnded)
    }

    @Test func anotherEpochEndsTheGames() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        try await resume.dropAndResume(session)
        try await resume.handshake(session, epoch: "e2", windows: [7])
        #expect(game.isEnded)
        #expect(session.windows[7]?.game == nil)
    }

    @Test func closingAGameWindowWaitsForItsSaves() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7, 8])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let window = try #require(session.windows[7]), plain = try #require(session.windows[8])
        _ = resume.streams.last.take()

        var flushed = false
        window.game?.savesFlusher = {
            try? await Task.sleep(for: .milliseconds(100))
            flushed = true
        }
        let close = DisplayProtocol.ClientType.close.rawValue
        session.close(window)
        #expect(!resume.streams.last.take().contains { $0.type == close })
        var closes: [DisplayFrame] = []
        try await helpers.until("close") {
            closes += resume.streams.last.take().filter { $0.type == close }
            return !closes.isEmpty
        }
        #expect(flushed)
        #expect(closes.map { $0.body["id"]?.int } == [7])

        session.close(plain) // no game: at once
        #expect(resume.streams.last.take().filter { $0.type == close }.map { $0.body["id"]?.int } == [8])
    }

    /// Input addressed to a game window is the game's, on the device; configure still goes.
    @Test func nothingTypedOrTouchedInAGameWindowGoesToTheComputer() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let window = try #require(session.windows[7])
        _ = resume.streams.last.take()
        let stroke = KeyStroke(name: "a", keyval: 0x61, string: "a")
        session.key(stroke, pressed: true, in: window)
        session.type("hello", in: window)
        session.edit([.type("x"), .backspace(2)], in: window)
        session.compose("に", selection: NSRange(location: 1, length: 0), in: window)
        session.pointerMove(in: window, to: CGPoint(x: 1, y: 1))
        session.pointerButton(in: window, button: 1, pressed: true, at: CGPoint(x: 1, y: 1))
        session.scroll(in: window, dx: 0, dy: 4, at: CGPoint(x: 1, y: 1))
        session.touch([TouchPoint(slot: 0, phase: .down, x: 1, y: 1)], in: window)
        session.pencil(PencilSample(phase: .down, x: 1, y: 1, pressure: 1, tilt: (0, 0), azimuth: 0), in: window)
        let input: Set<UInt8> = [DisplayProtocol.ClientType.key.rawValue, DisplayProtocol.ClientType.text.rawValue,
                                 DisplayProtocol.ClientType.pointer.rawValue, DisplayProtocol.ClientType.touch.rawValue,
                                 DisplayProtocol.ClientType.pencil.rawValue]
        #expect(!resume.streams.last.take().contains { input.contains($0.type) })
        session.configure(window, frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(resume.streams.last.take().contains { $0.type == DisplayProtocol.ClientType.configure.rawValue })
    }

    @Test func theWaitForSavesIsBounded() async {
        let game = RemoteGame(GameDescriptor(id: 1, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface())
        game.savesFlusher = { try? await Task.sleep(for: .seconds(30)) }
        let start = Date()
        await game.flushSaves(within: 0.1)
        #expect(Date().timeIntervalSince(start) < 5)
        await RemoteGame(GameDescriptor(id: 2, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface()).flushSaves(within: 5)
    }

    @Test func gamesReachTheHostBehindTheDisplay() {
        let session = CabooseDisplaySession(displayURL: URL(string: "wss://computer.example/v1/display")!, token: "owner", password: "p",
                                            capabilities: ClientCapabilities(desktopWidth: 100, desktopHeight: 100, dpi: 192))
        #expect(session.gameHost == GameHostAccess(baseURL: URL(string: "https://computer.example")!, token: "owner"))
    }

    @Test func theGamepadReachesTheLivePageOnChange() {
        let game = RemoteGame(GameDescriptor(id: 1, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface())
        var delivered: [GameGamepadState?] = []
        game.gamepadSink = { delivered.append($0) }
        var state = GameGamepadState()
        state[.start] = 1
        game.gamepad = state
        game.gamepad = state
        game.gamepad = nil
        #expect(delivered == [state, nil])
        game.end()
        game.gamepad = state
        #expect(delivered.count == 2)
    }
}
