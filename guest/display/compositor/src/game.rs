//! Game handoff (docs/game-handoff.md): the game socket `caboose-game-run` connects to,
//! the binding of a launcher to its window, and the `game.*` messages that tell a client
//! to run the window's game itself. While a client runs it, the window sends no pictures.

use crate::state::State;
use caboose_display_protocol::cbor::{self, Value};
use caboose_display_protocol::{self as proto, Message, HEADER_LEN};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::calloop::{Interest, LoopHandle, Mode as Trigger, PostAction, RegistrationToken};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The largest message a launcher may send.
pub const MAX_PAYLOAD: usize = 64 * 1024;
/// How long a launcher's window may take to appear after its hello.
pub const BIND_TIMEOUT: Duration = Duration::from_secs(5);
const HELLO: u8 = 0x01;
const MODE: u8 = 0x81;

/// What a launcher said in its `hello`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub title: String,
    pub app_id: String,
    pub root: String,
    pub entry: String,
    pub saves: Option<Vec<proto::GameSave>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Handoff,
    Local,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Mode::Handoff => "handoff",
            Mode::Local => "local",
        }
    }
}

fn text<'a>(map: &'a [(String, Value)], key: &str) -> Option<&'a str> {
    map.iter().find(|(k, _)| k == key).and_then(|(_, v)| match v {
        Value::Text(s) => Some(s.as_str()),
        _ => None,
    })
}

/// A relative path that names something inside its base: no empty, `.` or `..`
/// components and no leading `/`. The client resolves it again; this keeps a launcher
/// from announcing anything else.
fn contained(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\0')
        && path.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
}

impl Hello {
    /// `None` for anything but a version 1 hello with contained paths.
    pub fn parse(payload: &[u8]) -> Option<Hello> {
        let Value::Map(map) = cbor::decode(payload).ok()? else { return None };
        let version = map.iter().find(|(k, _)| k == "version").map(|(_, v)| v);
        if !matches!(version, Some(Value::Int(1))) {
            return None;
        }
        let saves = match map.iter().find(|(k, _)| k == "saves").map(|(_, v)| v) {
            None => None,
            Some(Value::Array(items)) => Some(
                items
                    .iter()
                    .map(|item| match item {
                        Value::Map(m) => Some(proto::GameSave {
                            mount: text(m, "mount").filter(|m| m.starts_with('/'))?.to_owned(),
                            path: text(m, "path").filter(|p| contained(p))?.to_owned(),
                        }),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>()?,
            ),
            Some(_) => return None,
        };
        Some(Hello {
            title: text(&map, "title")?.to_owned(),
            app_id: text(&map, "app_id")?.to_owned(),
            root: text(&map, "root").filter(|r| contained(r))?.to_owned(),
            entry: text(&map, "entry").filter(|e| contained(e))?.to_owned(),
            saves,
        })
    }
}

/// `mode` with its header.
pub fn mode_message(mode: Mode, window: Option<u64>) -> Vec<u8> {
    let mut map = vec![("mode".to_owned(), Value::Text(mode.as_str().into()))];
    if let Some(w) = window {
        map.push(("window".into(), Value::Int(w as i128)));
    }
    let payload = cbor::encode(&Value::Map(map));
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.push(MODE);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&payload);
    out
}

/// Splits a launcher's byte stream into `(type, payload)` messages.
#[derive(Default)]
pub struct Framer {
    buffer: Vec<u8>,
}

impl Framer {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next message, `Ok(None)` until one is complete, or `Err` for an oversized one.
    pub fn next_message(&mut self) -> Result<Option<(u8, Vec<u8>)>, usize> {
        if self.buffer.len() < HEADER_LEN {
            return Ok(None);
        }
        let len = u32::from_le_bytes(self.buffer[1..HEADER_LEN].try_into().unwrap()) as usize;
        if len > MAX_PAYLOAD {
            return Err(len);
        }
        if self.buffer.len() < HEADER_LEN + len {
            return Ok(None);
        }
        let kind = self.buffer[0];
        let payload = self.buffer[HEADER_LEN..HEADER_LEN + len].to_vec();
        self.buffer.drain(..HEADER_LEN + len);
        Ok(Some((kind, payload)))
    }
}

struct Launcher {
    out: UnixStream,
    pending: Vec<u8>,
    framer: Framer,
    pid: u32,
    hello: Option<Hello>,
    /// The game's id and window once bound.
    bound: Option<(u64, u64)>,
    /// Whether the connected client was sent `game.create` for it.
    announced: bool,
    /// The mode last sent, or None before the first.
    sent: Option<(Mode, Option<u64>)>,
    /// A bound launcher that may still get its first `handoff`.
    waiting: bool,
    token: Option<RegistrationToken>,
}

#[derive(Default)]
pub struct Games {
    /// The socket path, when listening.
    pub socket: Option<PathBuf>,
    launchers: HashMap<u64, Launcher>,
    next_conn: u64,
    next_game: u64,
}

/// `$CABOOSE_GAME_SOCKET`, else `$XDG_RUNTIME_DIR/caboose-game.sock`.
pub fn socket_path() -> Option<PathBuf> {
    std::env::var_os("CABOOSE_GAME_SOCKET")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR").map(|d| Path::new(&d).join("caboose-game.sock")))
}

impl Games {
    pub fn listen(path: &Path, handle: &LoopHandle<'static, State>) -> io::Result<Self> {
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        handle
            .insert_source(Generic::new(listener, Interest::READ, Trigger::Level), |_, listener, state: &mut State| {
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => state.accept_launcher(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("game socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { socket: Some(path.to_owned()), ..Self::default() })
    }

    /// The game bound to a window.
    fn of_window(&self, window: u64) -> Option<u64> {
        self.launchers.iter().find(|(_, l)| l.bound.is_some_and(|(_, w)| w == window)).map(|(c, _)| *c)
    }
}

impl State {
    /// Whether the connected client runs games.
    fn client_runs_games(&self) -> bool {
        self.session.as_ref().is_some_and(|s| s.ready && s.wasm)
    }

    /// The window's game runs on the client, so the window sends no pictures.
    pub fn game_shown(&self, window: u64) -> bool {
        self.client_runs_games() && self.games.of_window(window).is_some()
    }

    fn accept_launcher(&mut self, stream: UnixStream) {
        let Some(pid) = crate::video::server::peer_pid(&stream) else {
            tracing::warn!("game socket: no peer credentials");
            return;
        };
        let (Ok(out), Ok(())) = (stream.try_clone(), stream.set_nonblocking(true)) else { return };
        self.games.next_conn += 1;
        let id = self.games.next_conn;
        self.games.launchers.insert(
            id,
            Launcher {
                out,
                pending: Vec::new(),
                framer: Framer::default(),
                pid,
                hello: None,
                bound: None,
                announced: false,
                sent: None,
                waiting: false,
                token: None,
            },
        );
        let token = self.handle.insert_source(
            Generic::new(stream, Interest::READ, Trigger::Level),
            move |_, stream, state: &mut State| {
                let mut buf = [0u8; 16 * 1024];
                let mut closed = false;
                loop {
                    // SAFETY: the stream is not dropped while the source exists.
                    match unsafe { stream.get_mut() }.read(&mut buf) {
                        Ok(0) => {
                            closed = true;
                            break;
                        }
                        Ok(n) => {
                            if let Some(l) = state.games.launchers.get_mut(&id) {
                                l.framer.push(&buf[..n]);
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => {
                            closed = true;
                            break;
                        }
                    }
                }
                state.drain_launcher(id);
                if closed {
                    state.drop_launcher(id);
                    return Ok(PostAction::Remove);
                }
                Ok(PostAction::Continue)
            },
        );
        match token {
            Ok(t) => {
                if let Some(l) = self.games.launchers.get_mut(&id) {
                    l.token = Some(t);
                }
            }
            Err(e) => {
                tracing::warn!("game socket: {e}");
                self.games.launchers.remove(&id);
            }
        }
    }

    fn drain_launcher(&mut self, conn: u64) {
        loop {
            let Some(l) = self.games.launchers.get_mut(&conn) else { return };
            match l.framer.next_message() {
                Ok(Some((HELLO, payload))) => match Hello::parse(&payload) {
                    Some(hello) => self.on_launcher_hello(conn, hello),
                    None => {
                        tracing::warn!("game launcher {conn}: invalid hello; closing");
                        self.drop_launcher(conn);
                        return;
                    }
                },
                Ok(Some(_)) => {} // unknown types are skipped
                Ok(None) => return,
                Err(len) => {
                    tracing::warn!("game launcher {conn}: {len}-byte message; closing");
                    self.drop_launcher(conn);
                    return;
                }
            }
        }
    }

    fn on_launcher_hello(&mut self, conn: u64, hello: Hello) {
        let pid = self.games.launchers[&conn].pid;
        tracing::info!("game {:?} (pid {pid}): {}/{}", hello.title, hello.root, hello.entry);
        // A second connection from the same process replaces the first.
        let older: Vec<u64> =
            self.games.launchers.iter().filter(|(c, l)| **c != conn && l.pid == pid).map(|(c, _)| *c).collect();
        for c in older {
            self.drop_launcher(c);
        }
        let l = self.games.launchers.get_mut(&conn).unwrap();
        l.hello = Some(hello);
        l.waiting = true;
        self.bind_launcher(conn);
        if self.games.launchers.get(&conn).is_some_and(|l| l.bound.is_none()) {
            let timer = Timer::from_duration(BIND_TIMEOUT);
            let armed = self.handle.insert_source(timer, move |_, _, state: &mut State| {
                if let Some(l) = state.games.launchers.get_mut(&conn).filter(|l| l.bound.is_none()) {
                    tracing::info!("game launcher {conn}: no window within {BIND_TIMEOUT:?}");
                    l.waiting = false;
                    state.update_game_mode(conn);
                }
                TimeoutAction::Drop
            });
            if let Err(e) = armed {
                tracing::warn!("game bind timer: {e}");
            }
        }
        self.update_game_mode(conn);
    }

    /// Binds a launcher that said hello to the first toplevel its process made.
    fn bind_launcher(&mut self, conn: u64) {
        let Some(l) = self.games.launchers.get(&conn).filter(|l| l.hello.is_some() && l.bound.is_none()) else {
            return;
        };
        let pid = l.pid;
        let taken: Vec<u64> = self.games.launchers.values().filter_map(|l| l.bound.map(|(_, w)| w)).collect();
        let dh = self.dh.clone();
        let window = self.windows.find(|w| {
            use smithay::reexports::wayland_server::Resource;
            let crate::windows::Surface::Toplevel(t) = &w.surface else { return false };
            let owner = dh.get_client(t.wl_surface().id()).ok().and_then(|c| c.get_credentials(&dh).ok());
            owner.is_some_and(|c| c.pid as u32 == pid) && !taken.contains(&w.id)
        });
        let Some(window) = window else { return };
        self.games.next_game += 1;
        let game = self.games.next_game;
        self.games.launchers.get_mut(&conn).unwrap().bound = Some((game, window));
        tracing::info!("game {game} bound to window {window}");
        self.announce_game(conn);
    }

    /// Tries every launcher still looking for its window (a toplevel was just made).
    pub fn bind_waiting_games(&mut self) {
        let waiting: Vec<u64> = self
            .games
            .launchers
            .iter()
            .filter(|(_, l)| l.hello.is_some() && l.bound.is_none())
            .map(|(c, _)| *c)
            .collect();
        for conn in waiting {
            self.bind_launcher(conn);
            self.update_game_mode(conn);
        }
    }

    /// Sends `game.create` for a bound game whose window the client knows.
    fn announce_game(&mut self, conn: u64) {
        if !self.client_runs_games() {
            return;
        }
        let Some(session) = self.session.as_ref().map(|s| s.conn) else { return };
        let Some(l) = self.games.launchers.get(&conn) else { return };
        let (Some((id, window)), Some(hello), false) = (l.bound, l.hello.as_ref(), l.announced) else { return };
        if self.windows.get(window).is_none_or(|w| w.announced.is_none()) {
            return;
        }
        let message = Message::GameCreate(proto::GameCreate {
            id,
            window,
            root: hello.root.clone(),
            entry: hello.entry.clone(),
            saves: hello.saves.clone(),
        });
        self.net.send(session, &message);
        self.games.launchers.get_mut(&conn).unwrap().announced = true;
    }

    /// The window was just announced to the client: its game follows it.
    pub fn window_announced(&mut self, window: u64) {
        if let Some(conn) = self.games.of_window(window) {
            self.announce_game(conn);
        }
    }

    /// The window is about to be withdrawn from the client: its game goes first.
    pub fn window_withdrawn(&mut self, window: u64) {
        let Some(conn) = self.games.of_window(window) else { return };
        self.withdraw_game(conn);
    }

    fn withdraw_game(&mut self, conn: u64) {
        let Some(l) = self.games.launchers.get_mut(&conn) else { return };
        let (Some((id, _)), true) = (l.bound, l.announced) else { return };
        l.announced = false;
        if let Some(session) = self.session.as_ref().map(|s| s.conn) {
            self.net.send(session, &Message::GameDestroy { id });
        }
    }

    /// The window is gone: so is its game.
    pub fn game_window_gone(&mut self, window: u64) {
        let Some(conn) = self.games.of_window(window) else { return };
        self.withdraw_game(conn);
        if let Some(l) = self.games.launchers.get_mut(&conn) {
            l.bound = None;
            l.waiting = false;
        }
        self.update_game_mode(conn);
    }

    /// A client connected or went away: every launcher hears its new mode, and the new
    /// client is told nothing yet (its windows' `window.create` brings their games).
    pub fn games_session_changed(&mut self) {
        let conns: Vec<u64> = self.games.launchers.keys().copied().collect();
        for conn in conns {
            if let Some(l) = self.games.launchers.get_mut(&conn) {
                l.announced = false;
            }
            self.update_game_mode(conn);
        }
    }

    fn update_game_mode(&mut self, conn: u64) {
        let runs = self.client_runs_games();
        let Some(l) = self.games.launchers.get_mut(&conn) else { return };
        if l.hello.is_none() {
            return;
        }
        let now = match l.bound {
            Some((_, window)) if runs => (Mode::Handoff, Some(window)),
            // Still looking for its window: the answer waits, for up to BIND_TIMEOUT.
            None if runs && l.waiting && l.sent.is_none() => return,
            Some((_, window)) => (Mode::Local, Some(window)),
            None => (Mode::Local, None),
        };
        if l.sent == Some(now) {
            return;
        }
        l.sent = Some(now);
        l.pending.extend_from_slice(&mode_message(now.0, now.1));
        self.flush_launcher(conn);
        // A window whose game the client stopped running sends its picture again.
        if let (Mode::Local, Some(window)) = now {
            if let Some(w) = self.windows.get_mut(window) {
                w.stream.need_keyframe = true;
                w.stream.dirty = true;
            }
        }
    }

    fn flush_launcher(&mut self, conn: u64) {
        let Some(l) = self.games.launchers.get_mut(&conn) else { return };
        while !l.pending.is_empty() {
            match l.out.write(&l.pending) {
                Ok(n) => {
                    l.pending.drain(..n);
                }
                // A launcher reads only its mode; a full socket means it stopped reading.
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => {
                    l.pending.clear();
                    break;
                }
            }
        }
    }

    fn drop_launcher(&mut self, conn: u64) {
        self.withdraw_game(conn);
        let Some(l) = self.games.launchers.remove(&conn) else { return };
        if let Some(t) = l.token {
            self.handle.remove(t);
        }
        if let Some((game, window)) = l.bound {
            tracing::info!("game {game} (pid {}) gone", l.pid);
            if let Some(w) = self.windows.get_mut(window) {
                w.stream.need_keyframe = true;
                w.stream.dirty = true;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello(map: Vec<(&str, Value)>) -> Vec<u8> {
        cbor::encode(&Value::Map(map.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()))
    }

    fn valid() -> Vec<(&'static str, Value)> {
        vec![
            ("version", Value::Int(1)),
            ("title", Value::Text("The Powder Toy".into())),
            ("app_id", Value::Text("uk.co.powdertoy.tpt".into())),
            ("root", Value::Text(".local/share/caboose/games/powder-toy/web".into())),
            ("entry", Value::Text("index.html".into())),
        ]
    }

    #[test]
    fn a_hello_parses_with_and_without_saves() {
        let h = Hello::parse(&hello(valid())).unwrap();
        assert_eq!(h.root, ".local/share/caboose/games/powder-toy/web");
        assert_eq!(h.saves, None);
        let mut with = valid();
        with.push((
            "saves",
            Value::Array(vec![Value::Map(vec![
                ("mount".into(), Value::Text("/powder".into())),
                ("path".into(), Value::Text(".local/share/The Powder Toy".into())),
            ])]),
        ));
        let h = Hello::parse(&hello(with)).unwrap();
        assert_eq!(
            h.saves,
            Some(vec![proto::GameSave { mount: "/powder".into(), path: ".local/share/The Powder Toy".into() }])
        );
    }

    #[test]
    fn paths_that_leave_the_home_are_refused() {
        for root in ["/etc", "../x", "a/../../b", "a//b", "", "./a"] {
            let mut h = valid();
            h[3] = ("root", Value::Text(root.into()));
            assert_eq!(Hello::parse(&hello(h)), None, "{root}");
        }
        let mut h = valid();
        h.push((
            "saves",
            Value::Array(vec![Value::Map(vec![
                ("mount".into(), Value::Text("/powder".into())),
                ("path".into(), Value::Text("../outside".into())),
            ])]),
        ));
        assert_eq!(Hello::parse(&hello(h)), None);
    }

    #[test]
    fn other_versions_are_refused() {
        let mut h = valid();
        h[0] = ("version", Value::Int(2));
        assert_eq!(Hello::parse(&hello(h)), None);
    }

    #[test]
    fn mode_is_a_framed_canonical_map() {
        let bytes = mode_message(Mode::Handoff, Some(7));
        assert_eq!(bytes[0], MODE);
        let len = u32::from_le_bytes(bytes[1..5].try_into().unwrap()) as usize;
        assert_eq!(len, bytes.len() - HEADER_LEN);
        assert_eq!(
            cbor::decode(&bytes[HEADER_LEN..]).unwrap(),
            Value::Map(vec![("mode".into(), Value::Text("handoff".into())), ("window".into(), Value::Int(7))])
        );
        // Canonical: "mode" (4 bytes) sorts before "window" (6 bytes).
        assert_eq!(&bytes[HEADER_LEN..HEADER_LEN + 6], &[0xa2, 0x64, b'm', b'o', b'd', b'e']);
    }

    #[test]
    fn the_framer_splits_skips_and_limits() {
        let mut f = Framer::default();
        let one = mode_message(Mode::Local, None);
        f.push(&one[..3]);
        assert_eq!(f.next_message(), Ok(None));
        f.push(&one[3..]);
        f.push(&[0x50, 1, 0, 0, 0, 0xf6]);
        assert_eq!(f.next_message().unwrap().unwrap().0, MODE);
        assert_eq!(f.next_message(), Ok(Some((0x50, vec![0xf6]))));
        assert_eq!(f.next_message(), Ok(None));
        f.push(&[HELLO, 0, 0, 2, 0]);
        assert_eq!(f.next_message(), Err(0x20000));
    }
}
