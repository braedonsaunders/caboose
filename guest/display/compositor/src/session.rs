//! The client session: handshake, the messages a client sends, and the per-tick
//! render → encode → send pipeline with its pacing.

use crate::encode::{align_up, Backend, CpuImage};
use crate::net::{ConnId, NetEvent};
use crate::render::{Canvas, Rendered};
use crate::state::State;
use crate::stream::{CopyJob, Done, Job, MotionJob, MotionStream};
use caboose_display_protocol::{self as proto, ByeReason, Codec, Message, Rect};
use smithay::backend::renderer::utils::with_renderer_surface_state;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// A connection must say hello within this long.
pub const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// A display that has not ticked for this long paces its windows at 1 Hz.
pub const VSYNC_STALE: Duration = Duration::from_secs(1);

pub struct Session {
    pub conn: ConnId,
    /// The handshake is complete and windows are announced.
    pub ready: bool,
    pub backend: Backend,
    pub last_vsync: HashMap<u32, Instant>,
    /// What the client plays as `video.*` streams.
    pub video_decoders: Vec<Codec>,
    /// The client plays Opus audio.
    pub audio: bool,
    /// The client runs games handed off to it, and this instance hands them off.
    pub wasm: bool,
    pub webview: bool,
    pub webview_grant: Option<String>,
    /// The client renders Vulkan streams, and this instance relays them.
    pub gpu: bool,
    pub scaled_motion: bool,
    /// The client applies `frame.copy`, and this server sends them.
    pub copy: bool,
    /// The client offers its hardware and this instance accepts it (docs/devices.md).
    pub devices: bool,
}

/// Features this server implements (docs/display.md, Handshake).
pub fn features(xwayland: bool, video: bool, audio: bool, tiles: bool, wasm: bool, gpu: bool) -> Vec<String> {
    let mut f = vec!["vsync", "ack", "touch", "pencil", "text-input-v3", "cursor-named", "clipboard"];
    if xwayland {
        f.push("xwayland");
    }
    if video {
        f.push("video");
    }
    if audio {
        f.push("audio");
    }
    if tiles {
        f.push("tiles");
    }
    if wasm {
        f.push("wasm");
    }
    if gpu {
        f.push("gpu");
    }
    f.into_iter().map(String::from).collect()
}

/// The process that owns a window and its ancestors: the Wayland client's pid, or an X11
/// window's _NET_WM_PID.
fn window_lineage(
    dh: &smithay::reexports::wayland_server::DisplayHandle,
    surface: &crate::windows::Surface,
) -> Vec<u32> {
    use smithay::reexports::wayland_server::Resource;
    let pid = match surface {
        crate::windows::Surface::X11(x) => x.pid(),
        s => s
            .wl_surface()
            .and_then(|w| dh.get_client(w.id()).ok())
            .and_then(|c| c.get_credentials(dh).ok())
            .map(|c| c.pid as u32),
    };
    pid.map(crate::video::lineage).unwrap_or_default()
}

/// A random identifier for this server process (16 hex characters). Window ids restart
/// with the process, so a client keeps a window's last picture across a reconnect only
/// when the epoch is unchanged. Without /dev/urandom, the clock and pid still differ
/// between runs.
pub fn new_epoch() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 8];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        bytes = (nanos ^ ((std::process::id() as u64) << 32)).to_le_bytes();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Constant-time comparison, so the token cannot be guessed byte by byte.
fn token_matches(expected: &[u8], given: &[u8]) -> bool {
    if expected.len() != given.len() {
        return false;
    }
    expected.iter().zip(given).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

/// The codec for a client: the server's preference order filtered by what the client
/// decodes.
pub fn choose_codec(server: &[Codec], client: &[Codec]) -> Option<Codec> {
    server.iter().copied().find(|c| client.contains(c))
}

/// The render scale of a window's root surface: buffer pixels per logical pixel,
/// clamped to [1, display scale]. A scale-1 buffer on a 3x display is streamed at its
/// own size and the client scales it, rather than encoding nine times the pixels.
fn surface_scale(surface: &WlSurface, display_scale: f64) -> f64 {
    let scale = with_renderer_surface_state(surface, |s| {
        let buffer = s.buffer_size()?;
        let logical = s.surface_size()?;
        (logical.w > 0).then(|| buffer.w as f64 * s.buffer_scale() as f64 / logical.w as f64)
    })
    .flatten()
    .unwrap_or(display_scale);
    (scale.clamp(1.0, display_scale.max(1.0)) * 100.0).round() / 100.0
}

impl State {
    pub fn on_net_event(&mut self, event: NetEvent) {
        match event {
            NetEvent::Message(conn, message) => self.on_client_message(conn, message),
            NetEvent::ProtocolError(conn, error) => {
                tracing::warn!("connection {conn}: {error}");
                self.net.close_with(conn, Some(&Message::Bye { reason: ByeReason::Protocol }));
            }
            NetEvent::Closed(conn) => {
                tracing::info!("connection {conn} closed");
                if self.session.as_ref().is_some_and(|s| s.conn == conn) {
                    self.end_session();
                }
            }
        }
    }

    fn end_session(&mut self) {
        if self.session.as_ref().is_some_and(|s| s.devices) {
            if let Some(hub) = &self.devices {
                hub.disconnected();
            }
        }
        self.video_session_ended();
        if let Some(a) = self.audio.as_mut() {
            a.stop_capture();
        }
        self.session = None;
        self.games_session_changed();
        self.generation += 1;
        self.release_input();
        for w in self.windows.iter_mut() {
            w.announced = None;
            w.stream.reset_for_client();
        }
    }

    fn is_current(&self, conn: ConnId) -> bool {
        self.session.as_ref().is_some_and(|s| s.conn == conn && s.ready)
    }

    fn on_client_message(&mut self, conn: ConnId, message: Message) {
        if let Message::ClientHello(hello) = message {
            self.on_hello(conn, hello);
            return;
        }
        if let Message::Ping { t_us } = message {
            self.net.send(conn, &Message::Pong { t_us });
            return;
        }
        if !self.is_current(conn) {
            // Before hello, or a replaced client still talking: nothing to act on.
            return;
        }
        if !matches!(message, Message::Vsync { .. } | Message::Ack { .. }) {
            tracing::debug!("connection {conn}: {message:?}");
        }
        match message {
            Message::Vsync { display, t_us: _ } => self.on_vsync(display),
            Message::Ack { id, pts_us, decoded_us } => {
                let now = self.now_us();
                if let Some(w) = self.windows.get_mut(id) {
                    if w.stream.ack(pts_us) {
                        tracing::trace!(
                            "window {id}: frame {pts_us} acked after {} µs (decode {decoded_us} µs)",
                            now.saturating_sub(pts_us)
                        );
                    }
                    if decoded_us < 0 {
                        w.stream.need_keyframe = true;
                        w.stream.dirty = true;
                        w.stream.new_base();
                    }
                }
            }
            Message::RequestKeyframe { id } => {
                if let Some(w) = self.windows.get_mut(id) {
                    w.stream.need_keyframe = true;
                    w.stream.dirty = true;
                    w.stream.new_base();
                }
            }
            Message::Configure(c) => self.configure_window(&c),
            Message::Close { id } => self.close_window(id),
            Message::GpuAck { id, offset } => self.gpu_ack(id, offset),
            Message::GameDecline { id, reason } => self.decline_game(id, &reason),
            Message::WebviewDecline { id, reason } => self.decline_webview(id, &reason),
            Message::Displays { displays } => self.set_displays(&displays),
            Message::Touch(t) => self.touch(&t),
            Message::Pointer(p) => self.pointer(&p),
            Message::Key(k) => self.key(&k),
            Message::Text(t) => self.text(&t),
            Message::VideoKeyframe { id } => {
                let motion = self.windows.iter_mut().find(|w| w.stream.motion.as_ref().is_some_and(|m| m.id == id));
                if let Some(w) = motion {
                    w.stream.motion.as_mut().unwrap().need_keyframe = true;
                    w.stream.dirty = true;
                } else {
                    self.video_keyframe(id);
                }
            }
            Message::VideoAck { id, seq } => {
                if !self.windows.iter_mut().any(|w| w.stream.ack_motion(id, seq)) {
                    tracing::trace!("video {id}: frame {seq} queued for display");
                }
            }
            Message::ClientClipboard(c) => self.clipboard_from_phone(c),
            Message::Pencil(p) => self.pencil(&p),
            Message::Devices { devices } => {
                if let (Some(hub), true) = (&self.devices, self.session.as_ref().is_some_and(|s| s.devices)) {
                    hub.offer(devices);
                }
            }
            m @ (Message::DeviceCamera(_)
            | Message::DeviceDepth(_)
            | Message::DeviceAudio(_)
            | Message::DeviceMotion(_)
            | Message::DeviceGamepad(_)
            | Message::DeviceButton { .. }
            | Message::DeviceBattery(_)
            | Message::DeviceError { .. }) => {
                if let (Some(hub), true) = (&self.devices, self.session.as_ref().is_some_and(|s| s.devices)) {
                    hub.phone(m);
                }
            }
            other => tracing::debug!("connection {conn}: ignoring {}", other.name()),
        }
    }

    fn on_hello(&mut self, conn: ConnId, hello: proto::ClientHello) {
        if let Some(path) = &self.config.token_file {
            let expected = std::fs::read(path).map(|t| t.trim_ascii().to_vec()).unwrap_or_default();
            if expected.is_empty() || !token_matches(&expected, hello.token.as_bytes()) {
                tracing::warn!("connection {conn}: bad token");
                self.net.close_with(conn, Some(&Message::Bye { reason: ByeReason::Auth }));
                return;
            }
        }
        if hello.version != proto::VERSION {
            self.net.close_with(conn, Some(&Message::Bye { reason: ByeReason::Version }));
            return;
        }
        let offered = self.encoders.codecs();
        let Some(codec) = choose_codec(&offered, &hello.decoders) else {
            tracing::warn!("connection {conn}: no common codec (server {offered:?}, client {:?})", hello.decoders);
            self.net.close_with(conn, Some(&Message::Bye { reason: ByeReason::Protocol }));
            return;
        };
        let backend = self.encoders.backend_for(codec).unwrap().clone();
        // One client at a time: the newest wins.
        if let Some(old) = self.session.take() {
            tracing::info!("connection {conn} replaces {}", old.conn);
            self.net.close_with(old.conn, Some(&Message::Bye { reason: ByeReason::Replaced }));
            self.session = Some(old);
            self.end_session();
        }
        self.generation += 1;
        self.set_displays(&hello.displays);
        let encoders: Vec<Codec> = offered.into_iter().filter(|c| hello.decoders.contains(c)).collect();
        let wasm = hello.wasm && self.games.socket.is_some();
        let gpu = hello.gpu && self.games.socket.is_some();
        let webview_grant = if hello.webview && self.games.socket.is_some() {
            use std::io::Read;
            let mut bytes = [0u8; 16];
            std::fs::File::open("/dev/urandom")
                .and_then(|mut file| file.read_exact(&mut bytes))
                .ok()
                .map(|_| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>())
        } else {
            None
        };
        let webview = webview_grant.is_some();
        // Copies come from the software encoders' record of what the client shows.
        let copy = hello.copy && self.config.copy && matches!(backend, Backend::Software(_));
        let devices = hello.devices && self.devices.is_some();
        self.net.send(
            conn,
            &Message::ServerHello(proto::ServerHello {
                version: proto::VERSION,
                displays: self.displays.ids(),
                encoders,
                features: {
                    let mut supported = features(
                        self.xwm.is_some() || self.config.x_display.is_some(),
                        ((self.videos.socket.is_some() || self.config.motion)
                            && hello.video_decoders.as_ref().is_some_and(|d| !d.is_empty()))
                            || (self.config.motion && hello.scaled_motion),
                        self.audio.is_some(),
                        self.encoders.settings.tile_max_px > 0,
                        wasm,
                        gpu,
                    );
                    if webview {
                        supported.push("webview".into());
                    }
                    if copy {
                        supported.push("copy".into());
                    }
                    if devices {
                        supported.push("devices".into());
                    }
                    supported
                },
                epoch: Some(self.epoch.clone()),
            }),
        );
        tracing::info!("connection {conn}: session started, {} via {}", codec.as_str(), backend.describe());
        let video_decoders = hello.video_decoders.clone().unwrap_or_default();
        let audio = hello.audio_decoders.as_ref().is_some_and(|d| d.iter().any(|c| c == "opus"));
        self.session = Some(Session {
            conn,
            ready: true,
            backend,
            last_vsync: HashMap::new(),
            video_decoders,
            audio,
            wasm,
            webview,
            webview_grant,
            gpu,
            scaled_motion: hello.scaled_motion,
            copy,
            devices,
        });
        self.games_session_changed();
        if audio {
            let (tx, bitrate) = (self.audio_tx.clone(), self.config.audio_bitrate);
            if let Some(a) = self.audio.as_mut() {
                a.start_capture(tx, bitrate);
            }
        }
        for w in self.windows.iter_mut() {
            w.announced = None;
            w.stream.reset_for_client();
        }
        self.sync_windows();
        if let Some(cursor) = self.cursor.clone() {
            self.net.send(conn, &cursor);
        }
        self.video_session_started();
        // What the computer's clipboard holds, so the phone can paste it.
        if let Some(text) = self.clipboard.last_sent.clone() {
            let message = Message::ServerClipboard(proto::Clipboard {
                mime: crate::clipboard::MIME.into(),
                data: (*text).clone(),
            });
            self.net.send(conn, &message);
        }
        // Text input enabled before this client connected still needs the keyboard; the
        // toggle itself went to no one (or to the previous client).
        if let Some(surface) = self.keyboard_focus_surface() {
            if let (Some(purpose), Some(id)) =
                (self.text_inputs.enabled_purpose(&surface), self.window_of_surface(&surface))
            {
                if self.windows.get(id).is_some_and(|w| w.announced.is_some()) {
                    let state = proto::TextInputState {
                        id,
                        enabled: true,
                        purpose: purpose.map(str::to_owned),
                        surrounding: self.text_inputs.surrounding(&surface),
                    };
                    self.net.send(conn, &Message::TextInput(state));
                }
            }
        }
    }

    pub fn set_displays(&mut self, displays: &[proto::Display]) {
        let change = self.displays.replace(&self.dh, displays);
        let fallback = self.displays.primary().info.id;
        let ids = self.windows.ids();
        let mut resized = Vec::new();
        for id in &ids {
            if let Some(w) = self.windows.get_mut(*id) {
                if (w.fullscreen || w.maximized)
                    && (change.changed.contains(&w.display) || change.removed.contains(&w.display))
                {
                    resized.push(*id);
                }
                if change.removed.contains(&w.display) {
                    w.display = fallback;
                }
            }
        }
        for id in ids {
            self.assign_output(id);
            // Output modes and origins can change without replacing their ids. Keep
            // monitor-owned windows on the new output rectangle, through the same
            // native/X11 configure path as an application's fullscreen request.
            // A removed output was remapped above, so it needs the same treatment.
            if resized.contains(&id) {
                self.configure_window(&proto::Configure { id, ..Default::default() });
            }
        }
        // sync_windows (next tick) sends the resulting window.update messages.
    }

    fn on_vsync(&mut self, display: u32) {
        if let Some(s) = self.session.as_mut() {
            s.last_vsync.insert(display, Instant::now());
        }
        let ids: Vec<u64> = self
            .windows
            .iter()
            .filter(|w| w.display == display && w.stream.callbacks_pending && w.stream.can_release_callbacks())
            .map(|w| w.id)
            .collect();
        for id in ids {
            self.release_frame_callbacks(id);
        }
    }

    /// Once a second: frame callbacks for windows nothing paces, and connection upkeep.
    pub fn slow_tick(&mut self) {
        let stale: Vec<u64> = self
            .windows
            .iter()
            .filter(|w| {
                let paced = self
                    .session
                    .as_ref()
                    .and_then(|s| s.last_vsync.get(&w.display))
                    .is_some_and(|t| t.elapsed() < VSYNC_STALE);
                !paced && w.stream.callbacks_pending && w.stream.can_release_callbacks()
            })
            .map(|w| w.id)
            .collect();
        for id in stale {
            self.release_frame_callbacks(id);
        }
        self.motion_tick();
        let session_conn = self.session.as_ref().map(|s| s.conn);
        let timeout = self.config.client_timeout;
        if let Some(conn) =
            session_conn.filter(|c| timeout.is_some_and(|t| self.net.silent_for(*c).is_some_and(|s| s > t)))
        {
            // A suspended or vanished client keeps its TCP connection; it would hold the
            // display and queue everything sent to it.
            tracing::info!("connection {conn}: client silent for over {:?}, closing", timeout.unwrap());
            self.net.close_with(conn, None);
        }
        for conn in self.net.ids() {
            if Some(conn) != session_conn && self.net.age(conn).is_some_and(|a| a > HELLO_TIMEOUT) {
                tracing::info!("connection {conn}: no hello, closing");
                self.net.close_with(conn, None);
            }
        }
        for conn in self.net.stale_closing(Duration::from_secs(3)) {
            if let Some(token) = self.net.drop_conn(conn) {
                self.handle.remove(token);
            }
            self.on_net_event(NetEvent::Closed(conn));
        }
    }

    /// Renders every window that changed and can send, and hands the picture to its
    /// encoder.
    pub fn render_streams(&mut self) {
        let Some(session) = self.session.as_ref().filter(|s| s.ready) else { return };
        let backend = session.backend.clone();
        let copies = session.copy;
        let generation = self.generation;
        let align = backend.alignment();
        let now_us = self.now_us();
        for id in self.windows.ids() {
            if self.game_shown(id) {
                continue; // the client runs the window's game; there is nothing to show
            }
            let Some(w) = self.windows.get(id) else { continue };
            if let Some(a) = w.announced.as_ref().filter(|_| w.stream.refine_due(now_us) && !w.stream.need_keyframe) {
                let rect = Rect::new(0, 0, a.geometry.w, a.geometry.h);
                let w = self.windows.get_mut(id).unwrap();
                let image = w.stream.image.take().unwrap();
                let job = Job {
                    window: id,
                    generation,
                    pts_us: w.stream.refine_pts(now_us),
                    image,
                    shm: None,
                    detect: false,
                    alpha: w.kind == proto::WindowKind::Popup,
                    keyframe: false,
                    refine: true,
                    damage: None,
                    rect,
                    crop: w.stream.crop,
                    backend: backend.clone(),
                    settings: self.encoders.settings.clone(),
                    motion: None,
                    ends_motion: None,
                    base: w.stream.base,
                    copy: None,
                };
                w.stream.submit(job, &self.done_tx);
                continue;
            }
            if w.announced.is_none() || !w.stream.dirty || !w.stream.can_send() {
                continue;
            }
            let Some(root) = w.surface.wl_surface() else { continue };
            let display = self.displays.resolve(Some(w.display));
            let display_scale = display.info.scale;
            let local = w.local_geometry();
            if local.size.w <= 0 || local.size.h <= 0 {
                continue;
            }
            let scale = if w.surface.is_x11() { 1.0 } else { surface_scale(&root, display_scale) };
            let pic_w = (local.size.w as f64 * scale).round().max(1.0) as i32;
            let pic_h = (local.size.h as f64 * scale).round().max(1.0) as i32;
            let rect = w.announced.as_ref().map(|a| Rect::new(0, 0, a.geometry.w, a.geometry.h)).unwrap();
            let size = (pic_w, pic_h).into();
            // A popup keeps its alpha (window.create `alpha`): composed over transparent
            // and sent as RGBA tiles, with no motion stream or marker detection.
            let alpha = w.kind == proto::WindowKind::Popup;
            let w = self.windows.get_mut(id).unwrap();
            if !w.stream.canvas.as_ref().is_some_and(|c| c.matches(size, scale, alpha)) {
                w.stream.canvas = Some(Canvas::new(size, scale, alpha));
                w.stream.need_keyframe = true;
                w.stream.new_base();
                // The keyframe repaints everything; a motion region is found afresh.
                w.stream.tracker = None;
                w.stream.end_motion();
            }
            if w.stream.rect != rect || w.stream.crop != Rect::new(0, 0, pic_w, pic_h) {
                w.stream.end_motion();
                w.stream.tracker = None;
                w.stream.new_base();
            }
            // A motion stream that ends: this picture puts its region back.
            let ending = w.stream.motion.as_ref().filter(|m| m.ending).map(|m| (m.id, m.rect));
            let (coded_w, coded_h) = (align_up(pic_w as u32, align), align_up(pic_h as u32, align));
            let (mut image, image_id) = w.stream.take_image(coded_w, coded_h);
            let mut canvas = w.stream.canvas.take().unwrap();
            let started = Instant::now();
            // A window that is one shm buffer is streamed from it: read in place by the
            // encoder when the picture needs no padding, otherwise copied (damage only).
            // Not a window with alpha: an XRGB buffer's alpha byte is anything.
            let in_place = coded_w == pic_w as u32 && coded_h == pic_h as u32;
            let key = if in_place { crate::render::SHM_IN_PLACE } else { image_id };
            let since = w.stream.direct.filter(|d| d.image_id == key).map(|d| d.commit);
            let direct = if self.config.always_compose || alpha {
                None
            } else {
                crate::render::direct(&root, local, size, since)
            };
            let mut shm = None;
            let rendered = match direct {
                Some(d) => {
                    self.stats.direct += 1;
                    w.stream.direct = Some(crate::render::DirectState { image_id: key, commit: d.commit });
                    let result = if in_place { Ok(()) } else { crate::render::copy_direct(&d, &mut image) };
                    match result {
                        Ok(()) => {
                            // In place the picture is the buffer itself; the image is not
                            // kept up to date, so a keyframe of unchanged content (a new
                            // client) must read the buffer too.
                            if in_place && (!d.damage.is_empty() || w.stream.need_keyframe || ending.is_some()) {
                                shm =
                                    Some(crate::encode::ShmPicture { buffer: d.buffer, x: d.origin.0, y: d.origin.1 });
                            }
                            if d.damage.is_empty() {
                                Ok(Rendered::Unchanged)
                            } else {
                                Ok(Rendered::Picture(d.damage))
                            }
                        }
                        Err(e) => {
                            w.stream.direct = None;
                            Err(e)
                        }
                    }
                }
                None => {
                    if w.stream.direct.take().is_some() {
                        // The image was written behind the damage tracker's back.
                        canvas.invalidate();
                    }
                    canvas.render(&mut self.renderer, &root, local.loc, &mut image, image_id)
                }
            };
            self.stats.render_us += started.elapsed().as_micros() as u64;
            let w = self.windows.get_mut(id).unwrap();
            w.stream.canvas = Some(canvas);
            self.stats.renders += 1;
            match rendered {
                Err(e) => {
                    tracing::warn!("window {id}: render failed: {e}");
                    w.stream.return_image(image);
                    w.stream.dirty = false;
                }
                Ok(Rendered::Unchanged) if !w.stream.need_keyframe && ending.is_none() => {
                    self.stats.unchanged_renders += 1;
                    w.stream.return_image(image);
                    w.stream.dirty = false;
                }
                Ok(rendered) => {
                    let mut damage = match rendered {
                        // A new image (or a resize) has nothing to be partial against.
                        Rendered::Picture(d) if !w.stream.need_keyframe => {
                            pad_edges(&mut image, pic_w as u32, pic_h as u32, Some(&d));
                            Some(d)
                        }
                        Rendered::Unchanged if !w.stream.need_keyframe => Some(Vec::new()),
                        _ => {
                            pad_edges(&mut image, pic_w as u32, pic_h as u32, None);
                            None
                        }
                    };
                    if let (Some((_, region)), Some(d)) = (ending, damage.as_mut()) {
                        d.push(region);
                    }
                    let picture = pic_w as u64 * pic_h as u64;
                    self.stats.picture_px += picture;
                    self.stats.damaged_px += damage
                        .as_ref()
                        .map(|d| d.iter().map(|r| r.w.max(0) as u64 * r.h.max(0) as u64).sum::<u64>().min(picture))
                        .unwrap_or(picture);
                    let pts_us = w.stream.next_pts();
                    if w.stream.need_keyframe {
                        w.stream.new_base();
                    }
                    // A scroll can be a copy within the client's picture when the client shows
                    // what the encoder last had, at the picture's own size (a copy in a
                    // scaled picture would not land on whole pixels).
                    let copy = (!alpha
                        && copies
                        && ending.is_none()
                        && (pic_w, pic_h) == (rect.w, rect.h)
                        && w.stream.copy_ready()
                        && w.stream.scrolling(now_us))
                    .then(|| {
                        let per_window_px = (pic_w as f64 / rect.w as f64, pic_h as f64 / rect.h as f64);
                        CopyJob { hints: w.stream.scroll_hints(now_us, per_window_px) }
                    });
                    let detect = !alpha
                        && !self.videos.streams.by_id.is_empty()
                        && self
                            .videos
                            .streams
                            .wants_detection(w.lineage.get_or_insert_with(|| window_lineage(&self.dh, &w.surface)));
                    let job = Job {
                        window: id,
                        generation,
                        pts_us,
                        image,
                        shm,
                        detect,
                        alpha,
                        keyframe: w.stream.need_keyframe,
                        refine: false,
                        damage,
                        rect,
                        crop: Rect::new(0, 0, pic_w, pic_h),
                        backend: backend.clone(),
                        settings: self.encoders.settings.clone(),
                        motion: w.stream.motion.as_ref().filter(|m| !m.ending).map(|m| MotionJob {
                            id: m.id,
                            rect: m.rect,
                            keyframe: m.need_keyframe,
                            scaled: m.scaled,
                        }),
                        ends_motion: ending.map(|(id, _)| id),
                        base: w.stream.base,
                        copy,
                    };
                    w.stream.submit(job, &self.done_tx);
                }
            }
        }
        // Wake up for the next window that will have something to sharpen.
        if let Some(next) = self.windows.iter().filter_map(|w| w.stream.refine_at_us).filter(|t| *t > now_us).min() {
            self.arm_refine_timer(next);
        }
    }

    /// Makes sure the loop wakes up by `at_us` (monotonic), when a window's quiet areas
    /// are due; render_streams then sends them.
    fn arm_refine_timer(&mut self, at_us: u64) {
        if self.refine_timer.is_some_and(|(t, _)| t <= at_us) {
            return;
        }
        if let Some((_, token)) = self.refine_timer.take() {
            self.handle.remove(token);
        }
        let delay = Duration::from_micros(at_us.saturating_sub(self.now_us()));
        let timer = Timer::from_duration(delay);
        match self.handle.insert_source(timer, |_, _, state: &mut State| {
            state.refine_timer = None;
            TimeoutAction::Drop
        }) {
            Ok(token) => self.refine_timer = Some((at_us, token)),
            Err(e) => tracing::warn!("refinement timer: {e}"),
        }
    }

    /// Sound from the computer, for a client that plays it.
    pub fn on_audio_packet(&mut self, packet: crate::audio::Packet) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready && s.audio).map(|s| s.conn) else { return };
        let message = Message::Audio(proto::Audio {
            codec: "opus".into(),
            pts_us: packet.pts_us,
            channels: Some(crate::audio::CHANNELS),
            data: packet.data,
        });
        self.net.send(conn, &message);
    }

    /// A device message for the phone (docs/devices.md). The hub speaks for the session it
    /// was offered by; one from before a reconnect is answered again by the next offer.
    pub fn on_device_message(&mut self, message: Message) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready && s.devices).map(|s| s.conn) else { return };
        self.net.send(conn, &message);
    }

    /// An encoder finished a picture.
    pub fn on_encoded(&mut self, done: Done) {
        let now_us = self.now_us();
        let Some(w) = self.windows.get_mut(done.window) else { return };
        if done.generation != self.generation {
            // For a client that has gone. The stream has moved on (and may have a new
            // image whose damage history this one would break), so the image is dropped.
            return;
        }
        w.stream.return_image(done.image);
        w.stream.encoding = false;
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        let mut refined = false;
        let mut frame_sent = false;
        match done.result {
            None => {}
            // The relay carries at most 16 MiB per message; a picture that does not fit
            // is dropped (the CBOR header needs a few dozen bytes of the budget).
            Some(Ok(encoded)) if encoded.data.len() > proto::MAX_PAYLOAD - 256 => {
                tracing::warn!(
                    "window {}: {} byte picture exceeds the message limit; dropped",
                    done.window,
                    encoded.data.len()
                );
                w.stream.need_keyframe = true;
                w.stream.dirty = true;
                w.stream.new_base();
            }
            Some(Ok(encoded)) => {
                refined = encoded.refined;
                w.stream.in_flight.push_back(done.pts_us);
                w.stream.refine_at_us = encoded.refine_in_ms.map(|ms| now_us + ms * 1000);
                self.stats.frames += 1;
                self.stats.refines += encoded.refined as u64;
                self.stats.bytes += encoded.data.len() as u64;
                self.stats.encode_cpu_us += encoded.cpu_us;
                tracing::trace!(
                    "window {}: {} bytes {} in {} µs ({} µs CPU)",
                    done.window,
                    encoded.data.len(),
                    if encoded.keyframe {
                        "key"
                    } else if encoded.refined {
                        "sharpening"
                    } else {
                        "delta"
                    },
                    encoded.encode_us,
                    encoded.cpu_us
                );
                let message = Message::Frame(proto::Frame {
                    id: done.window,
                    codec: encoded.codec,
                    keyframe: encoded.keyframe,
                    pts_us: done.pts_us,
                    rect: done.rect,
                    crop: done.crop,
                    data: encoded.data,
                });
                self.net.send(conn, &message);
                frame_sent = true;
                w.stream.shown(done.base);
            }
            Some(Err(e)) => {
                tracing::warn!("window {}: encode failed: {e}", done.window);
                w.stream.need_keyframe = true;
                w.stream.new_base();
            }
        }
        if let Some(c) = done.copy {
            // The copy, then at once the tiles that complete it: together they turn what
            // the client shows into the window's new content.
            w.stream.refine_at_us = c.refine_in_ms.map(|ms| now_us + ms * 1000);
            self.stats.copies += 1;
            self.stats.tiles += c.tiles.len() as u64;
            self.stats.encode_cpu_us += c.cpu_us;
            tracing::trace!("window {}: copy {:?} to {:?}, {} tiles", done.window, c.src, c.dst, c.tiles.len());
            self.net.send(conn, &Message::FrameCopy(proto::FrameCopy { id: done.window, src: c.src, dst: c.dst }));
            for (rect, data) in c.tiles {
                self.stats.bytes += data.len() as u64;
                let tile = proto::Tile { id: done.window, rect, format: proto::TileFormat::Png, data };
                self.net.send(conn, &Message::Tile(tile));
            }
            w.stream.copying = true;
        } else if !refined && (frame_sent || done.tiles.is_some()) {
            w.stream.copying = false;
        }
        if let Some(t) = done.tiles {
            w.stream.refine_at_us = t.refine_in_ms.map(|ms| now_us + ms * 1000);
            self.stats.tiles += t.tiles.len() as u64;
            self.stats.tile_pictures += 1;
            self.stats.encode_cpu_us += t.cpu_us;
            for (rect, data) in t.tiles {
                self.stats.bytes += data.len() as u64;
                let tile = proto::Tile { id: done.window, rect, format: proto::TileFormat::Png, data };
                self.net.send(conn, &Message::Tile(tile));
            }
        }
        match (done.motion, w.stream.motion.as_mut()) {
            (Some((id, Ok(encoded))), Some(m)) if m.id == id && encoded.data.len() <= proto::MAX_PAYLOAD - 256 => {
                let seq = m.next_seq;
                m.next_seq += 1;
                m.in_flight.push_back(seq);
                self.stats.motion_frames += 1;
                self.stats.bytes += encoded.data.len() as u64;
                self.stats.encode_cpu_us += encoded.cpu_us;
                tracing::trace!(
                    "motion {id}: {} bytes {} in {} µs ({} µs CPU)",
                    encoded.data.len(),
                    if encoded.keyframe { "key" } else { "delta" },
                    encoded.encode_us,
                    encoded.cpu_us
                );
                let message = Message::VideoFrame(proto::VideoFrame {
                    id,
                    seq,
                    keyframe: encoded.keyframe,
                    pts_us: Some(done.pts_us),
                    data: encoded.data,
                });
                self.net.send(conn, &message);
            }
            (Some((id, result)), Some(m)) if m.id == id => {
                if let Err(e) = result {
                    tracing::warn!("motion {id}: encode failed: {e}");
                } else {
                    tracing::warn!("motion {id}: picture exceeds the message limit; dropped");
                }
                m.need_keyframe = true;
                w.stream.dirty = true;
            }
            _ => {}
        }
        if let Some(id) = done.ends_motion {
            // After the window picture that repaints its region.
            if w.stream.motion_repainted(id, frame_sent) {
                self.net.send(conn, &Message::VideoDestroy { id });
                tracing::debug!("window {}: motion stream {id} ended", done.window);
            }
        }
        if let Some(hits) = &done.hits {
            self.on_video_hits(done.window, hits, done.rect, done.crop, done.pts_us);
        }
        if !refined {
            self.watch_motion(done.window, &done.changed, done.rect, done.crop, now_us / 1000);
        }
    }

    /// Whether this window's motion can be its own video stream for the client.
    fn motion_possible(&self, window: u64) -> bool {
        let Some(session) = self.session.as_ref().filter(|s| s.ready) else { return false };
        self.config.motion
            && self.windows.get(window).is_some_and(|w| w.kind != proto::WindowKind::Popup)
            && (session.scaled_motion || session.video_decoders.contains(&session.backend.codec()))
            && !self.videos.streams.by_id.values().any(|s| s.binding.as_ref().is_some_and(|b| b.window == window))
    }

    /// Feeds a window's changes to its motion tracker, and starts or ends its motion
    /// stream on what it decides.
    fn watch_motion(&mut self, window: u64, changed: &[Rect], rect: Rect, crop: Rect, now_ms: u64) {
        if !self.motion_possible(window) {
            if let Some(w) = self.windows.get_mut(window) {
                w.stream.end_motion();
                w.stream.tracker = None;
            }
            return;
        }
        let Some(conn) = self.session.as_ref().map(|s| s.conn) else { return };
        let codec = self.session.as_ref().map(|s| s.backend.codec()).unwrap();
        let scaled_motion =
            self.session.as_ref().is_some_and(|s| s.scaled_motion && matches!(s.backend, Backend::Software(_)));
        let Some(w) = self.windows.get_mut(window) else { return };
        let Some(image) = w.stream.image.as_ref() else { return };
        let size = (image.width, image.height);
        if w.stream.tracker.as_ref().is_none_or(|t| t.detector.size() != size) {
            w.stream.tracker = Some(crate::motion::Tracker::new(size.0, size.1));
        }
        let tracker = w.stream.tracker.as_mut().unwrap();
        if !changed.is_empty() {
            tracker.detector.picture(changed, now_ms);
        }
        match tracker.update(now_ms) {
            Some(crate::motion::Change::Start(region)) if w.stream.motion.is_none() => {
                let id = self.videos.streams.allocate_id();
                let (video_rect, clip) = motion_to_window(region, rect, crop);
                let scaled = scaled_motion && region.w % 4 == 0 && region.h % 4 == 0;
                tracing::info!("window {window}: motion stream {id} for {region:?} (picture pixels)");
                self.net.send(
                    conn,
                    &Message::VideoCreate(proto::VideoCreate {
                        id,
                        window,
                        rect: video_rect,
                        clip,
                        z: None,
                        codec,
                        source: proto::VideoSource::Motion,
                        color: None,
                        extradata: None,
                        scaled,
                    }),
                );
                w.stream.new_base();
                w.stream.motion = Some(MotionStream {
                    id,
                    rect: region,
                    next_seq: 0,
                    in_flight: Default::default(),
                    need_keyframe: true,
                    ending: false,
                    scaled,
                });
            }
            Some(crate::motion::Change::Stop) => {
                w.stream.end_motion();
            }
            _ => {}
        }
    }

    /// Ends motion streams whose video has stopped arriving (paused, closed): their
    /// windows send no pictures that would let the tracker notice.
    pub fn motion_tick(&mut self) {
        let now_ms = self.now_us() / 1000;
        let ids: Vec<u64> = self.windows.iter().filter(|w| w.stream.motion.is_some()).map(|w| w.id).collect();
        for id in ids {
            let (rect, crop) = match self.windows.get(id) {
                Some(w) => (w.announced.as_ref().map(|a| a.geometry).unwrap_or_default(), w.stream.crop),
                None => continue,
            };
            self.watch_motion(id, &[], Rect::new(0, 0, rect.w, rect.h), crop, now_ms);
        }
    }
}

/// A motion region (picture pixels) in window coordinates, and its visible part when
/// it reaches into the picture's padding.
fn motion_to_window(region: Rect, rect: Rect, crop: Rect) -> (Rect, Option<Rect>) {
    let (sx, sy) = (rect.w as f64 / crop.w.max(1) as f64, rect.h as f64 / crop.h.max(1) as f64);
    let scale = |r: Rect| {
        let x0 = (r.x as f64 * sx).round() as i32;
        let y0 = (r.y as f64 * sy).round() as i32;
        let x1 = ((r.x + r.w) as f64 * sx).round() as i32;
        let y1 = ((r.y + r.h) as f64 * sy).round() as i32;
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    };
    let whole = scale(region);
    let visible = crate::motion::intersect(region, crop).map(scale).unwrap_or(whole);
    (whole, (visible != whole).then_some(visible))
}

/// Repeats the picture's last column and row into the encoder's padding, so the
/// padding compresses to nothing and never bleeds into the visible edge. With damage,
/// only when the damage reaches the edge.
fn pad_edges(image: &mut CpuImage, w: u32, h: u32, damage: Option<&[Rect]>) {
    let stride = image.stride;
    let reaches = |right: bool| {
        damage.is_none_or(|d| d.iter().any(|r| if right { r.x + r.w >= w as i32 } else { r.y + r.h >= h as i32 }))
    };
    if w < image.width && reaches(true) {
        for y in 0..h as usize {
            let row = y * stride;
            let last = row + (w as usize - 1) * 4;
            let px: [u8; 4] = image.data[last..last + 4].try_into().unwrap();
            for x in w as usize..image.width as usize {
                image.data[row + x * 4..row + x * 4 + 4].copy_from_slice(&px);
            }
        }
    }
    if h < image.height && reaches(false) {
        let last = (h as usize - 1) * stride;
        let row: Vec<u8> = image.data[last..last + stride].to_vec();
        for y in h as usize..image.height as usize {
            image.data[y * stride..(y + 1) * stride].copy_from_slice(&row);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_server_preference_decides_among_common_codecs() {
        assert_eq!(choose_codec(&[Codec::H264, Codec::Hevc], &[Codec::Hevc, Codec::H264]), Some(Codec::H264));
        assert_eq!(choose_codec(&[Codec::Hevc], &[Codec::Av1, Codec::Hevc]), Some(Codec::Hevc));
        assert_eq!(choose_codec(&[Codec::Hevc], &[Codec::H264]), None);
    }

    #[test]
    fn tokens_compare_exactly() {
        assert!(token_matches(b"abc", b"abc"));
        assert!(!token_matches(b"abc", b"abd"));
        assert!(!token_matches(b"abc", b"ab"));
    }

    #[test]
    fn padding_repeats_the_edge() {
        let mut image = CpuImage::new(4, 2);
        // 3x1 content: pixels 1, 2, 3.
        for x in 0..3 {
            image.data[x * 4] = (x + 1) as u8;
        }
        pad_edges(&mut image, 3, 1, None);
        assert_eq!(image.data[3 * 4], 3);
        assert_eq!(&image.data[16..32], &image.data[0..16]);
    }

    #[test]
    fn epochs_are_hex_and_differ() {
        let (a, b) = (new_epoch(), new_epoch());
        assert_eq!(a.len(), 16);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(a, b);
    }

    #[test]
    fn features_name_xwayland_only_when_running() {
        assert!(!features(false, false, false, false, false, false).contains(&"xwayland".to_string()));
        assert!(features(true, false, false, false, false, false).contains(&"xwayland".to_string()));
        assert!(features(false, true, false, false, false, false).contains(&"video".to_string()));
        assert!(features(false, false, true, false, false, false).contains(&"audio".to_string()));
        assert!(features(false, false, false, true, false, false).contains(&"tiles".to_string()));
        assert!(features(false, false, false, false, true, false).contains(&"wasm".to_string()));
        assert!(!features(true, true, true, true, false, false).contains(&"wasm".to_string()));
        assert!(features(false, false, false, false, false, true).contains(&"gpu".to_string()));
    }
}
