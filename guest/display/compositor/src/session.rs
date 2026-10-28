//! The client session: handshake, the messages a client sends, and the per-tick
//! render → encode → send pipeline with its pacing.

use crate::encode::{align_up, Backend, CpuImage};
use crate::net::{ConnId, NetEvent};
use crate::render::{Canvas, Rendered};
use crate::state::State;
use crate::stream::{Done, Job};
use caboose_display_protocol::{self as proto, ByeReason, Codec, Message, Rect};
use smithay::backend::renderer::utils::with_renderer_surface_state;
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
}

/// Features this server implements (docs/display.md, Handshake).
pub fn features(xwayland: bool) -> Vec<String> {
    let mut f = vec!["vsync", "ack", "touch", "text-input-v3", "cursor-named"];
    if xwayland {
        f.push("xwayland");
    }
    f.into_iter().map(String::from).collect()
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
        self.session = None;
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
                    }
                }
            }
            Message::RequestKeyframe { id } => {
                if let Some(w) = self.windows.get_mut(id) {
                    w.stream.need_keyframe = true;
                    w.stream.dirty = true;
                }
            }
            Message::Configure(c) => self.configure_window(&c),
            Message::Close { id } => self.close_window(id),
            Message::Displays { displays } => self.set_displays(&displays),
            Message::Touch(t) => self.touch(&t),
            Message::Pointer(p) => self.pointer(&p),
            Message::Key(k) => self.key(&k),
            Message::Text(t) => self.text(&t),
            Message::Pencil(_) | Message::ClientClipboard(_) => {
                // Not implemented yet; the features are absent from hello.
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
            self.net.close_with(old.conn, Some(&Message::Bye { reason: ByeReason::Shutdown }));
            self.session = Some(old);
            self.end_session();
        }
        self.generation += 1;
        self.set_displays(&hello.displays);
        let encoders: Vec<Codec> = offered.into_iter().filter(|c| hello.decoders.contains(c)).collect();
        self.net.send(
            conn,
            &Message::ServerHello(proto::ServerHello {
                version: proto::VERSION,
                displays: self.displays.ids(),
                encoders,
                features: features(self.xwm.is_some() || self.config.x_display.is_some()),
            }),
        );
        tracing::info!("connection {conn}: session started, {} via {}", codec.as_str(), backend.describe());
        self.session = Some(Session { conn, ready: true, backend, last_vsync: HashMap::new() });
        for w in self.windows.iter_mut() {
            w.announced = None;
            w.stream.reset_for_client();
        }
        self.sync_windows();
        if let Some(cursor) = self.cursor.clone() {
            self.net.send(conn, &cursor);
        }
    }

    pub fn set_displays(&mut self, displays: &[proto::Display]) {
        let change = self.displays.replace(&self.dh, displays);
        let fallback = self.displays.primary().info.id;
        let ids = self.windows.ids();
        for id in &ids {
            if let Some(w) = self.windows.get_mut(*id) {
                if change.removed.contains(&w.display) {
                    w.display = fallback;
                }
            }
        }
        for id in ids {
            self.assign_output(id);
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
        let session_conn = self.session.as_ref().map(|s| s.conn);
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
        let generation = self.generation;
        let align = backend.alignment();
        for id in self.windows.ids() {
            let Some(w) = self.windows.get(id) else { continue };
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
            let w = self.windows.get_mut(id).unwrap();
            if !w.stream.canvas.as_ref().is_some_and(|c| c.matches(size, scale)) {
                w.stream.canvas = Some(Canvas::new(size, scale));
                w.stream.need_keyframe = true;
            }
            let (coded_w, coded_h) = (align_up(pic_w as u32, align), align_up(pic_h as u32, align));
            let (mut image, image_id) = w.stream.take_image(coded_w, coded_h);
            let mut canvas = w.stream.canvas.take().unwrap();
            let started = Instant::now();
            let rendered = canvas.render(&mut self.renderer, &root, local.loc, &mut image, image_id);
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
                Ok(Rendered::Unchanged) if !w.stream.need_keyframe => {
                    self.stats.unchanged_renders += 1;
                    w.stream.return_image(image);
                    w.stream.dirty = false;
                }
                Ok(rendered) => {
                    let damage = match rendered {
                        // A new image (or a resize) has nothing to be partial against.
                        Rendered::Picture(d) if !w.stream.need_keyframe => {
                            pad_edges(&mut image, pic_w as u32, pic_h as u32, Some(&d));
                            Some(d)
                        }
                        _ => {
                            pad_edges(&mut image, pic_w as u32, pic_h as u32, None);
                            None
                        }
                    };
                    let picture = pic_w as u64 * pic_h as u64;
                    self.stats.picture_px += picture;
                    self.stats.damaged_px += damage
                        .as_ref()
                        .map(|d| d.iter().map(|r| r.w.max(0) as u64 * r.h.max(0) as u64).sum::<u64>().min(picture))
                        .unwrap_or(picture);
                    let pts_us = w.stream.next_pts();
                    let job = Job {
                        window: id,
                        generation,
                        pts_us,
                        image,
                        keyframe: w.stream.need_keyframe,
                        damage,
                        rect,
                        crop: Rect::new(0, 0, pic_w, pic_h),
                        backend: backend.clone(),
                        settings: self.encoders.settings.clone(),
                    };
                    w.stream.submit(job, &self.done_tx);
                }
            }
        }
    }

    /// An encoder finished a picture.
    pub fn on_encoded(&mut self, done: Done) {
        let Some(w) = self.windows.get_mut(done.window) else { return };
        if done.generation != self.generation {
            // For a client that has gone. The stream has moved on (and may have a new
            // image whose damage history this one would break), so the image is dropped.
            return;
        }
        w.stream.return_image(done.image);
        w.stream.encoding = false;
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        match done.result {
            // The relay carries at most 16 MiB per message; a picture that does not fit
            // is dropped (the CBOR header needs a few dozen bytes of the budget).
            Ok(encoded) if encoded.data.len() > proto::MAX_PAYLOAD - 256 => {
                tracing::warn!(
                    "window {}: {} byte picture exceeds the message limit; dropped",
                    done.window,
                    encoded.data.len()
                );
                w.stream.need_keyframe = true;
                w.stream.dirty = true;
            }
            Ok(encoded) => {
                w.stream.in_flight.push_back(done.pts_us);
                self.stats.frames += 1;
                self.stats.bytes += encoded.data.len() as u64;
                self.stats.encode_cpu_us += encoded.cpu_us;
                tracing::trace!(
                    "window {}: {} bytes {} in {} µs ({} µs CPU)",
                    done.window,
                    encoded.data.len(),
                    if encoded.keyframe { "key" } else { "delta" },
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
            }
            Err(e) => {
                tracing::warn!("window {}: encode failed: {e}", done.window);
                w.stream.need_keyframe = true;
            }
        }
    }
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
    fn features_name_xwayland_only_when_running() {
        assert!(!features(false).contains(&"xwayland".to_string()));
        assert!(features(true).contains(&"xwayland".to_string()));
    }
}
