//! The client session: the handshake, the messages a client sends, and the pacing of
//! applications' frame callbacks by the client's vsync and the phone's present results.

use crate::net::{ConnId, NetEvent};
use crate::state::State;
use caboose_display_protocol::{self as proto, ByeReason, Message};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

/// A connection must say hello within this long.
pub const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// A display that has not ticked for this long paces its windows at 1 Hz.
pub const VSYNC_STALE: Duration = Duration::from_secs(1);

pub struct Session {
    pub conn: ConnId,
    /// The handshake is complete and windows are announced.
    pub ready: bool,
    /// Outputs supplied by this authenticated owner, not retained fallback outputs.
    pub owner_displays: HashSet<u32>,
    pub last_vsync: HashMap<u32, Instant>,
    /// The client plays Opus audio.
    pub audio: bool,
    /// The client runs games handed off to it, and this instance hands them off.
    pub wasm: bool,
    pub webview: bool,
    pub webview_grant: Option<String>,
    /// The client offers its hardware and this instance accepts it (docs/devices.md).
    pub devices: bool,
    /// The client aims touches at `targets`, and this instance has their provider.
    pub targets: bool,
    /// What the client takes from the clipboard besides text.
    pub clipboard_types: Vec<String>,
}

/// Features this server implements (docs/display.md, Handshake).
pub fn features(xwayland: bool, audio: bool, wasm: bool) -> Vec<String> {
    let mut f = vec![
        "vsync",
        "touch",
        "pencil",
        "text-input-v3",
        "cursor-named",
        "clipboard",
        "clipboard-types",
        "drop",
        "drag",
    ];
    if xwayland {
        f.push("xwayland");
    }
    if audio {
        f.push("audio");
    }
    if wasm {
        f.push("wasm");
    }
    f.into_iter().map(String::from).collect()
}

/// The process that owns a window and its ancestors: the Wayland client's pid, or an X11
/// window's _NET_WM_PID.
pub(crate) fn window_lineage(
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
    pid.map(crate::launch::lineage).unwrap_or_default()
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

    pub(crate) fn end_session(&mut self) {
        if self.session.as_ref().is_some_and(|s| s.devices) {
            if let Some(hub) = &self.devices {
                hub.disconnected();
            }
        }
        self.dnd_session_ended();
        if let Some(a) = self.audio.as_mut() {
            a.stop_capture();
        }
        self.session = None;
        self.games_session_changed();
        self.targets_session_changed();
        self.generation += 1;
        self.release_input();
        for w in self.windows.iter_mut() {
            w.announced = None;
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
        if !matches!(message, Message::Vsync { .. }) {
            tracing::debug!("connection {conn}: {message:?}");
        }
        // While a taken drag's content is read, the phone's input waits (it holds the lift
        // that ends the drag).
        let message = if matches!(message, Message::Touch(_) | Message::Pointer(_) | Message::Key(_)) {
            match self.defer_input(message) {
                Some(m) => m,
                None => return,
            }
        } else {
            message
        };
        match message {
            Message::Vsync { display, t_us: _ } => self.on_vsync(display),
            Message::Configure(c) => self.configure_window(&c),
            Message::Close { id } => self.close_window(id),
            Message::GameDecline { id, reason } => self.decline_game(id, &reason),
            Message::WebviewDecline { id, reason } => self.decline_webview(id, &reason),
            Message::Displays { displays } => self.set_displays(&displays),
            Message::Touch(_) | Message::Pointer(_) | Message::Key(_) => self.apply_input(message),
            Message::Text(t) => self.text(&t),
            Message::ClientClipboard(c) => self.clipboard_from_phone(c),
            Message::DropEnter(e) => self.drop_enter(e),
            Message::DropMotion { id, x, y } => self.drop_motion(id, x, y),
            Message::DropLeave => self.drop_leave(),
            Message::DropPerform(c) => self.drop_perform(c),
            Message::DragTake => self.drag_take(),
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

    /// Pointer, touch and key input from the client. The pointer waits while it drives a
    /// drop from the phone.
    pub fn apply_input(&mut self, message: Message) {
        match message {
            Message::Touch(t) => {
                self.targets_input(t.id);
                self.touch(&t)
            }
            Message::Pointer(p) if !self.dnd.drops() => {
                if p.buttons != self.input.pointer_buttons || p.scroll.is_some() {
                    self.targets_input(p.id);
                }
                self.pointer(&p)
            }
            Message::Key(k) => {
                if let Some(&id) = self.focus_history.last() {
                    self.targets_input(id);
                }
                self.key(&k)
            }
            _ => {}
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
        // One client at a time: the newest wins.
        if let Some(old) = self.session.take() {
            tracing::info!("connection {conn} replaces {}", old.conn);
            self.net.close_with(old.conn, Some(&Message::Bye { reason: ByeReason::Replaced }));
            self.session = Some(old);
            self.end_session();
        }
        self.generation += 1;
        self.set_displays(&hello.displays);
        let wasm = hello.wasm && self.games.socket.is_some();
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
        let devices = hello.devices && self.devices.is_some();
        let targets = hello.targets && std::path::Path::new(crate::targets::PROVIDER).is_file();
        let mut supported = features(self.xwm.is_some() || self.config.x_display.is_some(), self.audio.is_some(), wasm);
        if webview {
            supported.push("webview".into());
        }
        if devices {
            supported.push("devices".into());
        }
        if targets {
            supported.push("targets".into());
        }
        self.net.send(
            conn,
            &Message::ServerHello(proto::ServerHello {
                version: proto::VERSION,
                displays: self.displays.ids(),
                features: supported,
                epoch: Some(self.epoch.clone()),
                gpu_live_epoch: self.gpu_grants.as_ref().and_then(|g| g.epoch_if_ready()),
            }),
        );
        tracing::info!("connection {conn}: session started");
        let audio = hello.audio_decoders.as_ref().is_some_and(|d| d.iter().any(|c| c == "opus"));
        let clipboard_types = hello.clipboard_types.clone().unwrap_or_default();
        self.session = Some(Session {
            conn,
            ready: true,
            owner_displays: hello
                .displays
                .iter()
                .filter(|d| d.width > 0 && d.height > 0 && d.scale.is_finite() && d.scale > 0.0)
                .map(|d| d.id)
                .collect(),
            last_vsync: HashMap::new(),
            audio,
            wasm,
            webview,
            webview_grant,
            devices,
            targets,
            clipboard_types,
        });
        self.games_session_changed();
        self.targets_session_changed();
        if audio {
            let (tx, bitrate) = (self.audio_tx.clone(), self.config.audio_bitrate);
            if let Some(a) = self.audio.as_mut() {
                a.start_capture(tx, bitrate);
            }
        }
        for w in self.windows.iter_mut() {
            w.announced = None;
        }
        self.sync_windows();
        if let Some(cursor) = self.cursor.clone() {
            self.net.send(conn, &cursor);
        }
        // What the computer's clipboard holds, so the phone can paste it.
        if let Some(content) = self.clipboard.last_sent.clone() {
            self.send_clipboard(&content);
        }
        // Text input enabled before this client connected still needs the keyboard; the
        // toggle itself went to no one (or to the previous client).
        if let Some(surface) = self.keyboard_focus_surface() {
            let ibus = self.ibus_shown.as_ref().filter(|(s, _)| *s == surface).map(|(_, f)| f.clone());
            let enabled = match self.text_inputs.enabled_purpose(&surface) {
                Some(purpose) => Some((purpose.map(str::to_owned), self.text_inputs.surrounding(&surface))),
                None => ibus.map(|f| (Some(f.purpose.to_owned()), f.surrounding.as_ref().map(|s| s.wire()))),
            };
            if let (Some((purpose, surrounding)), Some(id)) = (enabled, self.window_of_surface(&surface)) {
                if self.windows.get(id).is_some_and(|w| w.announced.is_some()) {
                    let state = proto::TextInputState { id, enabled: true, purpose, surrounding };
                    self.net.send(conn, &Message::TextInput(state));
                }
            }
        }
    }

    pub fn set_displays(&mut self, displays: &[proto::Display]) {
        for d in displays {
            tracing::info!("phone display {} {}x{} scale {}", d.id, d.width, d.height, d.scale);
        }
        let owner_displays: HashSet<u32> = displays
            .iter()
            .filter(|d| d.width > 0 && d.height > 0 && d.scale.is_finite() && d.scale > 0.0)
            .map(|d| d.id)
            .collect();
        crate::last_displays::save(&self.config.socket, displays);
        if let Some(session) = self.session.as_mut() {
            session.owner_displays = owner_displays.clone();
        }
        let change = self.displays.replace(&self.dh, displays);
        // X11 follows the primary display's density (x11_scale.rs).
        self.apply_x11_scale();
        let revoked: Vec<_> = self
            .windows
            .iter()
            .filter_map(|window| {
                let available = owner_displays.contains(&window.display);
                (!available || change.removed.contains(&window.display)).then_some(window.id)
            })
            .collect();
        for id in revoked {
            let grant = self.gpu_grants.as_mut().and_then(|grants| grants.begin_revoke(id));
            if let Some(grant) = grant {
                if self.queue_gpu_revoke(grant).is_err() {
                    self.gpu_control_failed();
                }
            }
        }
        let fallback = self.displays.primary().info.id;
        let ids = self.windows.ids();
        let mut resized = Vec::new();
        let mut gpu_resized = Vec::new();
        for id in &ids {
            let active_gpu = self.gpu_grants.as_ref().is_some_and(|grants| grants.client_surface(*id));
            if let Some(w) = self.windows.get_mut(*id) {
                match change.follow(w.display, w.fullscreen || w.maximized, active_gpu) {
                    // The geometry the client gave for the old display no longer fits it:
                    // the window takes the new display until the client lays it out again.
                    crate::displays::Follow::Display => {
                        w.maximized_geometry = None;
                        resized.push(*id);
                    }
                    crate::displays::Follow::GpuWindow => gpu_resized.push(*id),
                    crate::displays::Follow::Stay => {}
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
            } else if gpu_resized.contains(&id) {
                self.configure_gpu_window_to_display(id);
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
            .filter(|w| w.display == display && w.picture.callbacks_pending && w.picture.can_release_callbacks())
            .map(|w| w.id)
            .collect();
        for id in ids {
            self.release_frame_callbacks(id);
        }
    }

    /// The broker released one of the window's presents: its application may draw again,
    /// if the window's display is paced by the client's vsync (otherwise the slow tick
    /// paces it).
    pub(crate) fn release_paced_callbacks(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        let paced = self
            .session
            .as_ref()
            .and_then(|s| s.last_vsync.get(&w.display))
            .is_some_and(|t| t.elapsed() < VSYNC_STALE);
        if paced && w.picture.callbacks_pending && w.picture.can_release_callbacks() {
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
                !paced && w.picture.callbacks_pending && w.picture.can_release_callbacks()
            })
            .map(|w| w.id)
            .collect();
        for id in stale {
            self.release_frame_callbacks(id);
        }
        if let Some(gpu) = self.gpu.as_mut() {
            gpu.prune();
        }
        self.dnd_tick();
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_compare_exactly() {
        assert!(token_matches(b"abc", b"abc"));
        assert!(!token_matches(b"abc", b"abd"));
        assert!(!token_matches(b"abc", b"ab"));
    }

    #[test]
    fn epochs_are_hex_and_differ() {
        let (a, b) = (new_epoch(), new_epoch());
        assert_eq!(a.len(), 16);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(a, b);
    }

    #[test]
    fn features_name_only_what_runs() {
        assert!(!features(false, false, false).contains(&"xwayland".to_string()));
        assert!(features(true, false, false).contains(&"xwayland".to_string()));
        assert!(features(false, true, false).contains(&"audio".to_string()));
        assert!(features(false, false, true).contains(&"wasm".to_string()));
        for gone in ["video", "tiles", "ack", "atlas", "scene", "draw", "scroll", "gpu"] {
            assert!(!features(true, true, true).contains(&gone.to_string()), "{gone}");
        }
    }
}
