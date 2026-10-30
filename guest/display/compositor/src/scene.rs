//! Scene Socket (`$XDG_RUNTIME_DIR/caboose-scene.sock`): opt-in non-blocking Unix domain
//! stream listener for retained vector & glyph scene graphs (`scene.font` `0x25` and
//! `scene.commit` `0x26`) from toolkit interceptors (`libcaboose_scene_cairo.so`), and
//! reverse forwarding of client-predicted scroll (`scene.scroll` `0x9A`).
//!
//! Honors Headless Liveness: when no display client is connected or `session.scene` is
//! false, incoming toolkit frames are drained non-blockingly so toolkit processes never
//! block.

use crate::state::State;
use caboose_display_protocol::{self as proto, Decoded, Message, SceneScroll, StreamDecoder};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::{Interest, LoopHandle, Mode as Trigger, PostAction, RegistrationToken};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// Maximum concurrent toolkit connections on the scene socket.
pub const MAX_SCENE_CONNS: usize = 32;
/// Maximum retained font faces across the compositor session.
pub const MAX_SCENE_FONTS: usize = 128;
/// Maximum byte size of a single registered font face (8 MiB).
pub const MAX_FONT_BYTES: usize = 8 * 1024 * 1024;
/// Maximum aggregate byte size of all retained font faces (32 MiB).
pub const MAX_TOTAL_FONT_BYTES: usize = 32 * 1024 * 1024;
/// Maximum distinct `(window, node)` scroll targets coalesced while a toolkit socket is backpressured.
pub const MAX_PENDING_SCROLL_NODES: usize = 64;

struct SceneClient {
    out: UnixStream,
    /// Remainder of the single currently-writing `SceneScroll` frame (at most one message).
    writing: Vec<u8>,
    /// Bounded, coalesced latest scroll state per `(window_id, node_id)`.
    coalesced_scrolls: BTreeMap<(u64, u64), SceneScroll>,
    decoder: StreamDecoder,
    pid: u32,
    lineage: Vec<u32>,
    window: Option<u64>,
    token: Option<RegistrationToken>,
}

#[derive(Default)]
pub struct SceneServer {
    /// The socket path when listening.
    pub socket: Option<PathBuf>,
    conns: HashMap<u64, SceneClient>,
    next_conn: u64,
    /// Font hashes (`SceneFont.font`) already forwarded to the active display session.
    pub sent_fonts: HashSet<u64>,
    /// Retained fonts by hash so a newly connecting scene-capable client can receive them,
    /// or deduplicate across toolkit processes within a session.
    pub fonts: HashMap<u64, proto::SceneFont>,
    /// Total bytes stored in `fonts`.
    pub font_bytes: usize,
}

/// Opt-in scene socket path: active only when `CABOOSE_SCENE=1` or `CABOOSE_SCENE_SOCKET` is set.
pub fn socket_path() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("CABOOSE_SCENE_SOCKET").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(explicit));
    }
    if std::env::var("CABOOSE_SCENE").as_deref() == Ok("1") {
        return std::env::var_os("XDG_RUNTIME_DIR").map(|d| Path::new(&d).join("caboose-scene.sock"));
    }
    None
}

fn peer_credentials(stream: &UnixStream) -> Option<(u32, u32)> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `cred`.
    let r = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (r == 0 && cred.pid > 0).then_some((cred.uid, cred.pid as u32))
}

/// Authorizes a scene operation against the windows currently owned by the peer process.
/// - When `requested_id != 0`, the peer must actually own `requested_id` (foreign or stale IDs are rejected).
/// - When `requested_id == 0`, the peer must own unambiguously one window (`owned.len() == 1`).
pub fn authorize_scene_window(owned: &[u64], requested_id: u64) -> Option<u64> {
    if requested_id != 0 {
        owned.contains(&requested_id).then_some(requested_id)
    } else if owned.len() == 1 {
        Some(owned[0])
    } else {
        None
    }
}

/// Enqueues or coalesces a `SceneScroll` update into a bounded per-`(window, node)` map.
/// Returns `false` if the client has exceeded `MAX_PENDING_SCROLL_NODES` while stalled.
pub fn coalesce_scroll(
    map: &mut BTreeMap<(u64, u64), SceneScroll>,
    scroll: SceneScroll,
) -> bool {
    let key = (scroll.id, scroll.node);
    if !map.contains_key(&key) && map.len() >= MAX_PENDING_SCROLL_NODES {
        return false;
    }
    map.insert(key, scroll);
    true
}

impl SceneServer {
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
                        Ok((stream, _)) => state.accept_scene_client(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("scene socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { socket: Some(path.to_owned()), ..Self::default() })
    }

    pub fn reset_session(&mut self) {
        self.sent_fonts.clear();
    }

    /// Records a font within aggregate limits and returns `true` if it should be sent to the current session.
    pub fn record_font_for_session(&mut self, font: proto::SceneFont, session_active: bool) -> bool {
        if font.data.is_empty() || font.data.len() > MAX_FONT_BYTES {
            return false;
        }
        let hash = font.font;
        if !self.fonts.contains_key(&hash) {
            if self.fonts.len() >= MAX_SCENE_FONTS || self.font_bytes + font.data.len() > MAX_TOTAL_FONT_BYTES {
                return false;
            }
            self.font_bytes += font.data.len();
            self.fonts.insert(hash, font);
        }
        session_active && self.sent_fonts.insert(hash)
    }
}

impl State {
    fn accept_scene_client(&mut self, stream: UnixStream) {
        if self.scene.conns.len() >= MAX_SCENE_CONNS {
            tracing::warn!("scene socket: connection limit ({MAX_SCENE_CONNS}) reached");
            return;
        }
        let Some((uid, pid)) = peer_credentials(&stream) else {
            tracing::warn!("scene socket: refused peer without credentials");
            return;
        };
        // SAFETY: getuid is always safe to call.
        if uid != unsafe { libc::getuid() } {
            tracing::warn!("scene socket: refused peer of uid {uid}");
            return;
        }
        let (Ok(out), Ok(())) = (stream.try_clone(), stream.set_nonblocking(true)) else { return };
        let _ = out.set_nonblocking(true);
        self.scene.next_conn += 1;
        let id = self.scene.next_conn;
        let lineage = crate::video::lineage(pid);
        self.scene.conns.insert(
            id,
            SceneClient {
                out,
                writing: Vec::new(),
                coalesced_scrolls: BTreeMap::new(),
                decoder: StreamDecoder::new(),
                pid,
                lineage,
                window: None,
                token: None,
            },
        );
        let token = self.handle.insert_source(
            Generic::new(stream, Interest::BOTH, Trigger::Edge),
            move |_, stream, state: &mut State| {
                let mut buf = [0u8; 64 * 1024];
                let mut closed = false;
                loop {
                    // SAFETY: the stream is not dropped while the source exists.
                    match unsafe { stream.get_mut() }.read(&mut buf) {
                        Ok(0) => {
                            closed = true;
                            break;
                        }
                        Ok(n) => {
                            if let Some(c) = state.scene.conns.get_mut(&id) {
                                c.decoder.push(&buf[..n]);
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
                state.drain_scene_client(id);
                state.flush_scene_client(id);
                if closed || !state.scene.conns.contains_key(&id) {
                    state.drop_scene_client(id);
                    return Ok(PostAction::Remove);
                }
                Ok(PostAction::Continue)
            },
        );
        match token {
            Ok(t) => {
                if let Some(c) = self.scene.conns.get_mut(&id) {
                    c.token = Some(t);
                }
            }
            Err(e) => {
                tracing::warn!("scene socket: {e}");
                self.scene.conns.remove(&id);
            }
        }
    }

    fn drain_scene_client(&mut self, conn: u64) {
        loop {
            let next = {
                let Some(c) = self.scene.conns.get_mut(&conn) else { return };
                c.decoder.next_message()
            };
            match next {
                Ok(Some(Decoded::Message(Message::SceneFont(font)))) => {
                    self.on_scene_font(conn, font);
                }
                Ok(Some(Decoded::Message(Message::SceneCommit(commit)))) => {
                    self.on_scene_commit(conn, commit);
                }
                Ok(Some(Decoded::Message(_) | Decoded::Unknown { .. })) => {}
                Ok(Some(Decoded::Invalid { type_id, error })) => {
                    tracing::debug!("scene client {conn}: invalid 0x{type_id:02x}: {error}");
                }
                Ok(None) => break,
                Err(e) => {
                    tracing::warn!("scene client {conn}: {e}; closing");
                    self.drop_scene_client(conn);
                    return;
                }
            }
        }
    }

    fn flush_scene_client(&mut self, conn: u64) {
        let mut failed = false;
        if let Some(c) = self.scene.conns.get_mut(&conn) {
            loop {
                if c.writing.is_empty() {
                    let Some( next_key) = c.coalesced_scrolls.keys().next().copied() else { break };
                    let scroll = c.coalesced_scrolls.remove(&next_key).unwrap();
                    c.writing = proto::encode(&Message::SceneScroll(scroll));
                }
                match c.out.write(&c.writing) {
                    Ok(0) => {
                        failed = true;
                        break;
                    }
                    Ok(n) => {
                        c.writing.drain(..n);
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        failed = true;
                        break;
                    }
                }
            }
        }
        if failed {
            self.drop_scene_client(conn);
        }
    }

    fn drop_scene_client(&mut self, conn: u64) {
        let Some(c) = self.scene.conns.remove(&conn) else { return };
        if let Some(t) = c.token {
            self.handle.remove(t);
        }
    }

    /// Clears any cached window binding when a window is destroyed.
    pub fn scene_window_gone(&mut self, window: u64) {
        for c in self.scene.conns.values_mut() {
            if c.window == Some(window) {
                c.window = None;
            }
            c.coalesced_scrolls.retain(|&(w, _), _| w != window);
        }
    }

    /// Returns all currently live windows owned by `pid` (or its process lineage).
    fn owned_scene_windows(&self, pid: u32, client_lineage: &[u32]) -> Vec<u64> {
        if pid == 0 {
            return Vec::new();
        }
        use smithay::reexports::wayland_server::Resource;
        let mut owned = Vec::new();
        for w in self.windows.iter() {
            let owner = match &w.surface {
                crate::windows::Surface::Toplevel(t) => self
                    .dh
                    .get_client(t.wl_surface().id())
                    .ok()
                    .and_then(|cl| cl.get_credentials(&self.dh).ok())
                    .map(|cr| cr.pid as u32),
                crate::windows::Surface::Popup(p) => self
                    .dh
                    .get_client(p.wl_surface().id())
                    .ok()
                    .and_then(|cl| cl.get_credentials(&self.dh).ok())
                    .map(|cr| cr.pid as u32),
                crate::windows::Surface::X11(x) if w.parent.is_none() => x.pid().or_else(|| x.get_client_pid().ok()),
                _ => None,
            };
            if let Some(o) = owner {
                if o == pid || client_lineage.contains(&o) {
                    owned.push(w.id);
                } else {
                    let w_lineage = crate::video::lineage(o);
                    if crate::video::related(&w_lineage, client_lineage) {
                        owned.push(w.id);
                    }
                }
            }
        }
        owned
    }

    fn on_scene_font(&mut self, conn: u64, font: proto::SceneFont) {
        let Some(c) = self.scene.conns.get(&conn) else { return };
        if c.pid == 0 || self.owned_scene_windows(c.pid, &c.lineage).is_empty() {
            return;
        }
        let session_conn = self.session.as_ref().filter(|s| s.ready && s.scene).map(|s| s.conn);
        if self.scene.record_font_for_session(font.clone(), session_conn.is_some()) {
            if let Some(sconn) = session_conn {
                self.net.send(sconn, &Message::SceneFont(font));
            }
        }
    }

    fn on_scene_commit(&mut self, conn: u64, mut commit: proto::SceneCommit) {
        let (pid, lineage) = {
            let Some(c) = self.scene.conns.get(&conn) else { return };
            (c.pid, c.lineage.clone())
        };
        let owned = self.owned_scene_windows(pid, &lineage);
        let Some(authorized_window) = authorize_scene_window(&owned, commit.id) else {
            if let Some(c) = self.scene.conns.get_mut(&conn) {
                c.window = None;
            }
            tracing::debug!(
                "scene client {conn} (pid {pid}): rejected commit for window {} (owned: {owned:?})",
                commit.id
            );
            return;
        };
        if let Some(c) = self.scene.conns.get_mut(&conn) {
            c.window = Some(authorized_window);
        }
        commit.id = authorized_window;
        if commit.pts_us == 0 {
            commit.pts_us = self.now_us();
        }
        let Some(session_conn) = self.session.as_ref().filter(|s| s.ready && s.scene).map(|s| s.conn) else {
            return;
        };
        // Ensure any fonts referenced by nodes in this commit have been sent to the session
        for node in &commit.nodes {
            if let Some(fhash) = node.font {
                if !self.scene.sent_fonts.contains(&fhash) {
                    if let Some(font) = self.scene.fonts.get(&fhash).cloned() {
                        self.scene.sent_fonts.insert(fhash);
                        self.net.send(session_conn, &Message::SceneFont(font));
                    }
                }
            }
        }
        self.net.send(session_conn, &Message::SceneCommit(commit));
    }

    /// Forwards a client-predicted `SceneScroll` (`0x9A`) non-blockingly to the verified toolkit
    /// connection owning `scroll.id`.
    pub fn on_scene_scroll(&mut self, scroll: SceneScroll) {
        let target_window = scroll.id;
        if self.windows.get(target_window).is_none() {
            return;
        }
        let cids: Vec<u64> = self.scene.conns.keys().copied().collect();
        let mut matched = Vec::new();
        for cid in cids {
            let Some((pid, lineage, current_win)) =
                self.scene.conns.get(&cid).map(|c| (c.pid, c.lineage.clone(), c.window))
            else {
                continue;
            };
            let owned = self.owned_scene_windows(pid, &lineage);
            if let Some(prev) = current_win {
                if !owned.contains(&prev) {
                    if let Some(c) = self.scene.conns.get_mut(&cid) {
                        c.window = None;
                    }
                }
            }
            let bound = self.scene.conns.get(&cid).and_then(|c| c.window);
            let is_target = if bound == Some(target_window) {
                owned.contains(&target_window)
            } else if bound.is_none() && owned.as_slice() == [target_window] {
                if let Some(c) = self.scene.conns.get_mut(&cid) {
                    c.window = Some(target_window);
                }
                true
            } else {
                false
            };
            if is_target {
                matched.push(cid);
            }
        }
        for cid in matched {
            let overflow = if let Some(c) = self.scene.conns.get_mut(&cid) {
                !coalesce_scroll(&mut c.coalesced_scrolls, scroll.clone())
            } else {
                false
            };
            if overflow {
                tracing::warn!("scene client {cid}: scroll queue overflow; closing");
                self.drop_scene_client(cid);
            } else {
                self.flush_scene_client(cid);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deduplicates_fonts_within_session_and_enforces_limits() {
        let mut server = SceneServer::default();
        let font = proto::SceneFont {
            font: 0x1122334455667788,
            index: 0,
            family: Some("Inter".into()),
            data: vec![0, 1, 2, 3],
        };
        // Empty font is rejected.
        let empty = proto::SceneFont { font: 1, index: 0, family: None, data: vec![] };
        assert!(!server.record_font_for_session(empty, true));

        // Headless liveness: when no session is active, font is retained but not marked sent.
        assert!(!server.record_font_for_session(font.clone(), false));
        assert!(server.fonts.contains_key(&font.font));
        // Once a session is active, first emission returns true, second returns false.
        assert!(server.record_font_for_session(font.clone(), true));
        assert!(!server.record_font_for_session(font.clone(), true));
        // After reset_session, the next session receives it again.
        server.reset_session();
        assert!(server.record_font_for_session(font, true));
    }

    #[test]
    fn authorize_scene_window_rejects_foreign_and_ambiguous_windows() {
        // Peer owns window 7 only:
        assert_eq!(authorize_scene_window(&[7], 7), Some(7));
        assert_eq!(authorize_scene_window(&[7], 0), Some(7));
        assert_eq!(authorize_scene_window(&[7], 8), None); // foreign window rejected!

        // Peer owns multiple windows [7, 9]:
        assert_eq!(authorize_scene_window(&[7, 9], 7), Some(7));
        assert_eq!(authorize_scene_window(&[7, 9], 9), Some(9));
        assert_eq!(authorize_scene_window(&[7, 9], 0), None); // ambiguous 0 rejected!
        assert_eq!(authorize_scene_window(&[7, 9], 10), None); // foreign rejected!

        // Peer owns no windows:
        assert_eq!(authorize_scene_window(&[], 0), None);
        assert_eq!(authorize_scene_window(&[], 7), None);
    }

    #[test]
    fn coalesce_scroll_overwrites_same_node_and_caps_distinct_nodes() {
        let mut map = BTreeMap::new();
        for i in 0..100 {
            assert!(coalesce_scroll(
                &mut map,
                SceneScroll { id: 7, node: 1, sx: 0.0, sy: i as f64 }
            ));
        }
        assert_eq!(map.len(), 1);
        assert_eq!(map.get(&(7, 1)).unwrap().sy, 99.0);

        for node in 2..=(MAX_PENDING_SCROLL_NODES as u64) {
            assert!(coalesce_scroll(
                &mut map,
                SceneScroll { id: 7, node, sx: 0.0, sy: 1.0 }
            ));
        }
        assert_eq!(map.len(), MAX_PENDING_SCROLL_NODES);
        // 65th distinct node while stalled returns false
        assert!(!coalesce_scroll(
            &mut map,
            SceneScroll { id: 7, node: 999, sx: 0.0, sy: 1.0 }
        ));
    }
}
