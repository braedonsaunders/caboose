import CabooseKit
import Foundation
import Observation
import UIKit

/// The terminal tab's session: one shell on the computer, shown in one terminal view.
///
/// The shell lives on the computer, not in the connection, so leaving the app or losing the
/// network only detaches. Coming back reattaches from the last byte this view received and
/// nothing is drawn twice. The model outlives the screen, so its scrollback survives the tab
/// being rebuilt.
///
/// A model pinned to a session (an agent's sign-in) shows only that one: it never starts a
/// shell, and when the session ends it stays ended.
@MainActor @Observable
final class TerminalModel {
    static let shared = TerminalModel()

    enum Status: Equatable {
        case starting
        case live
        /// The network dropped; trying again.
        case reconnecting
        /// The shell exited, with how.
        case exited(String)
        /// Another device opened this session.
        case elsewhere
        /// Closed after a long time with nothing either way.
        case idle
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var title = String(localized: "Terminal")
    private(set) var sessions: [TerminalSessionInfo] = []
    private(set) var sessionID: String? {
        didSet { if !pinned { UserDefaults.standard.set(sessionID, forKey: Self.sessionKey) } }
    }
    @ObservationIgnored private let pinned: Bool

    @ObservationIgnored let view = CabooseTerminalView()
    @ObservationIgnored private var host: HostClient?
    @ObservationIgnored private var connection: TerminalConnection?
    /// Output this view holds of the current session, for a reattach to continue from.
    @ObservationIgnored private var offset: Int?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var size: (columns: Int, rows: Int)?
    /// A note to print once the next session says hello.
    @ObservationIgnored private var notice: String?
    private static let sessionKey = "caboose.terminal.session"

    private init() {
        pinned = false
        sessionID = UserDefaults.standard.string(forKey: Self.sessionKey).flatMap { TerminalProtocol.isSessionID($0) ? $0 : nil }
        view.owner = self
    }

    /// A model that shows only session `session`.
    init(pinnedTo session: String) {
        pinned = true
        sessionID = TerminalProtocol.isSessionID(session) ? session : nil
        view.owner = self
    }

    // MARK: Lifecycle

    /// The screen is on screen with the app in front: attach.
    func show(host: HostClient?) {
        if host?.baseURL != self.host?.baseURL || host?.token != self.host?.token {
            disconnect()
            if self.host != nil, host?.token != self.host?.token {
                // Another sign-in, so another computer: its sessions are not this one's. The
                // same computer at another address (home, or the VPN) keeps its session.
                sessionID = nil
                offset = nil
            }
            self.host = host
        }
        visible = true
        guard host != nil else { status = .failed(String(localized: "Pair with your computer to open a terminal.")); return }
        // Coming back to the screen is a fresh attempt after a failure.
        if case .failed = status { status = .starting; attempt = 0 }
        if connection == nil, retry == nil, canReconnectOnItsOwn { connect(wake: true) }
    }

    /// The screen went away or the app went to the background: detach, leaving the shell running.
    func hide() {
        view.resignFirstResponder()
        visible = false
        disconnect()
    }

    private var canReconnectOnItsOwn: Bool {
        switch status {
        case .starting, .live, .reconnecting: true
        case .exited, .elsewhere, .idle, .failed: false
        }
    }

    private func disconnect() {
        retry?.cancel()
        retry = nil
        if let connection {
            offset = connection.offset
            connection.close()
        }
        connection = nil
        if status == .live { status = .reconnecting }
    }

    /// `wake` is for the owner's own actions. Retries never wake the computer, so a terminal
    /// cut off by a park does not undo it.
    private func connect(wake: Bool) {
        guard visible, let host, let size, !pinned || sessionID != nil else { return }
        retry?.cancel()
        retry = nil
        connection?.close()
        let url = TerminalProtocol.url(base: host.baseURL, columns: size.columns, rows: size.rows, session: sessionID, offset: sessionID == nil ? nil : offset, wake: wake)
        let connection = TerminalConnection(transport: URLSessionTerminalTransport(url: url, token: host.token))
        self.connection = connection
        let view = view
        connection.start { [weak self, weak connection] event in
            // Output is fed in order on the connection's queue; libghostty parses off the main thread.
            switch event {
            case .connected(let hello):
                if hello.reset { view.replay(byteArray: hello.preamble[...]) }
            case .output(let data):
                view.feed(byteArray: [UInt8](data)[...])
            case .ended:
                break
            }
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .connected(let hello):
            sessionID = hello.session
            status = .live
            attempt = 0
            if let notice {
                view.feed(text: "\r\n\u{1b}[2m\(notice)\u{1b}[0m\r\n")
                self.notice = nil
            }
            Task { await refreshSessions() }
        case .output:
            break
        case .ended(let end):
            offset = connection?.offset ?? offset
            connection = nil
            ended(end)
        }
    }

    private func ended(_ end: TerminalEnd) {
        switch end {
        case .exited(let code, let signal):
            let how = signal.map { String(localized: "ended by signal \($0)") } ?? String(localized: "exited with code \(code ?? 0)")
            view.feed(text: "\r\n\u{1b}[2m[\(String(localized: "Process")) \(how)]\u{1b}[0m\r\n")
            sessionID = nil
            offset = nil
            status = .exited(how)
            Task { await refreshSessions() }
        case .sessionEnded where pinned:
            sessionID = nil
            offset = nil
            status = .exited(String(localized: "ended"))
        case .sessionEnded:
            // The computer restarted or the session was closed elsewhere: start a fresh one.
            notice = String(localized: "[The previous session has ended. This is a new one.]")
            sessionID = nil
            offset = nil
            connect(wake: false)
        case .replaced:
            status = .elsewhere
        case .idle:
            status = .idle
        case .unauthorized:
            status = .failed(String(localized: "Your computer did not accept this sign-in token."))
        case .tooMany:
            status = .failed(String(localized: "Too many terminals are open on your computer. Close one, then try again."))
        case .notRunning, .dropped:
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard visible else { return }
        status = .reconnecting
        attempt += 1
        // 0.5 s, 1, 2, 4, 8, then every 15 s.
        let delay = min(0.5 * pow(2, Double(attempt - 1)), 15)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect(wake: false)
        }
    }

    // MARK: Sessions

    /// Shows this session here again after another device took it, or after an idle close.
    func reconnect() {
        status = .reconnecting
        attempt = 0
        connect(wake: true)
    }

    func newSession() {
        disconnect()
        sessionID = nil
        offset = nil
        status = .starting
        view.feed(text: "\u{1b}c")
        connect(wake: true)
    }

    func open(_ session: TerminalSessionInfo) {
        guard session.id != sessionID else { return }
        disconnect()
        sessionID = session.id
        // This view holds none of that session's output: it arrives as a replay with a reset.
        offset = nil
        status = .starting
        connect(wake: true)
    }

    /// Hangs up the shell; its exit then arrives on the connection.
    func closeSession() {
        if let connection, status == .live { connection.hangup(); return }
        guard let host, let id = sessionID else { return }
        Task {
            try? await host.hangUpTerminal(id)
            newSession()
        }
    }

    func refreshSessions() async {
        guard let host else { return }
        if let list = try? await host.terminalSessions() { sessions = list }
    }

    func adjustTextSize(by step: CGFloat) {
        view.setFontSize(view.fontSize + step)
    }
}

extension TerminalModel: CabooseTerminalViewOwner {
    func terminal(_ view: CabooseTerminalView, send bytes: Data) {
        if let connection, status == .live {
            connection.send(input: bytes)
        } else if status == .idle {
            // Typing after an idle close comes straight back.
            reconnect()
            connection?.send(input: bytes)
        } else if case .exited = status, bytes == Data([0x0d]), !pinned {
            // Return after the shell has exited starts a new one, as in Terminal.
            newSession()
        }
    }

    func terminal(_ view: CabooseTerminalView, resizedTo columns: Int, rows: Int) {
        guard columns > 1, rows > 1 else { return }
        let first = size == nil
        size = (columns, rows)
        if first { if visible, connection == nil, retry == nil, canReconnectOnItsOwn { connect(wake: true) } } else { connection?.resize(columns: columns, rows: rows) }
    }

    func terminal(_ view: CabooseTerminalView, titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? String(localized: "Terminal") : String(trimmed.prefix(80))
    }
}
