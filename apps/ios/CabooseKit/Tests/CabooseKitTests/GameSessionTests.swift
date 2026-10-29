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
        session.playsAudio = false
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
            #expect(hello.body["webview"] == (runs ? .bool(true) : nil))
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

    func webview(_ grant: String) -> CBOR {
        ["id": 4, "window": 7, "app": "notes", "root": "Apps/notes", "entry": "index.html",
         "bridge": "0123456789abcdef0123456789abcdef", "grant": CBOR(grant)]
    }

    @Test func webviewTakeoverReplacesTheOldDocumentAndDeclinesAsWebview() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        let first = String(repeating: "a", count: 32), second = String(repeating: "b", count: 32)
        resume.streams.last.server([(.webviewCreate, webview(first))])
        try await helpers.until("webview") { session.windows[7]?.game?.webview != nil }
        let old = try #require(session.windows[7]?.game)
        resume.streams.last.server([(.webviewCreate, webview(second))])
        try await helpers.until("new grant") { session.windows[7]?.game?.webview?.grant == second }
        #expect(old.isEnded)
        let current = try #require(session.windows[7]?.game)
        _ = resume.streams.last.take()
        current.decline("cannot serve")
        var sent: [DisplayFrame] = []
        try await helpers.until("webview decline") {
            sent += resume.streams.last.take().filter { $0.type == DisplayProtocol.ClientType.webviewDecline.rawValue }
            return !sent.isEmpty
        }
        #expect(sent.first?.body["id"]?.int == 4)
        resume.streams.last.server([(.webviewDestroy, ["id": 4])])
        try await helpers.until("webview ended") { session.windows[7]?.game == nil }
        #expect(current.isEnded)
        session.disconnect()
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

    @Test func aPendingGameCloseCannotReachAReplacementConnection() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let window = try #require(session.windows[7])
        var gate: CheckedContinuation<Void, Never>?
        window.game?.savesFlusher = {
            await withCheckedContinuation { gate = $0 }
        }
        session.close(window)
        try await helpers.until("save wait") { gate != nil }
        try await resume.dropAndResume(session)
        try await resume.handshake(session, epoch: "e2", windows: [7])
        let replacement = try #require(session.windows[7])
        #expect(replacement !== window)
        _ = resume.streams.last.take()
        gate?.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!resume.streams.last.take().contains { $0.type == DisplayProtocol.ClientType.close.rawValue })
        session.close(replacement)
        #expect(resume.streams.last.take().contains { $0.type == DisplayProtocol.ClientType.close.rawValue })
        session.disconnect()
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
        session.disconnect()
    }

    /// The trackpad and keyboard aimed at a game window reach its page; what it holds is
    /// released when another window takes the input and when the connection goes.
    @Test func theAppsControlsReachTheGamesPageAndLetGo() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7, 8])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let window = try #require(session.windows[7])
        let game = try #require(window.game)
        var delivered: [GameInputEvent] = []
        game.inputSink = { delivered += $0 }
        let size = window.frame.size
        session.pointerMove(in: window, to: CGPoint(x: size.width / 2, y: size.height / 4))
        session.pointerButton(in: window, button: 1, pressed: true, at: CGPoint(x: size.width / 2, y: size.height / 4))
        session.key(Keysyms.special["Right"]!, pressed: true, in: window)
        session.type("z", in: nil)
        #expect(delivered.map(\.kind) == [.pointerMove, .pointerDown, .keyDown, .keyDown, .keyUp])
        #expect(delivered.first?.x == 0.5 && delivered.first?.y == 0.25)
        delivered.removeAll()
        session.focus(try #require(session.windows[8]))
        #expect(delivered.map(\.kind) == [.keyUp, .pointerCancel])
        session.key(Keysyms.special["Right"]!, pressed: true, in: window)
        delivered.removeAll()
        session.disconnect()
        #expect(delivered.map(\.kind) == [.keyUp])
    }

    /// Input that goes to another window releases what a game held, whether or not focus
    /// moves on the computer: a click in an ordinary window, keys there, or another game.
    @Test func inputElsewhereReleasesWhatAGameHeld() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7, 8, 9])
        resume.streams.last.server([(.gameCreate, game(1, window: 7)), (.gameCreate, game(2, window: 9))])
        try await helpers.until("games") { session.windows[7]?.game != nil && session.windows[9]?.game != nil }
        let first = try #require(session.windows[7]), ordinary = try #require(session.windows[8]), second = try #require(session.windows[9])
        var delivered: [Int: [GameInputEvent.Kind]] = [:]
        first.game?.inputSink = { delivered[1, default: []] += $0.map(\.kind) }
        second.game?.inputSink = { delivered[2, default: []] += $0.map(\.kind) }
        let up = Keysyms.special["Up"]!
        session.key(up, pressed: true, in: first)
        session.pointerButton(in: ordinary, button: 1, pressed: true, at: CGPoint(x: 1, y: 1))
        session.pointerButton(in: ordinary, button: 1, pressed: false, at: CGPoint(x: 1, y: 1))
        #expect(delivered[1] == [.keyDown, .keyUp])
        session.key(up, pressed: true, in: first)
        session.type("x", in: ordinary)
        #expect(delivered[1] == [.keyDown, .keyUp, .keyDown, .keyUp])
        session.key(up, pressed: true, in: first)
        session.key(up, pressed: true, in: second)
        #expect(delivered[1] == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        #expect(delivered[2] == [.keyDown])
        session.disconnect()
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

    // MARK: Declining

    func declines(_ frames: [DisplayFrame]) -> [DisplayFrame] {
        frames.filter { $0.type == DisplayProtocol.ClientType.gameDecline.rawValue }
    }

    @Test func aDeclineGoesOnceForTheWindowsCurrentGame() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        _ = resume.streams.last.take()
        game.decline("the page is not cross-origin isolated")
        try await helpers.until("ready") { game.isDeclineReady }
        session.declineGame(game, reason: "again")
        // The same game announced again on this connection does not ask twice.
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7))])
        try await Task.sleep(for: .milliseconds(30))
        let sent = declines(resume.streams.last.take())
        #expect(sent.map { $0.body["id"]?.int } == [1])
        #expect(sent.first?.body["reason"] == "the page is not cross-origin isolated")
        session.disconnect()
    }

    /// A decline sent on a connection that went before the computer answered is sent again on
    /// the next connection that announces the game, once.
    @Test func aDeclineTheConnectionLostIsSentAgainOnTheNext() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        game.decline("the page is not cross-origin isolated")
        var first: [DisplayFrame] = []
        try await helpers.until("first decline") {
            first += declines(resume.streams.last.take())
            return !first.isEmpty
        }
        try await resume.dropAndResume(session)
        let marker = try #require(try await resume.handshake(session, epoch: "e1", windows: [7]))
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7)), (.pong, ["t_us": CBOR(marker)])])
        var again: [DisplayFrame] = []
        try await helpers.until("decline again") {
            again += declines(resume.streams.last.take())
            return !again.isEmpty
        }
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7))])
        try await Task.sleep(for: .milliseconds(30))
        again += declines(resume.streams.last.take())
        #expect(again.map { $0.body["id"]?.int } == [1])
        session.disconnect()
    }

    /// While the saves a decline waits for are still being written, nothing is asked, even on a
    /// new connection that announces the game; the decline goes once they are.
    @Test func aDeclineWaitsForItsSavesAcrossAReconnect() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        game.declineSaveWait = 30
        var release: CheckedContinuation<Void, Never>?
        game.savesFlusher = { await withCheckedContinuation { release = $0 } }
        game.decline("the page is not cross-origin isolated")
        try await helpers.until("flushing") { release != nil }
        try await resume.dropAndResume(session)
        let marker = try #require(try await resume.handshake(session, epoch: "e1", windows: [7]))
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7)), (.pong, ["t_us": CBOR(marker)])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(declines(resume.streams.last.take()).isEmpty)
        #expect(!game.isDeclineReady)
        release?.resume()
        var sent: [DisplayFrame] = []
        try await helpers.until("decline") {
            sent += declines(resume.streams.last.take())
            return !sent.isEmpty
        }
        #expect(sent.map { $0.body["id"]?.int } == [1])
        session.disconnect()
    }

    /// Saves written after a new connection's hello but before it announces the game send
    /// nothing until the announcement.
    @Test func aDeclineWaitsForTheGameToBeAnnouncedAgain() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        game.declineSaveWait = 30
        var release: CheckedContinuation<Void, Never>?
        game.savesFlusher = { await withCheckedContinuation { release = $0 } }
        game.decline("the page is not cross-origin isolated")
        try await helpers.until("flushing") { release != nil }
        try await resume.dropAndResume(session)
        let marker = try #require(try await resume.handshake(session, epoch: "e1", windows: [7]))
        release?.resume()
        try await helpers.until("ready") { game.isDeclineReady }
        try await Task.sleep(for: .milliseconds(30))
        #expect(declines(resume.streams.last.take()).isEmpty) // hello, but no game.create yet
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7)), (.pong, ["t_us": CBOR(marker)])])
        var sent: [DisplayFrame] = []
        try await helpers.until("decline") {
            sent += declines(resume.streams.last.take())
            return !sent.isEmpty
        }
        #expect(sent.map { $0.body["id"]?.int } == [1])
        session.disconnect()
    }

    @Test func aDeclineIsOnlyForTheGameTheWindowRunsNow() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let first = try #require(session.windows[7]?.game)
        resume.streams.last.server([(.gameCreate, game(2, window: 7))])
        try await helpers.until("second") { session.windows[7]?.game?.id == 2 }
        _ = resume.streams.last.take()
        session.declineGame(first, reason: "replaced")
        #expect(declines(resume.streams.last.take()).isEmpty)

        let second = try #require(session.windows[7]?.game)
        session.disconnect()
        second.decline("gone")
        try await Task.sleep(for: .milliseconds(30))
        #expect(declines(resume.streams.last.take()).isEmpty)
    }

    /// The saves are written before the computer is asked, and the game shows it is going back.
    @Test func aDeclinedGameWritesItsSavesThenAsks() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        _ = resume.streams.last.take()
        var flushed = false
        game.savesFlusher = {
            try? await Task.sleep(for: .milliseconds(50))
            flushed = true
        }
        var states: [RemoteGame.State] = []
        game.stateSink = { states.append(game.state) }
        game.decline("WebKit ended the page twice within a minute")
        game.decline("twice")
        #expect(game.state == .declined && states == [.declined])
        #expect(declines(resume.streams.last.take()).isEmpty) // not before the saves
        var sent: [DisplayFrame] = []
        try await helpers.until("decline") {
            sent += declines(resume.streams.last.take())
            return !sent.isEmpty
        }
        #expect(flushed)
        #expect(sent.map { $0.body["reason"] } == ["WebKit ended the page twice within a minute"])
        resume.streams.last.server([(.gameDestroy, ["id": 1])])
        try await helpers.until("taken back") { game.isEnded }
        #expect(game.state == .declined)
    }

    @Test func aDeclineTheComputerDoesNotAnswerSaysSo() async throws {
        let game = RemoteGame(GameDescriptor(id: 1, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface())
        game.declineAnswerTime = .milliseconds(50)
        var asked: [String] = []
        game.onDecline = { asked.append($0) }
        game.decline("why")
        try await helpers.until("unanswered") { game.state == .declineUnanswered }
        #expect(asked == ["why"])
        #expect(game.declineReason == "why")

        let ended = RemoteGame(GameDescriptor(id: 2, window: 7, root: "r", entry: "e"), host: nil, picture: WindowSurface())
        ended.end()
        ended.decline("late")
        #expect(ended.state == .running)
    }

    @Test func aGameDeclinedWhileTheConnectionIsDownSaysSoOnTheNextOne() async throws {
        let session = makeSession()
        session.connect()
        try await resume.handshake(session, epoch: "e1", windows: [7])
        resume.streams.last.server([(.gameCreate, game(1, window: 7))])
        try await helpers.until("game") { session.windows[7]?.game != nil }
        let game = try #require(session.windows[7]?.game)
        try await resume.dropAndResume(session)
        game.decline("the page is not cross-origin isolated")
        try await helpers.until("declined") { game.declineReason != nil }
        try await Task.sleep(for: .milliseconds(30))
        let marker = try #require(try await resume.handshake(session, epoch: "e1", windows: [7]))
        resume.streams.last.server([(.gameCreate, self.game(1, window: 7)), (.pong, ["t_us": CBOR(marker)])])
        var sent: [DisplayFrame] = []
        try await helpers.until("decline") {
            sent += declines(resume.streams.last.take())
            return !sent.isEmpty
        }
        #expect(sent.map { $0.body["id"]?.int } == [1])
        session.disconnect()
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

@Suite struct GamePresentationTests {
    @Test func desktopHostsLiveGameWithoutRoutingInputThroughItsView() {
        #expect(GamePresentation.hosts(interactive: false, desktop: true, contentEnabled: true, hasConnection: true, onScreen: true))
        #expect(GamePresentation.hosts(interactive: true, desktop: false, contentEnabled: true, hasConnection: true, onScreen: true))
    }
    @Test func thumbnailsAndInactiveOwnersDoNotTakeTheGame() {
        #expect(!GamePresentation.hosts(interactive: false, desktop: false, contentEnabled: true, hasConnection: true, onScreen: true))
        #expect(!GamePresentation.hosts(interactive: false, desktop: true, contentEnabled: false, hasConnection: true, onScreen: true))
        #expect(!GamePresentation.hosts(interactive: false, desktop: true, contentEnabled: true, hasConnection: false, onScreen: true))
        #expect(!GamePresentation.hosts(interactive: false, desktop: true, contentEnabled: true, hasConnection: true, onScreen: false))
    }
}
