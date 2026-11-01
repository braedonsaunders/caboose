//! The draw socket: applications' draw-list recorders (guest/draw, docs/draw.md) connect here,
//! and their recordings go to a client that draws them (`draw.ops`, `draw.present`,
//! `draw.end`).
//!
//! The socket is `draw.sock` in the instance's private directory, owner-only. A recorder records
//! nothing until the compositor asks it to: when a client whose hello says `draw` connects, each
//! recorder gets `R` and a generation, and from its next frame sends a fresh stream that starts
//! with `begin` of that generation, so the client never sees ops whose surfaces and resources it
//! missed. `S` stops it when the client leaves. Bytes before the `begin` the compositor asked for
//! are dropped. Each (connection, generation) is one stream to the client. A `present` names a
//! wl_surface by its protocol id, which, with the recorder's process, identifies the window.
//!
//! The recorder never waits on this socket (it drops recording rather than block), and the
//! compositor drains it whether or not a client draws, so applications never stall.

use crate::state::State;
use caboose_display_protocol::draw::{self, Op};
use caboose_display_protocol::{self as proto, Message};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::{Interest, LoopHandle, Mode as Trigger, PostAction, RegistrationToken};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// Recorders connected at once.
pub const MAX_CONNS: usize = 128;
/// The largest single op accepted (an image of 4096 × 4096 pixels).
pub const MAX_OP: usize = 64 << 20;
/// `draw.ops` payloads are cut at this size; a client concatenates a stream's payloads.
pub const CHUNK: usize = 1 << 20;

/// A piece of a recorder's stream, in order.
#[derive(Debug, PartialEq, Eq)]
pub enum Piece {
    /// Validated ops, to forward as they are.
    Ops(Vec<u8>),
    /// A stream started with this generation (`begin`).
    Begin(u32),
    /// A window buffer was committed to a wl_surface.
    Present { surface: u32, wl_surface: u32 },
}

/// Splits a recorder's byte stream into validated ops, separating `begin` and `present`.
#[derive(Default)]
pub struct Splitter {
    buf: Vec<u8>,
    at: usize,
}

impl Splitter {
    pub fn push(&mut self, bytes: &[u8]) {
        if self.at > 0 && self.at == self.buf.len() {
            self.buf.clear();
            self.at = 0;
        }
        self.buf.extend_from_slice(bytes);
    }

    /// The next piece, `None` until more bytes arrive, or an error for an op that does not
    /// fit its kind or exceeds [`MAX_OP`] (the stream cannot be trusted after it).
    pub fn next(&mut self) -> Option<Result<Piece, draw::DrawError>> {
        let mut ops = Vec::new();
        loop {
            let rest = &self.buf[self.at..];
            if rest.len() < 5 {
                break;
            }
            let len = u32::from_le_bytes([rest[1], rest[2], rest[3], rest[4]]) as usize;
            if len > MAX_OP {
                return Some(Err(draw::DrawError { op: rest[0], offset: self.at }));
            }
            if rest.len() < 5 + len {
                break;
            }
            let whole = &rest[..5 + len];
            match draw::Reader::new(whole).next() {
                Some(Ok(Op::Begin { .. } | Op::Present { .. })) if !ops.is_empty() => {
                    // Forward what came before it first.
                    break;
                }
                Some(Ok(Op::Begin { generation })) => {
                    self.at += whole.len();
                    return Some(Ok(Piece::Begin(generation)));
                }
                Some(Ok(Op::Present { surface, wl_surface })) => {
                    self.at += whole.len();
                    return Some(Ok(Piece::Present { surface, wl_surface }));
                }
                Some(Ok(_)) => {
                    ops.extend_from_slice(whole);
                    self.at += whole.len();
                    if ops.len() >= CHUNK {
                        break;
                    }
                }
                Some(Err(e)) => return Some(Err(draw::DrawError { op: e.op, offset: self.at })),
                None => break,
            }
        }
        if self.at == self.buf.len() {
            self.buf.clear();
            self.at = 0;
        } else if self.at > (1 << 20) {
            self.buf.drain(..self.at);
            self.at = 0;
        }
        (!ops.is_empty()).then_some(Ok(Piece::Ops(ops)))
    }
}

struct Recorder {
    out: UnixStream,
    pid: u32,
    splitter: Splitter,
    /// The generation asked of it, and the stream its `begin` started, if it has.
    asked: Option<u32>,
    stream: Option<u32>,
    token: Option<RegistrationToken>,
}

#[derive(Default)]
pub struct DrawServer {
    pub socket: Option<PathBuf>,
    recorders: HashMap<u64, Recorder>,
    next_conn: u64,
    next_stream: u32,
    generation: u32,
    /// Whether the client draws: recorders are asked to record.
    drawing: bool,
}

impl DrawServer {
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
                        Ok((stream, _)) => state.accept_draw_recorder(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("draw socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { socket: Some(path.to_owned()), ..Self::default() })
    }
}

/// `R` and the generation: start a fresh stream at the next frame.
fn start_command(generation: u32) -> [u8; 5] {
    let g = generation.to_le_bytes();
    [b'R', g[0], g[1], g[2], g[3]]
}

impl State {
    /// A client that draws draw lists connected (`drawing`), or the session ended.
    pub fn draw_session(&mut self, drawing: bool) {
        let server = &mut self.draw;
        server.drawing = drawing;
        server.generation = server.generation.wrapping_add(1);
        let generation = server.generation;
        for r in server.recorders.values_mut() {
            r.stream = None;
            r.asked = drawing.then_some(generation);
            let command: &[u8] = if drawing { &start_command(generation) } else { b"S" };
            // A recorder that cannot take five bytes is stuck; it is dropped when it closes.
            let _ = r.out.write(command);
        }
    }

    fn accept_draw_recorder(&mut self, stream: UnixStream) {
        if self.draw.recorders.len() >= MAX_CONNS {
            tracing::warn!("draw socket: connection limit ({MAX_CONNS}) reached");
            return;
        }
        let Some((uid, pid)) = crate::scene::peer_credentials(&stream) else { return };
        // SAFETY: getuid is always safe to call.
        if uid != unsafe { libc::getuid() } {
            tracing::warn!("draw socket: refused a peer of another user");
            return;
        }
        let (Ok(mut out), Ok(())) = (stream.try_clone(), stream.set_nonblocking(true)) else { return };
        let _ = out.set_nonblocking(true);
        let asked = self.draw.drawing.then_some(self.draw.generation);
        if let Some(generation) = asked {
            let _ = out.write(&start_command(generation));
        }
        self.draw.next_conn += 1;
        let id = self.draw.next_conn;
        self.draw.recorders.insert(id, Recorder { out, pid, splitter: Splitter::default(), asked, stream: None, token: None });
        let token = self.handle.insert_source(Generic::new(stream, Interest::READ, Trigger::Level), move |_, stream, state: &mut State| {
            let mut buf = vec![0u8; 256 * 1024];
            let mut closed = false;
            loop {
                // SAFETY: the stream is not dropped while the source exists.
                match unsafe { stream.get_mut() }.read(&mut buf) {
                    Ok(0) => {
                        closed = true;
                        break;
                    }
                    Ok(n) => {
                        if let Some(r) = state.draw.recorders.get_mut(&id) {
                            r.splitter.push(&buf[..n]);
                        }
                        if n < buf.len() {
                            break;
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
            if !state.drain_draw_recorder(id) {
                closed = true;
            }
            if closed {
                state.drop_draw_recorder(id);
                return Ok(PostAction::Remove);
            }
            Ok(PostAction::Continue)
        });
        match token {
            Ok(t) => {
                tracing::debug!("draw recorder {id}: pid {pid} connected");
                if let Some(r) = self.draw.recorders.get_mut(&id) {
                    r.token = Some(t);
                }
            }
            Err(e) => {
                tracing::warn!("draw socket: {e}");
                self.draw.recorders.remove(&id);
            }
        }
    }

    /// Forwards what the recorder sent; false when its stream is broken.
    fn drain_draw_recorder(&mut self, id: u64) -> bool {
        loop {
            let Some(r) = self.draw.recorders.get_mut(&id) else { return false };
            let piece = match r.splitter.next() {
                None => return true,
                Some(Ok(piece)) => piece,
                Some(Err(e)) => {
                    tracing::warn!("draw recorder {id} (pid {}): {e}; closing", r.pid);
                    return false;
                }
            };
            let session = self.session.as_ref().filter(|s| s.ready && s.draw).map(|s| s.conn);
            match piece {
                Piece::Begin(generation) => {
                    let ended = r.stream.take();
                    if r.asked == Some(generation) && session.is_some() {
                        self.draw.next_stream = self.draw.next_stream.wrapping_add(1).max(1);
                        r.stream = Some(self.draw.next_stream);
                    }
                    if let (Some(stream), Some(conn)) = (ended, session) {
                        self.net.send(conn, &Message::DrawEnd { stream });
                    }
                }
                Piece::Ops(ops) => {
                    if let (Some(stream), Some(conn)) = (r.stream, session) {
                        self.net.send(conn, &Message::DrawOps(proto::DrawOps { stream, ops }));
                    }
                }
                Piece::Present { surface, wl_surface } => {
                    let (Some(stream), Some(conn)) = (r.stream, session) else { continue };
                    let pid = r.pid;
                    let Some(window) = self.draw_window(pid, wl_surface) else { continue };
                    let pts_us = self.now_us();
                    self.net.send(conn, &Message::DrawPresent(proto::DrawPresent { id: window, stream, surface, pts_us }));
                }
            }
        }
    }

    fn drop_draw_recorder(&mut self, id: u64) {
        let Some(r) = self.draw.recorders.remove(&id) else { return };
        if let Some(token) = r.token {
            self.handle.remove(token);
        }
        if let (Some(stream), Some(conn)) = (r.stream, self.session.as_ref().filter(|s| s.ready && s.draw).map(|s| s.conn)) {
            self.net.send(conn, &Message::DrawEnd { stream });
        }
    }

    /// The window whose root surface is wl_surface `protocol_id` of process `pid`.
    fn draw_window(&self, pid: u32, protocol_id: u32) -> Option<u64> {
        use smithay::reexports::wayland_server::Resource;
        self.windows.iter().find_map(|w| {
            let surface = w.surface.wl_surface()?;
            (surface.id().protocol_id() == protocol_id && self.window_pid(&w.surface) == Some(pid)).then_some(w.id)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(code: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![code];
        out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn u32s(values: &[u32]) -> Vec<u8> {
        values.iter().flat_map(|v| v.to_le_bytes()).collect()
    }

    #[test]
    fn splits_a_stream_at_begin_and_present_wherever_its_bytes_break() {
        let mut stream = op(draw::BEGIN, &u32s(&[4]));
        let surface = op(draw::SURFACE, &[u32s(&[1, 64, 32]), vec![1]].concat());
        let target = op(draw::TARGET, &u32s(&[1]));
        stream.extend(&surface);
        stream.extend(&target);
        stream.extend(op(draw::PRESENT, &u32s(&[1, 12])));
        stream.extend(&target);
        for cut in 0..stream.len() {
            let mut s = Splitter::default();
            let mut pieces = Vec::new();
            for part in [&stream[..cut], &stream[cut..]] {
                s.push(part);
                while let Some(p) = s.next() {
                    pieces.push(p.unwrap());
                }
            }
            // Ops that arrive in two reads may come as two pieces; joined, they are the same.
            let mut joined: Vec<Piece> = Vec::new();
            for p in pieces {
                match (joined.last_mut(), p) {
                    (Some(Piece::Ops(a)), Piece::Ops(b)) => a.extend(b),
                    (_, p) => joined.push(p),
                }
            }
            assert_eq!(
                joined,
                [
                    Piece::Begin(4),
                    Piece::Ops([surface.clone(), target.clone()].concat()),
                    Piece::Present { surface: 1, wl_surface: 12 },
                    Piece::Ops(target.clone()),
                ],
                "cut at {cut}"
            );
        }
    }

    #[test]
    fn a_malformed_op_breaks_the_stream() {
        let mut s = Splitter::default();
        s.push(&op(draw::TARGET, &[1, 0, 0])); // three bytes where four belong
        assert!(matches!(s.next(), Some(Err(_))));
        let mut s = Splitter::default();
        let mut huge = vec![draw::IMAGE];
        huge.extend_from_slice(&((MAX_OP + 1) as u32).to_le_bytes());
        s.push(&huge);
        assert!(matches!(s.next(), Some(Err(_))));
    }
}
