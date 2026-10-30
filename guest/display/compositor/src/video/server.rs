//! The compositor's side of the video socket: driver connections, the ACCEPT/DECODE
//! decision, forwarding access units to the client, and binding streams to windows from
//! the markers the encode workers find.

use super::ipc::{self, CompositorMessage, DriverMessage, Framer};
use super::{create_message, frame_message, lineage, marker, Binding, Streams, Unit, MISSES_TO_UNBIND};
use crate::state::State;
use caboose_display_protocol::{self as proto, Codec, Message, Rect};
use smithay::reexports::calloop::{generic::Generic, Interest, LoopHandle, Mode, PostAction, RegistrationToken};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

struct DriverConn {
    out: UnixStream,
    pending: Vec<u8>,
    framer: Framer,
    pid: u32,
    program: String,
    lineage: Vec<u32>,
    token: Option<RegistrationToken>,
}

#[derive(Default)]
pub struct Videos {
    /// The socket path, when listening.
    pub socket: Option<PathBuf>,
    pub streams: Streams,
    conns: HashMap<u64, DriverConn>,
    next_conn: u64,
}

/// The peer's pid, from the kernel rather than from what it says.
pub(crate) fn peer_pid(stream: &UnixStream) -> Option<u32> {
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
    (r == 0 && cred.pid > 0).then_some(cred.pid as u32)
}

/// `$CABOOSE_VIDEO_SOCKET`, else `$XDG_RUNTIME_DIR/caboose-video.sock`.
pub fn socket_path() -> Option<PathBuf> {
    std::env::var_os("CABOOSE_VIDEO_SOCKET")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR").map(|d| Path::new(&d).join("caboose-video.sock")))
}

impl Videos {
    pub fn listen(path: &Path, handle: &LoopHandle<'static, State>) -> io::Result<Self> {
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        handle
            .insert_source(Generic::new(listener, Interest::READ, Mode::Level), |_, listener, state: &mut State| {
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => state.accept_driver(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("video socket accept: {e}");
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

impl State {
    fn accept_driver(&mut self, stream: UnixStream) {
        let Some(pid) = peer_pid(&stream) else {
            tracing::warn!("video socket: no peer credentials");
            return;
        };
        let (Ok(out), Ok(())) = (stream.try_clone(), stream.set_nonblocking(true)) else { return };
        self.videos.next_conn += 1;
        let id = self.videos.next_conn;
        let conn = DriverConn {
            out,
            pending: Vec::new(),
            framer: Framer::default(),
            pid,
            program: String::new(),
            lineage: lineage(pid),
            token: None,
        };
        self.videos.conns.insert(id, conn);
        let token = self.handle.insert_source(
            Generic::new(stream, Interest::READ, Mode::Level),
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
                            if let Some(c) = state.videos.conns.get_mut(&id) {
                                c.framer.push(&buf[..n]);
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
                state.drain_driver(id);
                if closed {
                    state.drop_driver(id);
                    return Ok(PostAction::Remove);
                }
                Ok(PostAction::Continue)
            },
        );
        match token {
            Ok(t) => {
                if let Some(c) = self.videos.conns.get_mut(&id) {
                    c.token = Some(t);
                }
                tracing::info!("video driver connected (pid {pid})");
            }
            Err(e) => {
                tracing::warn!("video socket: {e}");
                self.videos.conns.remove(&id);
            }
        }
    }

    fn drain_driver(&mut self, conn: u64) {
        loop {
            let Some(c) = self.videos.conns.get_mut(&conn) else { return };
            match c.framer.next_message() {
                Ok(Some((t, payload))) => match DriverMessage::parse(t, &payload) {
                    Ok(m) => self.on_driver_message(conn, m),
                    Err(e) => tracing::debug!("video driver {conn}: {e:?}"),
                },
                Ok(None) => break,
                Err(e) => {
                    tracing::warn!("video driver {conn}: {e:?}; closing");
                    self.drop_driver(conn);
                    return;
                }
            }
        }
        self.flush_driver(conn);
    }

    fn drop_driver(&mut self, conn: u64) {
        let Some(c) = self.videos.conns.remove(&conn) else { return };
        if let Some(t) = c.token {
            self.handle.remove(t);
        }
        let ids: Vec<u64> = self.videos.streams.by_id.values().filter(|s| s.conn == conn).map(|s| s.id).collect();
        for id in ids {
            self.close_video(id);
        }
        tracing::info!("video driver {} (pid {}) gone", c.program, c.pid);
    }

    fn send_driver(&mut self, conn: u64, m: CompositorMessage) {
        if let Some(c) = self.videos.conns.get_mut(&conn) {
            c.pending.extend_from_slice(&m.encode());
        }
        self.flush_driver(conn);
    }

    fn flush_driver(&mut self, conn: u64) {
        let Some(c) = self.videos.conns.get_mut(&conn) else { return };
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

    /// The client's video decoders, when a client is connected.
    fn client_video_decoders(&self) -> Option<&[Codec]> {
        self.session.as_ref().filter(|s| s.ready).map(|s| s.video_decoders.as_slice())
    }

    fn on_driver_message(&mut self, conn: u64, m: DriverMessage) {
        match m {
            DriverMessage::Hello { version, program, .. } => {
                if let Some(c) = self.videos.conns.get_mut(&conn) {
                    tracing::info!("video driver {conn}: {program} (pid {}, protocol {version})", c.pid);
                    if version != ipc::PROTO_VERSION {
                        tracing::warn!(
                            "video driver {conn} speaks protocol {version}, this compositor {}",
                            ipc::PROTO_VERSION
                        );
                    }
                    c.program = program;
                }
            }
            DriverMessage::Open { stream, codec, .. } => {
                // A flattened marker identifies geometry, not foreground alpha or
                // occlusion. Even exact marker-colored controls are ambiguous.
                // No current driver message supplies independent composition planes,
                // so decoder support cannot authorize replacing this rectangle.
                // Decode before the application composites its controls/subtitles,
                // including when no phone is connected.
                tracing::debug!(stream, codec, "video uses local decode: marker has no composition provenance");
                self.send_driver(conn, CompositorMessage::Accept { stream, tag: 0, mode: ipc::mode::DECODE });
            }
            DriverMessage::Frame { stream, seq, flags, data, .. } => {
                let Some(s) = self.videos.streams.by_driver(conn, stream) else { return };
                let unit = Unit { seq, key: flags & ipc::frame_flags::KEY != 0, data: Arc::new(data) };
                let replay = flags & ipc::frame_flags::REPLAY != 0;
                // Hidden frames (reference-only, or shown later) go to the client like the
                // rest: what is shown, and when, comes from video.present.
                if flags & ipc::frame_flags::HIDDEN != 0 {
                    tracing::trace!("video stream {}: frame {seq} hidden", s.id);
                }
                let id = s.id;
                let send = s.binding.as_ref().is_some_and(|b| b.announced);
                if !replay {
                    s.push(unit.clone());
                }
                if send {
                    if let Some(c) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) {
                        self.net.send(c, &frame_message(id, &unit));
                    }
                }
            }
            DriverMessage::Close { stream, reason } => {
                if let Some(id) = self.videos.streams.by_driver(conn, stream).map(|s| s.id) {
                    tracing::info!("video stream {id} closed: {}", ipc::close::name(reason));
                    self.close_video(id);
                }
            }
            DriverMessage::Surface { surface, dev, ino } => {
                tracing::debug!("video driver {conn}: surface {surface} is dmabuf {dev:x}:{ino} (bound by marker)");
            }
            DriverMessage::SurfaceGone { .. } => {}
        }
    }

    fn close_video(&mut self, id: u64) {
        let Some(s) = self.videos.streams.close(id) else { return };
        if s.binding.is_some_and(|b| b.announced) {
            if let Some(c) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) {
                self.net.send(c, &Message::VideoDestroy { id });
            }
        }
    }

    /// Sends `video.create` and the frames since the last keyframe.
    fn announce_video(&mut self, id: u64) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        let Some(s) = self.videos.streams.by_id.get_mut(&id) else { return };
        let Some(b) = s.binding.as_mut() else { return };
        b.announced = true;
        let create = create_message(s, s.binding.as_ref().unwrap());
        let units: Vec<Unit> = s.gop.clone();
        s.first_sent = units.first().map(|u| u.seq).or_else(|| s.recent.back().map(|q| q + 1));
        s.presented = None;
        self.net.send(conn, &create);
        for u in &units {
            self.net.send(conn, &frame_message(id, u));
        }
    }

    /// A new client: ask the driver to decode what it cannot play, re-announce the rest.
    pub fn video_session_started(&mut self) {
        let decoders = self.client_video_decoders().map(<[Codec]>::to_vec).unwrap_or_default();
        for id in self.videos.streams.ids() {
            let Some(s) = self.videos.streams.by_id.get_mut(&id) else { continue };
            if let Some(b) = s.binding.as_mut() {
                b.announced = false; // that was for the previous client
            }
            if !s.passthrough {
                continue;
            }
            if !decoders.contains(&s.codec) {
                s.passthrough = false;
                let (conn, stream) = (s.conn, s.driver_stream);
                self.send_driver(conn, CompositorMessage::Decode { stream, reason: ipc::decode_reason::CLIENT_CODEC });
                continue;
            }
            if s.binding.is_some() {
                self.announce_video(id);
            }
        }
    }

    pub fn video_session_ended(&mut self) {
        for s in self.videos.streams.by_id.values_mut() {
            if let Some(b) = s.binding.as_mut() {
                b.announced = false;
            }
        }
    }

    pub fn video_keyframe(&mut self, id: u64) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        let Some(s) = self.videos.streams.by_id.get_mut(&id) else { return };
        if s.passthrough && s.client_failed(std::time::Instant::now()) {
            // The client cannot decode it: the driver decodes, the window stream shows it.
            tracing::info!("video stream {id}: the client keeps failing to decode it; decoding locally");
            s.passthrough = false;
            let (c, stream, bound) = (s.conn, s.driver_stream, s.binding.take().is_some_and(|b| b.announced));
            if bound {
                self.net.send(conn, &Message::VideoDestroy { id });
            }
            self.send_driver(c, CompositorMessage::Decode { stream, reason: ipc::decode_reason::CLIENT_ERRORS });
            return;
        }
        let Some(s) = self.videos.streams.by_id.get(&id) else { return };
        if !s.binding.as_ref().is_some_and(|b| b.announced) {
            return;
        }
        if s.gop.first().is_some_and(|u| u.key) {
            let units = s.gop.clone();
            for u in &units {
                self.net.send(conn, &frame_message(id, u));
            }
        } else {
            let (c, stream) = (s.conn, s.driver_stream);
            self.send_driver(c, CompositorMessage::Replay { stream });
        }
    }

    /// A window went away: its videos are no longer shown there.
    pub fn video_window_gone(&mut self, window: u64) {
        for s in self.videos.streams.by_id.values_mut() {
            if s.binding.as_ref().is_some_and(|b| b.window == window) {
                s.binding = None;
                s.misses = 0;
            }
        }
    }

    /// Markers found in a window picture: bind, move and present streams.
    pub fn on_video_hits(&mut self, window: u64, hits: &[marker::Hit], rect: Rect, crop: Rect, pts_us: u64) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        let (sx, sy) = (rect.w as f64 / crop.w.max(1) as f64, rect.h as f64 / crop.h.max(1) as f64);
        let mut seen = Vec::new();
        for hit in hits {
            let Some(s) = self.videos.streams.by_tag(hit.tag) else { continue };
            if !s.passthrough {
                continue;
            }
            let id = s.id;
            seen.push(id);
            s.misses = 0;
            let (video_rect, clip) = super::to_window(hit, sx, sy);
            let moved = |b: &Binding| {
                let far = |a: Rect, b: Rect| {
                    (a.x - b.x).abs() > 1 || (a.y - b.y).abs() > 1 || (a.w - b.w).abs() > 1 || (a.h - b.h).abs() > 1
                };
                far(b.rect, video_rect) || far(b.clip, clip)
            };
            match s.binding.clone() {
                Some(b) if b.window == window && b.announced => {
                    if moved(&b) {
                        s.binding = Some(Binding { rect: video_rect, clip, ..b });
                        let update = proto::VideoUpdate { id, rect: Some(video_rect), clip: Some(clip), z: None };
                        self.net.send(conn, &Message::VideoUpdate(update));
                    }
                }
                previous => {
                    if previous.is_some_and(|b| b.announced) {
                        self.net.send(conn, &Message::VideoDestroy { id });
                    }
                    s.binding = Some(Binding { window, rect: video_rect, clip, announced: false });
                    self.announce_video(id);
                }
            }
            let Some(s) = self.videos.streams.by_id.get_mut(&id) else { continue };
            if let Some(seq) = s.resolve(hit.seq) {
                if s.presented != Some(seq) {
                    s.presented = Some(seq);
                    self.net.send(conn, &Message::VideoPresent { id, seq: seq as u64, pts_us });
                }
            }
        }
        // Streams bound here that this picture no longer shows.
        let gone: Vec<u64> = self
            .videos
            .streams
            .by_id
            .values_mut()
            .filter(|s| s.binding.as_ref().is_some_and(|b| b.window == window) && !seen.contains(&s.id))
            .filter_map(|s| {
                s.misses += 1;
                (s.misses >= MISSES_TO_UNBIND).then_some(s.id)
            })
            .collect();
        for id in gone {
            if let Some(s) = self.videos.streams.by_id.get_mut(&id) {
                if s.binding.take().is_some_and(|b| b.announced) {
                    self.net.send(conn, &Message::VideoDestroy { id });
                }
                s.misses = 0;
            }
        }
    }
}
