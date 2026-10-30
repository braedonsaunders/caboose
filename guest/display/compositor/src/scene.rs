//! Scene Socket (`$XDG_RUNTIME_DIR/caboose-scene.sock`): non-blocking Unix domain stream
//! listener for retained vector & glyph scene graphs (`scene.font` `0x25` and
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
use std::collections::{HashMap, HashSet};
use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

struct SceneClient {
    out: UnixStream,
    pending: Vec<u8>,
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
}

/// `$CABOOSE_SCENE_SOCKET`, else `$XDG_RUNTIME_DIR/caboose-scene.sock`.
pub fn socket_path() -> Option<PathBuf> {
    std::env::var_os("CABOOSE_SCENE_SOCKET")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR").map(|d| Path::new(&d).join("caboose-scene.sock")))
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

    /// Records a font and returns `true` if it has not yet been sent to the current session.
    pub fn record_font_for_session(&mut self, font: proto::SceneFont, session_active: bool) -> bool {
        let hash = font.font;
        self.fonts.entry(hash).or_insert_with(|| font.clone());
        session_active && self.sent_fonts.insert(hash)
    }
}

impl State {
    fn accept_scene_client(&mut self, stream: UnixStream) {
        let pid = crate::video::server::peer_pid(&stream).unwrap_or(0);
        let (Ok(out), Ok(())) = (stream.try_clone(), stream.set_nonblocking(true)) else { return };
        self.scene.next_conn += 1;
        let id = self.scene.next_conn;
        let lineage = if pid > 0 { crate::video::lineage(pid) } else { Vec::new() };
        self.scene.conns.insert(
            id,
            SceneClient {
                out,
                pending: Vec::new(),
                decoder: StreamDecoder::new(),
                pid,
                lineage,
                window: None,
                token: None,
            },
        );
        let token = self.handle.insert_source(
            Generic::new(stream, Interest::READ, Trigger::Level),
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
                if closed {
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

    fn drop_scene_client(&mut self, conn: u64) {
        let Some(c) = self.scene.conns.remove(&conn) else { return };
        if let Some(t) = c.token {
            self.handle.remove(t);
        }
    }

    fn resolve_scene_window(&mut self, conn: u64) -> Option<u64> {
        let c = self.scene.conns.get(&conn)?;
        if let Some(w) = c.window.filter(|id| self.windows.get(*id).is_some()) {
            return Some(w);
        }
        let pid = c.pid;
        if pid == 0 {
            return None;
        }
        let client_lineage = c.lineage.clone();
        let dh = self.dh.clone();
        let found = self.windows.find(|w| {
            use smithay::reexports::wayland_server::Resource;
            let owner = match &w.surface {
                crate::windows::Surface::Toplevel(t) => dh
                    .get_client(t.wl_surface().id())
                    .ok()
                    .and_then(|cl| cl.get_credentials(&dh).ok())
                    .map(|cr| cr.pid as u32),
                crate::windows::Surface::X11(x) if w.parent.is_none() => x.pid().or_else(|| x.get_client_pid().ok()),
                _ => None,
            };
            owner.is_some_and(|o| o == pid || client_lineage.contains(&o))
        });
        if let Some(w) = found {
            if let Some(c) = self.scene.conns.get_mut(&conn) {
                c.window = Some(w);
            }
        }
        found
    }

    fn on_scene_font(&mut self, _conn: u64, font: proto::SceneFont) {
        let session_conn = self.session.as_ref().filter(|s| s.ready && s.scene).map(|s| s.conn);
        if self.scene.record_font_for_session(font.clone(), session_conn.is_some()) {
            if let Some(conn) = session_conn {
                self.net.send(conn, &Message::SceneFont(font));
            }
        }
    }

    fn on_scene_commit(&mut self, conn: u64, mut commit: proto::SceneCommit) {
        if commit.id == 0 {
            if let Some(w) = self.resolve_scene_window(conn) {
                commit.id = w;
            }
        } else if let Some(c) = self.scene.conns.get_mut(&conn) {
            c.window = Some(commit.id);
        }
        if commit.pts_us == 0 {
            commit.pts_us = self.now_us();
        }
        let Some(session_conn) = self.session.as_ref().filter(|s| s.ready && s.scene).map(|s| s.conn) else {
            return;
        };
        if commit.id == 0 {
            return;
        }
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

    /// Forwards a client-predicted `SceneScroll` (`0x9A`) non-blockingly to the toolkit
    /// connection owning `scroll.id`.
    pub fn on_scene_scroll(&mut self, scroll: SceneScroll) {
        let target_window = scroll.id;
        let encoded = proto::encode(&Message::SceneScroll(scroll));
        let matching: Vec<u64> = self
            .scene
            .conns
            .iter()
            .filter(|(_, c)| c.window == Some(target_window))
            .map(|(id, _)| *id)
            .collect();
        let targets = if matching.is_empty() {
            // Try resolving unresolved connections first
            let unresolved: Vec<u64> = self
                .scene
                .conns
                .iter()
                .filter(|(_, c)| c.window.is_none())
                .map(|(id, _)| *id)
                .collect();
            let mut resolved = Vec::new();
            for cid in unresolved {
                if self.resolve_scene_window(cid) == Some(target_window) {
                    resolved.push(cid);
                }
            }
            resolved
        } else {
            matching
        };
        for cid in targets {
            if let Some(c) = self.scene.conns.get_mut(&cid) {
                c.pending.extend_from_slice(&encoded);
                while !c.pending.is_empty() {
                    match c.out.write(&c.pending) {
                        Ok(n) => {
                            c.pending.drain(..n);
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            c.pending.clear();
                            break;
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deduplicates_fonts_within_session_and_resets_across_sessions() {
        let mut server = SceneServer::default();
        let font = proto::SceneFont {
            font: 0x1122334455667788,
            family: "Inter".into(),
            weight: 400,
            italic: false,
            data: vec![0, 1, 2, 3],
        };
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
}
