//! The compositor's state and the Wayland protocol handlers.

use crate::config::Config;
use crate::displays::Displays;
use crate::input::InputState;
use crate::net::{HasNet, Net, NetEvent};
use crate::session::Session;
use crate::text_input::{TextInputs, Toggle};
use crate::windows::{Surface, Window, Windows};
use caboose_display_protocol::{self as proto, WindowKind};
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::renderer::utils::{on_commit_buffer_handler, with_renderer_surface_state};
use smithay::input::keyboard::{KeyboardTarget, KeysymHandle, ModifiersState};
use smithay::input::pointer::CursorImageStatus;
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::reexports::calloop::{LoopHandle, LoopSignal};
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode as DecorationMode;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::wl_data_device_manager::DndAction;
use smithay::reexports::wayland_server::protocol::wl_data_source::WlDataSource;
use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_seat, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{Client, DisplayHandle, Resource};
use smithay::utils::{Clock, IsAlive, Monotonic, Serial, SERIAL_COUNTER};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    get_parent, is_sync_subsurface, with_surface_tree_downward, CompositorClientState, CompositorHandler,
    BufferAssignment, CompositorState, SurfaceAttributes, TraversalAction,
};
use smithay::wayland::dmabuf::{DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier};
use smithay::wayland::fractional_scale::{with_fractional_scale, FractionalScaleHandler};
use smithay::wayland::output::OutputHandler;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::selection::data_device::{
    set_data_device_focus, ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
};
use smithay::wayland::selection::primary_selection::{
    set_primary_focus, PrimarySelectionHandler, PrimarySelectionState,
};
use smithay::wayland::selection::{SelectionHandler, SelectionSource, SelectionTarget};
use smithay::wayland::shell::kde::decoration::{KdeDecorationHandler, KdeDecorationState};
use smithay::wayland::shell::xdg::decoration::XdgDecorationHandler;
use smithay::wayland::shell::xdg::{PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState};
use smithay::wayland::shm::{ShmHandler, ShmState};
use smithay::wayland::xwayland_shell::{XWaylandShellHandler, XWaylandShellState};
use smithay::xwayland::{X11Surface, X11Wm};
use std::borrow::Cow;
use std::time::Duration;

/// How long the compositor stands aside in a window for an application's bind.
const YIELD_LIMIT: Duration = Duration::from_secs(5);

/// Keyboard focus: a Wayland surface, or an X11 window (which also needs X input focus).
#[derive(Debug, Clone, PartialEq)]
pub enum KeyboardFocus {
    Wayland(WlSurface),
    X11(X11Surface),
}

impl IsAlive for KeyboardFocus {
    fn alive(&self) -> bool {
        match self {
            KeyboardFocus::Wayland(s) => s.alive(),
            KeyboardFocus::X11(x) => x.alive(),
        }
    }
}

impl WaylandFocus for KeyboardFocus {
    fn wl_surface(&self) -> Option<Cow<'_, WlSurface>> {
        match self {
            KeyboardFocus::Wayland(s) => Some(Cow::Borrowed(s)),
            KeyboardFocus::X11(x) => x.wl_surface().map(Cow::Owned),
        }
    }
}

impl KeyboardTarget<State> for KeyboardFocus {
    fn enter(&self, seat: &Seat<State>, data: &mut State, keys: Vec<KeysymHandle<'_>>, serial: Serial) {
        match self {
            KeyboardFocus::Wayland(s) => KeyboardTarget::enter(s, seat, data, keys, serial),
            KeyboardFocus::X11(x) => KeyboardTarget::enter(x, seat, data, keys, serial),
        }
    }
    fn leave(&self, seat: &Seat<State>, data: &mut State, serial: Serial) {
        match self {
            KeyboardFocus::Wayland(s) => KeyboardTarget::leave(s, seat, data, serial),
            KeyboardFocus::X11(x) => KeyboardTarget::leave(x, seat, data, serial),
        }
    }
    fn key(
        &self,
        seat: &Seat<State>,
        data: &mut State,
        key: KeysymHandle<'_>,
        state: smithay::backend::input::KeyState,
        serial: Serial,
        time: u32,
    ) {
        match self {
            KeyboardFocus::Wayland(s) => KeyboardTarget::key(s, seat, data, key, state, serial, time),
            KeyboardFocus::X11(x) => KeyboardTarget::key(x, seat, data, key, state, serial, time),
        }
    }
    fn modifiers(&self, seat: &Seat<State>, data: &mut State, modifiers: ModifiersState, serial: Serial) {
        match self {
            KeyboardFocus::Wayland(s) => KeyboardTarget::modifiers(s, seat, data, modifiers, serial),
            KeyboardFocus::X11(x) => KeyboardTarget::modifiers(x, seat, data, modifiers, serial),
        }
    }
}

#[derive(Default)]
pub struct ClientState {
    pub compositor: CompositorClientState,
    pub gpu_peer: Option<crate::gpu_peer::GpuPeer>,
    /// Which connection to the Wayland socket this was, counting from 1 (0 for Xwayland's own):
    /// the control socket's `windows` names it, so a tool that opened the connections can
    /// tell whose window is whose.
    pub ordinal: u64,
}

impl ClientData for ClientState {
    fn initialized(&self, _: ClientId) {}
    fn disconnected(&self, _: ClientId, reason: DisconnectReason) {
        // A client the compositor cut off says why: it sees only a broken connection.
        if let DisconnectReason::ProtocolError(error) = reason {
            tracing::warn!("client disconnected: {error}");
        }
    }
}

/// Counters the control socket's `stats` and the exit log report.
#[derive(Default, Debug, Clone)]
pub struct Stats {
    /// Window renders, and those that changed nothing.
    pub renders: u64,
    pub unchanged_renders: u64,
    /// Main-thread time spent rendering windows into their images.
    pub render_us: u64,
    /// Pixels redrawn.
    pub damaged_px: u64,
    /// Bytes texture uploads copied out of wl_shm buffers.
    pub uploaded_bytes: u64,
    /// The compositor's own images the broker was asked to show, and client buffers.
    pub presents: u64,
    pub direct_presents: u64,
    /// Presents the broker released without showing (replaced, or refused).
    pub unshown: u64,
}

impl Stats {
    pub fn summary(&self) -> String {
        format!(
            "{} presents of the compositor's images and {} of client buffers ({} not shown); {} renders ({} unchanged), {} pixels redrawn, {} kB uploaded from shared memory, {:.2} ms per render",
            self.presents,
            self.direct_presents,
            self.unshown,
            self.renders,
            self.unchanged_renders,
            self.damaged_px,
            self.uploaded_bytes / 1000,
            if self.renders > 0 { self.render_us as f64 / self.renders as f64 / 1000.0 } else { 0.0 }
        )
    }
}

pub struct State {
    pub dh: DisplayHandle,
    pub handle: LoopHandle<'static, State>,
    pub signal: LoopSignal,
    pub clock: Clock<Monotonic>,
    pub config: Config,

    pub compositor: CompositorState,
    pub xdg_shell: XdgShellState,
    pub kde_decoration: KdeDecorationState,
    pub shm: ShmState,
    pub dmabuf: DmabufState,
    pub seat_state: SeatState<State>,
    pub data_device: DataDeviceState,
    /// Held so the `zwp_pointer_gestures_v1` global stays registered.
    #[allow(dead_code)]
    pub pointer_gestures: smithay::wayland::pointer_gestures::PointerGesturesState,
    pub primary_selection: PrimarySelectionState,
    pub xwayland_shell: XWaylandShellState,
    /// The hint protocols' globals (hints.rs) and the xdg-activation tokens.
    pub hint_protocols: crate::hints::Protocols,
    pub activation: smithay::wayland::xdg_activation::XdgActivationState,
    /// What clients hold through them.
    pub hints: crate::hints::Hints,
    pub seat: Seat<State>,
    pub xwm: Option<X11Wm>,
    /// Xwayland's own client, whose scale is the primary display's (x11_scale.rs).
    pub xwayland_client: Option<smithay::reexports::wayland_server::Client>,
    pub x11_scale: f64,
    pub x11_foreground: Option<crate::x11_focus::Foreground>,
    /// The X server's window tree and client records, for GPU surface binds on X11 windows.
    pub gpu_x11: Option<crate::gpu_x11::X11Windows>,
    /// Applications' own GPU surfaces inset in their windows (children.rs).
    pub children: crate::children::Children,
    /// The child the bind being answered made, ended again if the bind is refused.
    pub gpu_bind_new_child: Option<u64>,
    /// The X11 bind being answered names a window larger than its top-level (gpu_x11.rs).
    pub gpu_bind_larger: bool,
    /// The X11 bind being answered names a window the bound process made that is not
    /// bindable yet: it is held (gpu_pending.rs).
    pub gpu_bind_holdable: bool,
    /// X11 binds held until their windows are bindable, and whether a look at them again
    /// is scheduled.
    pub gpu_pending_binds: crate::gpu_pending::PendingBinds<crate::gpu_control::Bind>,
    pub gpu_pending_sweep: bool,
    pub x11_identity: Option<crate::x11_identity::X11Identity>,
    /// The input-method service for applications without text-input-v3 (ibus.rs).
    pub ibus: Option<crate::ibus::Ibus>,
    /// The IBus field the phone's keyboard was last shown for, and its window's surface.
    pub ibus_shown: Option<(WlSurface, crate::ibus::Field)>,
    pub text_inputs: TextInputs,

    pub windows: Windows,
    pub displays: Displays,
    /// The GPU renderer, made again whenever the phone's executor comes or goes.
    pub gpu: Option<crate::render::Gpu>,
    pub gpu_generation: u64,
    /// When the renderer was last made again after a failed render, and whether doing
    /// so again is already scheduled (present.rs `renderer_failed`).
    pub gpu_recovered_at: Option<std::time::Instant>,
    pub gpu_recovery_pending: bool,
    /// Windows the compositor stands aside in while an application binds its own surface
    /// to them, and since when (`yield_window`).
    pub yielded: std::collections::HashMap<u64, std::time::Instant>,
    /// The last canvas serial given out (render.rs `Canvas`).
    pub next_canvas: u64,
    /// The computer's vgem render node, when it has one.
    pub render_node: Option<std::path::PathBuf>,
    pub net: Net,
    pub session: Option<Session>,
    pub input: InputState,
    /// Windows in the order they were focused, most recent last.
    pub focus_history: Vec<u64>,
    pub games: crate::game::Games,
    pub control: crate::control::Control,
    /// The focused window's controls for a client that aims touches (targets.rs).
    pub targets: crate::targets::Targets,
    pub clipboard: crate::clipboard::Clipboard,
    /// How the compositor reaches its Xwayland as a client, once it runs.
    pub x11: Option<crate::x11sel::Access>,
    pub dnd: crate::dnd::Dnd,
    /// The compositor's PulseAudio, when it runs.
    pub audio: Option<crate::audio::Audio>,
    pub audio_tx: smithay::reexports::calloop::channel::Sender<crate::audio::Packet>,
    /// The phone's hardware as devices, on the owner's display (docs/devices.md).
    pub devices: Option<crate::devices::Hub>,
    pub devices_tx: smithay::reexports::calloop::channel::Sender<caboose_display_protocol::Message>,
    /// Bumped per client session; stale encoder results are discarded.
    pub generation: u64,
    /// Random for this process, sent in every hello: window ids are unique within it.
    pub epoch: String,
    pub gpu_grants: Option<crate::gpu_grant::Grants>,
    /// The private GPU broker is restarted whenever it ends: a restart is pending, the
    /// delay before the next one (doubling to 30 s, reset by a broker that lasted a
    /// minute), and when the current broker started.
    pub gpu_restart_pending: bool,
    pub gpu_restart_delay: std::time::Duration,
    pub gpu_started_at: std::time::Instant,
    /// Phone-resident buffers committed to windows and held until the broker releases them.
    pub remote_presents: crate::remote_buffers::Presents,
    pub stats: Stats,
    /// When client input arrived, for frame lab (`frames` on the control socket).
    pub input_trace: crate::frame_trace::Ring<crate::frame_trace::Input>,
    /// Per-input latency correlation (frame_trace::LatencyTrace).
    pub latency: crate::frame_trace::LatencyTrace,
    /// wp_presentation: clients ask when their frames reached the screen.
    pub presentation: smithay::wayland::presentation::PresentationState,
    /// Presentation sequence counter, one per released frame.
    pub present_seq: u64,
    pub next_input_id: u64,
    /// The cursor last sent, so it is re-sent to a new client.
    pub cursor: Option<proto::Message>,
}

impl HasNet for State {
    fn net(&mut self) -> &mut Net {
        &mut self.net
    }
    fn loop_handle(&self) -> LoopHandle<'static, Self> {
        self.handle.clone()
    }
    fn on_net_events(&mut self, events: Vec<NetEvent>) {
        use caboose_display_protocol::Message;
        let input = events.iter().any(|e| matches!(e, NetEvent::Message(_, Message::Pointer(_) | Message::Touch(_)
            | Message::Key(_) | Message::Text(_) | Message::Pencil(_))));
        let trace = input_trace().then(|| {
            let scrolls: Vec<(f64, f64)> = events.iter().filter_map(|e| match e {
                NetEvent::Message(_, Message::Pointer(p)) => p.scroll.as_ref().map(|s| (s.dx, s.dy)),
                _ => None,
            }).collect();
            (crate::state::monotonic_us(), scrolls)
        });
        for event in events { self.on_net_event(event); }
        // Input reaches applications now, not after this turn's rendering: a window's
        // composition can take longer than the next input sample's interval.
        if input {
            if let Err(e) = self.dh.flush_clients() {
                tracing::warn!("flushing Wayland clients: {e}");
            }
        }
        if let Some((received, scrolls)) = trace {
            let injected = crate::state::monotonic_us();
            for (dx, dy) in &scrolls {
                eprintln!("CABOOSE_INPUT_TRACE kind=scroll received_us={received} flushed_us={injected} batch={} dx={dx:.2} dy={dy:.2}", scrolls.len());
            }
        }
    }
    fn on_gpu_record(&mut self, record: crate::gpu_control::Record) { self.handle_gpu_record(record); }
    fn on_gpu_control_sent(&mut self, grant: Option<crate::gpu_grant::Grant>) {
        if let Some(grant) = grant {
            if self.gpu_grants.as_mut().is_none_or(|grants| grants.revoke_sent(grant).is_err()) {
                self.gpu_control_failed();
            }
        }
    }
    #[track_caller]
    fn on_gpu_control_failure(&mut self) { self.gpu_control_failed(); }
}

impl State {
    /// Native Wayland toplevel identity from its accepted peer, never X11 PID
    /// properties. This does not mint or authorize a surface grant by itself.
    #[allow(dead_code)]
    pub fn native_gpu_surface_identity(&self, window: u64) -> Option<(u32, u32, u64, u32)> {
        use smithay::reexports::wayland_server::Resource;
        let window = self.windows.get(window)?;
        let Surface::Toplevel(toplevel) = &window.surface else { return None };
        let surface = toplevel.wl_surface();
        let object = surface.id();
        let client = self.dh.get_client(object.clone()).ok()?;
        let peer = client.get_data::<ClientState>()?.gpu_peer.as_ref()?;
        if !peer.alive() { return None; }
        Some((peer.uid, peer.pid, peer.start_ticks, object.protocol_id()))
    }

    /// Toplevels whose own wl_surface is the bind's object, made by the bound process; or,
    /// for a client that shows child windows, the child for a subsurface of one.
    fn wayland_gpu_bind_matches(&mut self, bind: &crate::gpu_control::Bind) -> Vec<u64> {
        use smithay::reexports::wayland_server::Resource;
        use std::os::fd::AsRawFd;
        let mut matches = Vec::new();
        let mut inset = Vec::new();
        for window in self.windows.iter() {
            let Surface::Toplevel(toplevel) = &window.surface else { continue };
            let root = toplevel.wl_surface();
            let object = root.id();
            let Ok(client) = self.dh.get_client(object.clone()) else { continue };
            let Some(peer) = client.get_data::<ClientState>().and_then(|state| state.gpu_peer.as_ref()) else { continue };
            if !peer.matches_pidfd(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()) { continue; }
            if object.protocol_id() == bind.object {
                matches.push(window.id);
                continue;
            }
            // Protocol ids are per client: a subsurface of the bound client's window.
            smithay::wayland::compositor::with_surface_tree_downward(root, (), |_, _, _|
                smithay::wayland::compositor::TraversalAction::DoChildren(()),
                |surface, _, _| if surface != root && surface.id().protocol_id() == bind.object { inset.push((window.id, surface.clone())) },
                |_, _, _| true);
        }
        if matches.is_empty() && inset.len() == 1 && self.session.as_ref().is_some_and(|s| s.children) {
            let (parent, surface) = inset.remove(0);
            let (id, new) = self.subsurface_child(parent, &surface);
            if new { self.gpu_bind_new_child = Some(id); }
            matches.push(id);
        }
        matches
    }

    /// The managed X11 toplevel the bind's window is or covers, when the X server records
    /// the bound process as the client that created that window (docs/gpu-live.md).
    fn x11_gpu_bind_matches(&mut self, bind: &crate::gpu_control::Bind) -> Vec<u64> {
        use std::os::fd::AsRawFd;
        let Some(lookup) = &self.gpu_x11 else { return Vec::new() };
        // SAFETY: geteuid has no arguments or memory-safety preconditions.
        if bind.uid != unsafe { libc::geteuid() } ||
            !crate::gpu_peer::pidfd_identifies(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()) {
            return Vec::new();
        }
        // Top-level windows, and override-redirect ones (menus, tooltips, dropdowns), which
        // the phone shows as popups placed over their parent: every window an application
        // draws in gets a phone surface, so none is ever presented by a copy back.
        let toplevels: Vec<(u32, u64)> = self.windows.iter().filter_map(|window| match &window.surface {
            Surface::X11(x11) if gpu_bindable_x11(window.parent.is_none(), x11.is_override_redirect(), x11.alive()) =>
                Some((x11.window_id(), window.id)),
            _ => None,
        }).collect();
        let ids: Vec<u32> = toplevels.iter().map(|(xid, _)| *xid).collect();
        match lookup.resolve(bind.object, &ids, self.x11_scale) {
            Ok(Some(found)) if found.inset && found.pid == bind.pid &&
                crate::gpu_peer::pidfd_identifies(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()) => {
                // An inset child (a browser view) is a child window of its top-level, for a
                // client that shows children; for any other it has nowhere to be shown.
                let parents: Vec<u64> = toplevels.iter().filter(|(xid, _)| *xid == found.toplevel).map(|(_, id)| *id).collect();
                if parents.len() != 1 || !self.session.as_ref().is_some_and(|s| s.children) {
                    tracing::info!("GPU X11 bind of {:#x} by process {} refused: {}", bind.object, bind.pid,
                                   lookup.refusal(bind.object, &ids, self.x11_scale, bind.pid));
                    return Vec::new();
                }
                let (id, new) = self.x11_child(parents[0], bind.object, found.toplevel);
                if new { self.gpu_bind_new_child = Some(id); }
                vec![id]
            }
            Ok(Some(found)) if found.pid == bind.pid &&
                crate::gpu_peer::pidfd_identifies(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()) => {
                let matches: Vec<u64> = toplevels.iter().filter(|(xid, _)| *xid == found.toplevel).map(|(_, id)| *id).collect();
                if found.larger {
                    // A swapchain larger than its top-level (a game's, sized to the screen,
                    // in a window held smaller): the window grows to the display to show it.
                    self.gpu_bind_larger = true;
                }
                matches
            }
            Ok(_) if !self.gpu_pending_binds.expired_before(bind.object, bind.pid) &&
                lookup.holds_until_bindable(bind.object, &ids, bind.pid).unwrap_or(false) => {
                // A window the bound process made that is not bindable yet (a menu, top-level
                // or child made before it is shown): the bind is held until it is (gpu_pending.rs).
                self.gpu_bind_holdable = true;
                Vec::new()
            }
            Ok(_) => {
                // Binds are rare and retried a few times: each refusal says why, so a window
                // left without its phone surface (white) can be told from the log alone.
                tracing::info!("GPU X11 bind of {:#x} by process {} refused: {}", bind.object, bind.pid,
                               lookup.refusal(bind.object, &ids, self.x11_scale, bind.pid));
                Vec::new()
            }
            Err(error) => {
                tracing::warn!("GPU X11 window lookup: {error}");
                Vec::new()
            }
        }
    }

    /// A buffer window: one this compositor asked the broker to show a remote buffer in,
    /// bound to a live process of the compositor's user, the compositor itself included
    /// (its own images of every window, popups too). The broker names the process that
    /// registered the buffer; holding its dma-buf is that process's proof of ownership.
    fn buffer_gpu_bind_matches(&self, bind: &crate::gpu_control::Bind) -> Vec<u64> {
        use std::os::fd::AsRawFd;
        let window = u64::from(bind.object);
        // SAFETY: geteuid has no arguments or memory-safety preconditions.
        let ours = bind.uid == unsafe { libc::geteuid() } &&
            crate::gpu_peer::pidfd_identifies(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd());
        let admitted = crate::picture::buffer_bind_admits(
            self.windows.get(window).is_some(), self.remote_presents.presenting(window), ours);
        if admitted { vec![window] } else { Vec::new() }
    }

    /// A window committed a new remote buffer, on its own surface or on a subsurface that
    /// covers its window geometry (Chromium's primary plane, over a one-pixel root): ask the
    /// broker to show it as it is.
    fn present_remote_buffer(&mut self, surface: &WlSurface) {
        let Some(buffer) = with_renderer_surface_state(surface, |state| state.buffer().cloned()).flatten() else { return };
        let Ok(dmabuf) = smithay::wayland::dmabuf::get_dmabuf(&buffer) else { return };
        if !crate::remote_buffers::is_remote(dmabuf) { return }
        let size = smithay::backend::allocator::Buffer::size(dmabuf);
        let skipped = |reason: &str| {
            // The first 32, then every 256th: enough to diagnose without flooding the log.
            static SKIPPED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = SKIPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if n < 32 || n % 256 == 0 {
                tracing::info!("remote buffer not presented: {reason} (buffer {}x{}, skip {})", size.w, size.h, n + 1);
            }
        };
        if self.gpu_grants.is_none() { return skipped("no private GPU") }
        if self.gpu_grants.as_ref().and_then(|grants| grants.epoch_if_ready()).is_none() { return skipped("no GPU epoch") }
        let Some(id) = self.window_of_surface(surface) else { return skipped("no window") };
        let Some(window) = self.windows.get(id) else { return skipped("no window") };
        if window.surface.wl_surface().as_ref() != Some(surface) && !covers_geometry(surface, window.local_geometry()) {
            let geometry = window.local_geometry();
            return skipped(&format!("subsurface does not cover the window geometry {}x{} at {},{}",
                geometry.size.w, geometry.size.h, geometry.loc.x, geometry.loc.y));
        }
        let (Some(identity), size) = (crate::remote_buffers::identity(dmabuf), smithay::backend::allocator::Buffer::size(dmabuf)) else { return };
        let (Ok(width), Ok(height)) = (u32::try_from(size.w), u32::try_from(size.h)) else { return };
        let fence = crate::remote_buffers::pending_fence(dmabuf);
        let request = self.remote_presents.begin(id, crate::remote_buffers::Held::Client { _buffer: buffer });
        self.stats.direct_presents += 1;
        let Some(fence) = fence else {
            self.send_remote_present(request, id, identity, width, height);
            return;
        };
        // A client relying on implicit synchronization: show the buffer once its rendering
        // finished. A newer commit replaces a present still waiting.
        use smithay::reexports::calloop::generic::Generic;
        use smithay::reexports::calloop::{Interest, Mode, PostAction};
        let inserted = self.handle.insert_source(Generic::new(fence, Interest::READ, Mode::OneShot),
            move |_, _, state: &mut State| {
                if state.remote_presents.fence_signaled(id, request) {
                    state.send_remote_present(request, id, identity, width, height);
                }
                Ok(PostAction::Remove)
            });
        match inserted {
            Ok(token) => {
                if let Some((replaced, old)) = self.remote_presents.fence(id, request, token) {
                    self.handle.remove(old);
                    self.own_present_released(replaced);
                }
            }
            Err(_) => { self.own_present_released(request); }
        }
    }

    pub(crate) fn send_remote_present(&mut self, request: u64, window: u64, identity: (u64, u64), width: u32, height: u32) {
        static SENT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = SENT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if n < 8 || n % 1024 == 0 {
            tracing::info!("remote buffer present {}: window {window}, {width}x{height}", n + 1);
        }
        let sent = crate::gpu_control::buffer_present(request, window, identity, width, height)
            .and_then(|bytes| self.net.queue_gpu_control(bytes, None));
        if sent.is_err() {
            self.own_present_released(request);
            self.gpu_control_failed();
        }
    }

    fn release_remote_presents(&mut self) {
        let (tokens, held) = self.remote_presents.release_all();
        for token in tokens {
            self.handle.remove(token);
        }
        for (window, held) in held {
            self.free_held(window, held);
        }
    }

    #[track_caller]
    pub(crate) fn gpu_control_failed(&mut self) {
        // Each failure says where it came from: it also closes the display session.
        let at = std::panic::Location::caller();
        eprintln!("caboose-display: private GPU control failed at {}:{}", at.file(), at.line());
        // Without the broker no release will come: return every held buffer. Held binds
        // were the broker's, whose requests a restarted broker numbers anew.
        self.release_remote_presents();
        self.gpu_pending_binds.clear();
        if let Some(grants) = self.gpu_grants.as_mut() { grants.fail(); }
        self.net.fail_gpu_control();
        self.reconnect_for_gpu_epoch();
        self.schedule_gpu_restart();
        // Whatever executor the renderer was on is gone with the broker.
        self.rebuild_gpu_after_loss();
    }

    pub(crate) fn schedule_gpu_restart(&mut self) {
        if self.gpu_restart_pending || self.config.private_gpu_stream.is_none() { return; }
        self.gpu_restart_pending = true;
        if self.gpu_started_at.elapsed() >= std::time::Duration::from_secs(60) {
            self.gpu_restart_delay = std::time::Duration::from_secs(1);
        }
        let delay = self.gpu_restart_delay;
        self.gpu_restart_delay = (delay * 2).min(std::time::Duration::from_secs(30));
        if self.config.joins_gpu_broker() {
            eprintln!("caboose-display: joining the shared GPU broker in {} ms", delay.as_millis());
        } else {
            eprintln!("caboose-display: the private GPU broker ended; restarting in {} ms", delay.as_millis());
        }
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        let inserted = self.handle.insert_source(Timer::from_duration(delay), |_, _, state: &mut State| {
            state.restart_private_gpu();
            TimeoutAction::Drop
        });
        if inserted.is_err() { self.gpu_restart_pending = false; }
    }

    fn restart_private_gpu(&mut self) {
        self.gpu_restart_pending = false;
        let (Some(stream), Some(surface), Some(token)) = (self.config.private_gpu_stream.clone(),
            self.config.private_gpu_surface.clone(), self.config.token_file.clone()) else { return };
        // Stops and reaps the previous broker, reporting how it ended.
        self.net.disable_private_gpu();
        let broker = self.config.private_gpu_broker.clone();
        // A broker that died without cleaning up leaves its sockets behind; a shared broker's
        // sockets are its own.
        for path in [&stream, &surface].into_iter().filter(|_| broker.is_none()) {
            use std::os::unix::fs::FileTypeExt;
            if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_socket()) {
                let _ = std::fs::remove_file(path);
            }
        }
        let grants = match crate::gpu_grant::Grants::new() {
            Ok(grants) => grants,
            Err(error) => { eprintln!("caboose-display: private GPU entropy: {error}"); self.schedule_gpu_restart(); return; }
        };
        let handle = self.handle.clone();
        match self.net.enable_private_gpu(&token, &stream, &surface, self.config.private_gpu_indexed, broker.as_deref(), &handle) {
            Ok(()) => {
                self.gpu_grants = Some(grants);
                self.gpu_pending_binds.clear();
                self.gpu_started_at = std::time::Instant::now();
                eprintln!("caboose-display: private GPU broker restarted");
            }
            Err(error) => { eprintln!("caboose-display: private GPU broker restart failed: {error}"); self.schedule_gpu_restart(); }
        }
    }

    fn reconnect_for_gpu_epoch(&mut self) {
        if let Some(conn) = self.session.as_ref().map(|s| s.conn) {
            self.net.close_with(conn, None);
            self.end_session();
        }
    }

    /// The compositor stops presenting in window `id` and revokes its grant there, for an
    /// application that binds its own surface to it. It presents again if none has bound
    /// within `YIELD_LIMIT`.
    fn yield_window(&mut self, id: u64) {
        self.yielded.insert(id, std::time::Instant::now());
        let grant = self.gpu_grants.as_mut().and_then(|grants| grants.begin_revoke(id));
        if let Some(grant) = grant {
            tracing::info!("window {id}: an application binds its own surface; the compositor's images stand aside");
            if self.queue_gpu_revoke(grant).is_err() {
                self.gpu_control_failed();
            }
        }
    }

    /// Whether the compositor presents nothing in window `id` while an application binds it.
    pub(crate) fn yielding(&mut self, id: u64) -> bool {
        match self.yielded.get(&id) {
            Some(at) if at.elapsed() < YIELD_LIMIT => true,
            Some(_) => {
                self.yielded.remove(&id);
                if let Some(w) = self.windows.get_mut(id) { w.picture.repaint(); }
                false
            }
            None => false,
        }
    }

    pub(crate) fn queue_gpu_revoke(&mut self, grant: crate::gpu_grant::Grant) -> std::io::Result<()> {
        let bytes = crate::gpu_control::revoke(grant)?;
        self.net.queue_gpu_control(bytes, Some(grant))
    }

    pub(crate) fn configure_gpu_window_to_display(&mut self, id: u64) {
        let Some(display) = self.windows.get(id).and_then(|w| self.displays.get(w.display)) else { return };
        let size = display.logical_size();
        let Some(window) = self.windows.get(id) else { return };
        match &window.surface {
            Surface::Toplevel(toplevel) => {
                toplevel.with_pending_state(|state| state.size = Some(size));
                toplevel.send_configure();
            }
            Surface::X11(x11) => {
                let at = x11.geometry().loc;
                if let Err(error) = x11.configure(smithay::utils::Rectangle::new(at, size)) {
                    tracing::warn!("GPU window configure: {error}");
                }
            }
            Surface::Popup(_) => {}
        }
    }

    /// Answers a bind: with a grant for the one window it matches, else refused. An X11 bind
    /// of a window the bound process made that is not bindable yet is held instead, and
    /// answered again (`since` is when it was first held) when an X11 window maps and every
    /// `gpu_pending::SWEEP` (gpu_pending.rs).
    fn answer_gpu_bind(&mut self, bind: crate::gpu_control::Bind, since: Option<std::time::Instant>) {
        use crate::gpu_control;
        // A newer bind of a window replaces the bind held for it by the same process.
        if since.is_none() && bind.space == gpu_control::X11_WINDOW {
            for old in self.gpu_pending_binds.take_window(bind.object, Some(bind.pid)) {
                tracing::info!("held GPU X11 bind of {:#x} by process {} refused: a newer bind replaces it", old.object, old.pid);
                self.refuse_gpu_bind(old.request);
            }
        }
        // A probe (a bind with no frame to show) never takes a window: the compositor keeps
        // presenting the window's own picture, and the process answers its queries itself.
        // Its first frame binds again at once, and that bind is answered as any other.
        if bind.probe {
            tracing::info!("GPU bind of {:#x} by process {} refused: a probe, with no frame to show", bind.object, bind.pid);
            self.refuse_gpu_bind(bind.request);
            return;
        }
        self.gpu_bind_larger = false;
        self.gpu_bind_holdable = false;
        let mut matches = match bind.space {
            gpu_control::X11_WINDOW => self.x11_gpu_bind_matches(&bind),
            gpu_control::BUFFER_WINDOW => self.buffer_gpu_bind_matches(&bind),
            _ => self.wayland_gpu_bind_matches(&bind),
        };
        if std::mem::take(&mut self.gpu_bind_holdable) {
            let now = std::time::Instant::now();
            let held = crate::gpu_pending::Held { object: bind.object, pid: bind.pid, since: since.unwrap_or(now), bind };
            if held.expired(now) {
                tracing::info!("held GPU X11 bind of {:#x} by process {} refused: no top-level held the window within {} ms",
                               held.object, held.pid, crate::gpu_pending::HOLD.as_millis());
                self.gpu_pending_binds.remember_expired(held.object, held.pid);
                self.refuse_gpu_bind(held.bind.request);
                return;
            }
            let (object, pid) = (held.object, held.pid);
            match self.gpu_pending_binds.hold(held) {
                Ok(()) => {
                    if since.is_none() {
                        tracing::info!("GPU X11 bind of {object:#x} by process {pid} held until the window is bindable");
                    }
                    self.schedule_pending_gpu_binds(crate::gpu_pending::SWEEP);
                }
                Err(bind) => {
                    tracing::info!("GPU X11 bind of {object:#x} by process {pid} refused: {} binds are held already",
                                   crate::gpu_pending::LIMIT);
                    self.refuse_gpu_bind(bind.request);
                }
            }
            return;
        }
        // A retained fallback display is not an authenticated owner layout.
        // Ambiguous Wayland connections must remain ambiguous, even if
        // only one happens to be on an eligible output.
        if matches.len() == 1 && !self.bind_window(matches[0]).is_some_and(|window|
            self.session.as_ref().is_some_and(|session| session.ready && session.owner_displays.contains(&window.display)) &&
            self.displays.get(window.display).is_some_and(|display| {
                let size = display.logical_size(); size.w > 0 && size.h > 0
            })) { matches.clear(); }
        // An application binding a window the compositor presents its own images in
        // (a game's swapchain on its X11 window) gets it once that grant is retired:
        // the compositor stops presenting there and revokes it, and the application's
        // next attempt is granted.
        // Nor does a present of the compositor's own take a window back meanwhile.
        if bind.space == gpu_control::BUFFER_WINDOW && bind.pid == std::process::id() &&
            matches.len() == 1 && self.yielding(matches[0]) {
            matches.clear();
        }
        if bind.space != gpu_control::BUFFER_WINDOW && matches.len() == 1 &&
            self.gpu_grants.as_ref().is_some_and(|grants| grants.buffer_window(matches[0])) {
            self.yield_window(matches[0]);
        }
        let peer = (bind.uid, bind.pid, bind.start_ticks, bind.object);
        let grant = self.gpu_grants.as_mut().and_then(|grants|
            grants.bind(bind.process, bind.space, peer, &matches).ok());
        if grant.is_none() && since.is_none() {
            // Every refused bind says why (the X11 lookup has said so already when nothing matched).
            let reason = self.gpu_grants.as_ref().map_or("no GPU grants", |grants| grants.refusal(bind.process, peer, &matches));
            if bind.pid != std::process::id() && !(bind.space == gpu_control::X11_WINDOW && matches.is_empty()) {
                tracing::info!("GPU bind of {:#x} by process {} refused: {reason}", bind.object, bind.pid);
            }
        }
        // A child made for this bind lives only with its grant.
        if let Some(child) = self.gpu_bind_new_child.take().filter(|_| grant.is_none()) {
            self.children.remove(child);
        }
        if let Some(grant) = grant {
            // A popup keeps the place and size its application gave it, and a window the
            // phone placed keeps its geometry: CEF rebinding on every swapchain recreate
            // would otherwise resize it to the display each time. The compositor's own
            // images take the window's size as it is.
            let grows = std::mem::take(&mut self.gpu_bind_larger);
            let application = bind.pid != std::process::id();
            if application && self.windows.get(grant.window)
                .is_some_and(|window| window.kind != WindowKind::Popup && (grows || window.gpu_bind_follows_display())) {
                self.configure_gpu_window_to_display(grant.window);
            }
            self.sync_windows();
        }
        if since.is_some() {
            match &grant {
                Some(grant) => tracing::info!("held GPU X11 bind of {:#x} by process {} attached to window {}",
                                              bind.object, bind.pid, grant.window),
                None => tracing::info!("held GPU X11 bind of {:#x} by process {} refused",
                                       bind.object, bind.pid),
            }
        }
        if gpu_control::response(bind.request, grant).and_then(|bytes| self.net.queue_gpu_control(bytes, None)).is_err() {
            self.gpu_control_failed();
        }
    }

    fn refuse_gpu_bind(&mut self, request: u64) {
        if crate::gpu_control::response(request, None).and_then(|bytes| self.net.queue_gpu_control(bytes, None)).is_err() {
            self.gpu_control_failed();
        }
    }

    /// Looks at the held binds again after `delay`, unless that is already scheduled.
    pub(crate) fn schedule_pending_gpu_binds(&mut self, delay: std::time::Duration) {
        if self.gpu_pending_sweep || self.gpu_pending_binds.is_empty() { return; }
        self.gpu_pending_sweep = true;
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        let inserted = self.handle.insert_source(Timer::from_duration(delay), |_, _, state: &mut State| {
            state.gpu_pending_sweep = false;
            state.answer_pending_gpu_binds();
            TimeoutAction::Drop
        });
        if inserted.is_err() {
            // Nothing would look at them again: refuse them now.
            self.gpu_pending_sweep = false;
            for held in self.gpu_pending_binds.take_all() {
                self.refuse_gpu_bind(held.bind.request);
            }
        }
    }

    /// Answers every held bind whose window is bindable now, and refuses those whose window
    /// went, whose process ended or that waited too long; the rest stay held.
    pub(crate) fn answer_pending_gpu_binds(&mut self) {
        for held in self.gpu_pending_binds.take_all() {
            self.answer_gpu_bind(held.bind, Some(held.since));
        }
    }

    /// An X11 window was destroyed: the binds held for it are refused.
    pub(crate) fn refuse_pending_gpu_binds_of(&mut self, window: u32) {
        self.gpu_pending_binds.forget_window(window);
        for bind in self.gpu_pending_binds.take_window(window, None) {
            tracing::info!("held GPU X11 bind of {window:#x} by process {} refused: the window was destroyed", bind.pid);
            self.refuse_gpu_bind(bind.request);
        }
    }

    fn handle_gpu_record(&mut self, record: crate::gpu_control::Record) {
        use crate::gpu_control::Record;
        match record {
            Record::Bind(bind) => {
                if self.gpu_grants.as_mut().is_some_and(|grants| !grants.accept_bind_request(bind.request)) {
                    self.gpu_control_failed(); return;
                }
                self.answer_gpu_bind(bind, None);
            }
            Record::SurfaceRetired { epoch, grant, generation } => {
                if self.gpu_grants.as_mut().is_none_or(|grants| grants.surface_retired_by_identity(epoch, grant, generation).is_err()) {
                    self.gpu_control_failed();
                }
            }
            Record::RevokeRequest { epoch, grant, generation } => {
                let result = self.gpu_grants.as_mut().ok_or(()).and_then(|grants|
                    grants.request_revoke(epoch, grant, generation).map_err(|_| ()));
                match result {
                    Ok(Some(grant)) => if self.queue_gpu_revoke(grant).is_err() { self.gpu_control_failed(); },
                    Ok(None) => {},
                    Err(()) => self.gpu_control_failed(),
                }
            }
            Record::BufferReleased { request, status } => {
                // A release for a present already returned (all of them are on an executor
                // loss, before the broker's last answers for that executor arrive) is stale.
                let Some((window, held)) = self.remote_presents.released(request) else {
                    tracing::debug!("stale remote buffer release {request}");
                    return;
                };
                self.free_held(window, held);
                if status != 0 { self.stats.unshown += 1; }
                // A frame went to the phone: the application may draw the next one.
                self.release_paced_callbacks(window);
                // Rate-limited: the first few of each outcome, then every 1024th.
                static OUTCOMES: [std::sync::atomic::AtomicU64; 2] =
                    [std::sync::atomic::AtomicU64::new(0), std::sync::atomic::AtomicU64::new(0)];
                let n = OUTCOMES[usize::from(status != 0)].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if n < 16 || n % 1024 == 0 {
                    if status == 0 { tracing::info!("remote buffer shown {}", n + 1); }
                    else { tracing::info!("remote buffer present {request} not shown: errno {status} (unshown {})", n + 1); }
                }
            }
            Record::Lifecycle { kind, executor, generation } => {
                if kind == 5 { self.release_remote_presents(); }
                let Some(grants) = self.gpu_grants.as_mut() else { self.gpu_control_failed(); return };
                match kind {
                    4 => {
                        // The previous executor's lost or retired report may never come (it
                        // crossed a broker restart): a ready executor supersedes it.
                        if grants.epoch_if_ready().is_some() || grants.supersede().is_err() ||
                            grants.ready(executor, generation).is_err() { self.gpu_control_failed(); }
                        else {
                            self.reconnect_for_gpu_epoch();
                            // The phone's GPU is there: render on it.
                            self.rebuild_gpu();
                        }
                    }
                    5 => {
                        // A loss of an executor that is no longer the current one (already
                        // lost, or superseded) has nothing left to revoke.
                        let revokes = grants.lost(executor, generation).unwrap_or_else(|_| {
                            tracing::debug!("stale executor loss, generation {generation}");
                            Vec::new()
                        });
                        for grant in revokes {
                            if self.queue_gpu_revoke(grant).is_err() { self.gpu_control_failed(); return; }
                        }
                        self.reconnect_for_gpu_epoch();
                        // The phone's GPU is gone: render on the computer until it returns.
                        self.rebuild_gpu_after_loss();
                    }
                    11 | 12 => {
                        // 11: the phone suspended for longer than the broker holds the compositor;
                        // its streams were ended so a held call cannot block this thread. Draw on
                        // the computer alone meanwhile, so pictures (screenshots, the agents'
                        // tools) never depend on the phone. 12: it resumed; draw on it again.
                        match crate::present::renderer_move(kind, self.gpu.as_ref().map(|g| g.presents())) {
                            crate::present::RendererMove::Local => {
                                tracing::info!("executor suspended: rendering on the computer until it resumes");
                                self.render_locally();
                            }
                            crate::present::RendererMove::Phone => self.rebuild_gpu(),
                            crate::present::RendererMove::Keep => {}
                        }
                    }
                    6 => {
                        // A retirement for an executor a later ready already superseded is stale.
                        if grants.retired(executor, generation).is_err() {
                            tracing::debug!("stale executor retirement, generation {generation}");
                        }
                    }
                    _ => self.gpu_control_failed(),
                }
            }
        }
    }

    pub fn now_us(&self) -> u64 {
        Duration::from(self.clock.now()).as_micros() as u64
    }

    pub fn now_ms(&self) -> u32 {
        Duration::from(self.clock.now()).as_millis() as u32
    }

    pub fn next_serial(&self) -> Serial {
        SERIAL_COUNTER.next_serial()
    }

    pub fn keyboard_focus_surface(&self) -> Option<WlSurface> {
        self.seat.get_keyboard()?.current_focus()?.wl_surface().map(|s| s.into_owned())
    }

    /// The window that owns `surface` (its root surface, or a subsurface of it).
    pub fn window_of_surface(&self, surface: &WlSurface) -> Option<u64> {
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        self.windows.by_surface(&root)
    }

    fn is_mapped(surface: &WlSurface) -> bool {
        with_renderer_surface_state(surface, |s| s.buffer().is_some()).unwrap_or(false)
    }

    pub fn add_window(&mut self, surface: Surface, kind: WindowKind, parent: Option<u64>) -> u64 {
        let display = parent
            .and_then(|p| self.windows.get(p))
            .map(|p| p.display)
            .unwrap_or_else(|| self.displays.primary().info.id);
        let id = self.windows.insert(Window {
            id: 0,
            surface,
            parent,
            kind,
            display,
            position: (0, 0).into(),
            announced: None,
            picture: Default::default(),
            fullscreen: false,
            maximized: false,
            maximized_geometry: None,
            placed: false,
            lineage: None,
            desktop_id: None,
            icon: None,
            identified: false,
            held_min: None,
        });
        self.assign_output(id);
        if kind == WindowKind::Toplevel {
            self.bind_waiting_games();
        }
        id
    }

    pub fn remove_window(&mut self, id: u64) {
        for child in self.windows.descendants(id) {
            if let Some(w) = self.windows.get(child) {
                if let Surface::Popup(p) = &w.surface {
                    p.send_popup_done();
                }
            }
            self.forget_window(child);
        }
        self.forget_window(id);
    }

    fn forget_window(&mut self, id: u64) {
        let revoke = self.gpu_grants.as_mut().and_then(|grants| grants.begin_revoke(id));
        if let Some(grant) = revoke {
            if self.queue_gpu_revoke(grant).is_err() { self.gpu_control_failed(); }
        }
        let focused = self.focus_history.last() == Some(&id);
        // A popup takes the keyboard for its grab without becoming the focused window.
        let had_keyboard = self.focused_window() == Some(id);
        self.focus_history.retain(|f| *f != id);
        let Some(w) = self.windows.remove(id) else { return };
        // A touch on a closing surface (a menu, say) never gets its release; without a
        // cancel the application keeps that touch down and rejects every later one.
        if self.input.forget_window(id) {
            if let Some(touch) = self.seat.get_touch() {
                touch.cancel(self);
            }
            self.input.clear_touches();
        }
        // Closing the window that has the keyboard (a dialog, a transient surface, a menu
        // holding a grab) gives the keyboard back, as a desktop does: to the menu whose grab
        // is still open, else the window focused before it.
        let grab = self.input.popup_grab.filter(|g| *g != id && self.windows.get(*g).is_some());
        match keyboard_after_close(focused, had_keyboard, grab, self.focus_history.last().copied()) {
            KeyboardAfterClose::Keep => {}
            KeyboardAfterClose::Popup(popup) => {
                if let (Some(Surface::Popup(p)), Some(keyboard)) =
                    (self.windows.get(popup).map(|w| w.surface.clone()), self.seat.get_keyboard())
                {
                    let serial = self.next_serial();
                    keyboard.set_focus(self, Some(KeyboardFocus::Wayland(p.wl_surface().clone())), serial);
                }
            }
            KeyboardAfterClose::Window(previous) => {
                // Taken off the history as focus_window puts it back on top.
                self.focus_history.retain(|f| *f != previous);
                self.focus_window(previous);
            }
            KeyboardAfterClose::Nobody => {
                if let Some(keyboard) = self.seat.get_keyboard() {
                    let serial = self.next_serial();
                    keyboard.set_focus(self, None, serial);
                }
            }
        }
        self.game_window_gone(id);
        self.targets_window_gone(id);
        if w.announced.is_some() {
            if let Some(s) = &self.session {
                self.net.send(s.conn, &proto::Message::WindowDestroy { id });
            }
        }
    }

    /// Tells the window's surfaces which output they are on and the scale to render at.
    pub fn assign_output(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        let Some(root) = w.surface.wl_surface() else { return };
        let display = self.displays.resolve(Some(w.display));
        let output = display.output.clone();
        let scale = display.info.scale;
        let others: Vec<_> = self.displays.outputs().filter(|o| **o != output).cloned().collect();
        with_surface_tree_downward(
            &root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |surface, states, _| {
                for o in &others {
                    o.leave(surface);
                }
                output.enter(surface);
                smithay::wayland::compositor::send_surface_state(
                    surface,
                    states,
                    scale.ceil() as i32,
                    smithay::utils::Transform::Normal,
                );
                with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
            },
            |_, _, _| true,
        );
    }

    /// Sends the frame callbacks of a window's surfaces.
    pub fn release_frame_callbacks(&mut self, id: u64) {
        let time = self.now_ms();
        let (root, display, commit_us) = {
            let Some(w) = self.windows.get_mut(id) else { return };
            w.picture.callbacks_pending = false;
            let Some(root) = w.surface.wl_surface() else { return };
            (root, w.display, w.picture.commit_us)
        };
        // Releasing the frame callbacks is the seat's present of that commit:
        // it completes the latency entry of the input it answered.
        self.latency.present(id, commit_us, self.now_us());
        let output = self.displays.resolve(Some(display)).output.clone();
        let refresh_hz = self.displays.resolve(Some(display)).info.refresh_hz;
        self.present_seq += 1;
        let seq = self.present_seq;
        let refresh = smithay::wayland::presentation::Refresh::fixed(std::time::Duration::from_secs_f64(1.0 / refresh_hz.max(1.0)));
        let presented = std::time::Duration::from_micros(self.now_us());
        with_surface_tree_downward(
            &root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |_, states, _| {
                for callback in states.cached_state.get::<SurfaceAttributes>().current().frame_callbacks.drain(..) {
                    callback.done(time);
                }
                for feedback in std::mem::take(
                    &mut states.cached_state.get::<smithay::wayland::presentation::PresentationFeedbackCachedState>().current().callbacks,
                ) {
                    feedback.presented(
                        &output,
                        presented,
                        refresh,
                        seq,
                        smithay::reexports::wayland_protocols::wp::presentation_time::server::wp_presentation_feedback::Kind::Vsync,
                    );
                }
            },
            |_, _, _| true,
        );
    }

    /// Announces new windows and changes to known ones; retracts unmapped ones.
    /// Looks up, once, the desktop entry a toplevel's process was launched from. Other
    /// windows' processes bound it: one under a launched terminal's shell is not the terminal.
    fn find_desktop_id(&mut self, id: u64) {
        let toplevel = self.windows.get(id).is_some_and(|w| w.parent.is_none() && w.desktop_id.is_none());
        if !toplevel {
            return;
        }
        let dh = self.dh.clone();
        let mut windowed = std::collections::HashSet::new();
        for other in self.windows.ids() {
            if other == id {
                continue;
            }
            if let Some(w) = self.windows.get_mut(other) {
                let lineage = w.lineage.get_or_insert_with(|| crate::session::window_lineage(&dh, &w.surface));
                windowed.extend(lineage.first().copied());
            }
        }
        let Some(w) = self.windows.get_mut(id) else { return };
        // An X11 window may not name its process yet: look again at the next sync.
        if w.lineage.as_ref().is_none_or(|l| l.is_empty()) {
            w.lineage = Some(crate::session::window_lineage(&dh, &w.surface));
        }
        let lineage = w.lineage.clone().unwrap_or_default();
        if lineage.is_empty() {
            return;
        }
        let found = crate::launch::desktop_id(&lineage, &windowed, crate::launch::read_environ);
        if let Some(desktop) = &found {
            tracing::info!("window {id}: launched from {desktop}");
        }
        w.desktop_id = Some(found);
    }

    pub fn sync_windows(&mut self) {
        self.hints.prune();
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        for id in self.windows.parent_first() {
            self.identify_x11(id);
            self.find_desktop_id(id);
            let Some(w) = self.windows.get(id) else { continue };
            // A Vulkan application bound to its phone surface may never commit a buffer here:
            // its window is shown once it has a grant.
            let virtual_window = self.gpu_grants.as_ref().is_some_and(|grants| grants.client_surface(id)) &&
                self.session.as_ref().is_some_and(|session| session.owner_displays.contains(&w.display));
            let mapped = w.surface.wl_surface().is_some_and(|s| Self::is_mapped(&s)) || virtual_window;
            let parent_announced = w.parent.is_none_or(|p| self.windows.get(p).is_some_and(|p| p.announced.is_some()));
            if !mapped || !parent_announced {
                if w.announced.is_some() {
                    self.window_withdrawn(id);
                    self.net.send(conn, &proto::Message::WindowDestroy { id });
                    self.windows.get_mut(id).unwrap().announced = None;
                }
                continue;
            }
            let Some(mut now) = self.windows.describe(id, &self.displays) else { continue };
            (now.idle_inhibit, now.content_type, now.keys_grabbed) = self.window_hints(id);
            if virtual_window && w.surface.wl_surface().is_some_and(|s| !Self::is_mapped(&s)) {
                let Surface::Toplevel(toplevel) = &w.surface else { continue };
                let Some(size) = toplevel.with_pending_state(|state| state.size) else { continue };
                let Some(display) = self.displays.get(w.display) else { continue };
                let Some((width, height)) = virtual_target_pixels(size.w, size.h, display.info.scale) else { continue };
                now.geometry.w = width;
                now.geometry.h = height;
            }
            match &w.announced {
                None => {
                    self.net.send(conn, &proto::Message::WindowCreate(now.clone()));
                    let w = self.windows.get_mut(id).unwrap();
                    w.announced = Some(now);
                    // The client has nothing of it yet: its picture is presented whole.
                    w.picture.repaint();
                    self.window_announced(id);
                }
                Some(before) => {
                    let update = crate::windows::diff(before, &now);
                    if !update.is_empty() {
                        self.net.send(conn, &proto::Message::WindowUpdate(update));
                        self.windows.get_mut(id).unwrap().announced = Some(now);
                    }
                }
            }
        }
        self.sync_children();
    }

    pub fn on_text_input_toggle(&mut self, toggle: Toggle) {
        let Some(id) = self.window_of_surface(&toggle.surface) else { return };
        tracing::debug!("text input: window {id} {} ({:?})", if toggle.enabled { "on" } else { "off" }, toggle.purpose);
        if let Some(s) = self.session.as_ref().filter(|s| s.ready) {
            let conn = s.conn;
            self.net.send(
                conn,
                &proto::Message::TextInput(proto::TextInputState {
                    id,
                    enabled: toggle.enabled,
                    purpose: toggle.purpose.map(str::to_owned),
                    surrounding: toggle.surrounding.as_ref().map(crate::text_input::Surrounding::wire),
                }),
            );
        }
    }

    /// Runs after every batch of events: announce, render, present, flush.
    pub fn tick(&mut self) {
        self.sync_windows();
        let started = input_trace().then(monotonic_us);
        self.render_windows();
        if let Some(started) = started {
            let took = monotonic_us() - started;
            if took >= 4000 {
                eprintln!("CABOOSE_INPUT_TRACE kind=render started_us={started} took_us={took}");
            }
        }
        if let Err(e) = self.dh.flush_clients() {
            tracing::warn!("flushing Wayland clients: {e}");
        }
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}

/// CLOCK_MONOTONIC in microseconds: the clock of the input trace, comparable across the
/// computer's processes.
pub(crate) fn monotonic_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes one timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000
}

/// `CABOOSE_DISPLAY_INPUT_TRACE=1`: log when each phone scroll arrives and reaches
/// applications, and main-loop rendering that holds input back.
pub(crate) fn input_trace() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CABOOSE_DISPLAY_INPUT_TRACE").is_some_and(|v| v == "1"))
}

fn virtual_target_pixels(width: i32, height: i32, scale: f64) -> Option<(i32, i32)> {
    if width <= 0 || height <= 0 || !scale.is_finite() || scale <= 0.0 { return None; }
    let (w, h) = ((width as f64 * scale).round(), (height as f64 * scale).round());
    if w < 1.0 || h < 1.0 || w > i32::MAX as f64 || h > i32::MAX as f64 { return None; }
    Some((w as i32, h as i32))
}

fn is_explicit_buffer_detach(buffer: Option<&BufferAssignment>) -> bool {
    matches!(buffer, Some(BufferAssignment::Removed))
}

/// Whether an X11 window can be bound to a phone surface: a top-level window, or an
/// override-redirect one (a menu, tooltip or dropdown, shown as a popup over its parent).
fn gpu_bindable_x11(top_level: bool, override_redirect: bool, alive: bool) -> bool {
    alive && (override_redirect || top_level)
}

/// Where the keyboard goes when a window closes.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum KeyboardAfterClose {
    /// The closing window did not have it.
    Keep,
    /// To the popup whose grab is still open (a parent menu).
    Popup(u64),
    /// To the window focused before.
    Window(u64),
    /// No window is left to take it.
    Nobody,
}

/// `focused`: the closing window was the focused one; `had_keyboard`: it held the keyboard
/// (a popup's grab gives it the keyboard without focusing it); `grab`: a popup grab still
/// open after it closes; `previous`: the most recently focused window left.
pub(crate) fn keyboard_after_close(
    focused: bool,
    had_keyboard: bool,
    grab: Option<u64>,
    previous: Option<u64>,
) -> KeyboardAfterClose {
    if !focused && !had_keyboard {
        return KeyboardAfterClose::Keep;
    }
    if let (false, Some(popup)) = (focused, grab) {
        return KeyboardAfterClose::Popup(popup);
    }
    match previous {
        Some(previous) => KeyboardAfterClose::Window(previous),
        None => KeyboardAfterClose::Nobody,
    }
}

#[cfg(test)]
mod keyboard_after_close_tests {
    use super::{keyboard_after_close, KeyboardAfterClose::*};

    #[test]
    fn closing_a_window_without_the_keyboard_leaves_it() {
        assert_eq!(keyboard_after_close(false, false, None, Some(1)), Keep);
        assert_eq!(keyboard_after_close(false, false, Some(3), Some(1)), Keep);
    }

    #[test]
    fn a_closed_dialog_gives_it_to_the_window_focused_before() {
        assert_eq!(keyboard_after_close(true, true, None, Some(1)), Window(1));
        assert_eq!(keyboard_after_close(true, false, None, Some(1)), Window(1));
        assert_eq!(keyboard_after_close(true, true, None, None), Nobody);
    }

    #[test]
    fn a_closed_menu_gives_it_back_to_its_window() {
        // The menu's grab gave it the keyboard; its window is still the focused one.
        assert_eq!(keyboard_after_close(false, true, None, Some(1)), Window(1));
        assert_eq!(keyboard_after_close(false, true, None, None), Nobody);
    }

    #[test]
    fn a_closed_submenu_gives_it_to_the_menu_still_open() {
        assert_eq!(keyboard_after_close(false, true, Some(4), Some(1)), Popup(4));
    }
}

#[cfg(test)]
mod gpu_detach_tests {
    use super::{gpu_bindable_x11, is_explicit_buffer_detach, virtual_target_pixels, BufferAssignment};

    #[test]
    fn popups_and_top_level_x11_windows_get_phone_surfaces() {
        assert!(gpu_bindable_x11(true, false, true));
        assert!(gpu_bindable_x11(false, true, true), "an override-redirect menu, tooltip or dropdown");
        assert!(!gpu_bindable_x11(false, false, true), "a child window binds through its top-level window");
        assert!(!gpu_bindable_x11(true, false, false));
        assert!(!gpu_bindable_x11(false, true, false));
    }

    #[test]
    fn only_explicit_null_buffer_is_a_detach() {
        assert!(!is_explicit_buffer_detach(None));
        assert!(is_explicit_buffer_detach(Some(&BufferAssignment::Removed)));
    }
    #[test]
    fn virtual_target_requires_a_real_positive_configure() {
        assert_eq!(virtual_target_pixels(640, 360, 1.5), Some((960, 540)));
        for (w, h, scale) in [(0, 360, 1.0), (640, 0, 1.0), (640, 360, 0.0), (640, 360, f64::NAN)] {
            assert_eq!(virtual_target_pixels(w, h, scale), None);
        }
    }
}

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        if let Some(state) = client.get_data::<smithay::xwayland::XWaylandClientData>() {
            return &state.compositor_state;
        }
        &client.get_data::<ClientState>().unwrap().compositor
    }

    fn commit(&mut self, surface: &WlSurface) {
        // Smithay's renderer consumes this assignment, so inspect it first.
        // A missing buffer assignment is not an explicit unmap.
        let detached = smithay::wayland::compositor::with_states(surface, |states| {
            is_explicit_buffer_detach(states.cached_state.get::<SurfaceAttributes>().current().buffer.as_ref())
        });
        // Surfaces of this tree with a new buffer: this one, and synchronized subsurfaces
        // whose state this commit applied.
        let mut new_buffers = Vec::new();
        with_surface_tree_downward(surface, (), |_, _, _| TraversalAction::DoChildren(()), |child, states, _| {
            if matches!(states.cached_state.get::<SurfaceAttributes>().current().buffer, Some(BufferAssignment::NewBuffer(_))) {
                new_buffers.push(child.clone());
            }
        }, |_, _, _| true);
        if detached {
            if let Some(id) = self.windows.by_surface(surface) {
                let revoke = self.gpu_grants.as_mut().and_then(|grants| grants.begin_revoke(id));
                if let Some(grant) = revoke {
                    if self.queue_gpu_revoke(grant).is_err() { self.gpu_control_failed(); }
                }
            }
        }
        on_commit_buffer_handler::<Self>(surface);
        for fresh in &new_buffers {
            self.present_remote_buffer(fresh);
        }
        // xdg surfaces get their initial configure on their first commit.
        if let Some(id) = self.windows.by_surface(surface) {
            match &self.windows.get(id).unwrap().surface {
                Surface::Toplevel(t) => {
                    if !t.is_initial_configure_sent() {
                        t.send_configure();
                    }
                }
                Surface::Popup(p) => {
                    if !p.is_initial_configure_sent() {
                        let _ = p.send_configure();
                    }
                }
                Surface::X11(_) => {}
            }
        }
        if is_sync_subsurface(surface) {
            return;
        }
        if let Some(id) = self.window_of_surface(surface) {
            let now = self.now_us();
            let new_children = self.windows.get(id).is_some_and(|w| w.surface.wl_surface().as_ref() != Some(surface));
            // A window whose tree is one phone-resident buffer covering it shows that buffer;
            // any other is rendered by the compositor.
            let source = if self.covered_by_remote_buffer(id) { crate::picture::Source::Direct } else { crate::picture::Source::Composed };
            if let Some(w) = self.windows.get_mut(id) {
                w.picture.mark_dirty(now);
                w.picture.source = source;
            }
            self.latency.commit(id, now);
            if new_children {
                self.assign_output(id);
            }
        }
    }

    fn new_subsurface(&mut self, _surface: &WlSurface, parent: &WlSurface) {
        if let Some(id) = self.window_of_surface(parent) {
            self.assign_output(id);
        }
    }
}

impl ShmHandler for State {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl DmabufHandler for State {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf
    }

    fn dmabuf_imported(&mut self, _global: &DmabufGlobal, dmabuf: Dmabuf, notifier: ImportNotifier) {
        // A remote buffer's pixels are on the phone: nothing here can map them.
        let ok = if crate::remote_buffers::is_remote(&dmabuf) {
            crate::remote_buffers::identity(&dmabuf).is_some()
        } else {
            self.gpu.as_mut().is_some_and(|gpu| gpu.import_dmabuf(&dmabuf))
        };
        if ok {
            let _ = notifier.successful::<State>();
        } else {
            notifier.failed();
        }
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        // Window decorations belong to the phone; the client's own are not wanted.
        surface.with_pending_state(|s| s.decoration_mode = Some(DecorationMode::ServerSide));
        let parent = surface.parent().and_then(|p| self.windows.by_surface(&p));
        let kind = if parent.is_some() { WindowKind::Dialog } else { WindowKind::Toplevel };
        let id = self.add_window(Surface::Toplevel(surface), kind, parent);
        self.focus_window(id);
    }

    fn new_popup(&mut self, surface: PopupSurface, positioner: PositionerState) {
        let parent = surface.get_parent_surface().and_then(|p| self.windows.by_surface(&p));
        let id = self.add_window(Surface::Popup(surface.clone()), WindowKind::Popup, parent);
        self.place_popup(id, &positioner);
    }

    fn reposition_request(&mut self, surface: PopupSurface, positioner: PositionerState, token: u32) {
        if let Some(id) = self.windows.by_popup(&surface) {
            self.place_popup(id, &positioner);
            surface.send_repositioned(token);
        }
    }

    fn grab(&mut self, surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {
        if let Some(id) = self.windows.by_popup(&surface) {
            self.input.popup_grab = Some(id);
            if let Some(keyboard) = self.seat.get_keyboard() {
                let serial = self.next_serial();
                keyboard.set_focus(self, Some(KeyboardFocus::Wayland(surface.wl_surface().clone())), serial);
            }
        }
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            self.remove_window(id);
        }
    }

    fn popup_destroyed(&mut self, surface: PopupSurface) {
        if let Some(id) = self.windows.by_popup(&surface) {
            if self.input.popup_grab == Some(id) {
                self.input.popup_grab = self
                    .windows
                    .get(id)
                    .and_then(|w| w.parent)
                    .filter(|p| self.windows.get(*p).is_some_and(|w| matches!(w.surface, Surface::Popup(_))));
            }
            self.remove_window(id);
        }
    }

    fn parent_changed(&mut self, surface: ToplevelSurface) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            let parent = surface.parent().and_then(|p| self.windows.by_surface(&p));
            if let Some(w) = self.windows.get_mut(id) {
                w.parent = parent;
                w.kind = if parent.is_some() { WindowKind::Dialog } else { WindowKind::Toplevel };
            }
        }
    }

    fn title_changed(&mut self, _surface: ToplevelSurface) {}
    fn app_id_changed(&mut self, _surface: ToplevelSurface) {}

    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        _output: Option<smithay::reexports::wayland_server::protocol::wl_output::WlOutput>,
    ) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            self.configure_window(&proto::Configure { id, fullscreen: Some(true), ..Default::default() });
        }
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            self.configure_window(&proto::Configure { id, fullscreen: Some(false), ..Default::default() });
        }
    }

    fn maximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            self.configure_window(&proto::Configure { id, maximized: Some(true), ..Default::default() });
        }
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(id) = self.windows.by_toplevel(&surface) {
            self.configure_window(&proto::Configure { id, maximized: Some(false), ..Default::default() });
        }
    }
}

impl State {
    /// Positions a popup from its positioner, kept inside its display.
    fn place_popup(&mut self, id: u64, positioner: &PositionerState) {
        let Some(w) = self.windows.get(id) else { return };
        let Surface::Popup(popup) = &w.surface else { return };
        let popup = popup.clone();
        let parent_origin = w.parent.map(|p| self.windows.logical_origin(p, &self.displays)).unwrap_or_default();
        let display = self.displays.resolve(Some(w.display)).logical_rect();
        let target = smithay::utils::Rectangle::new(display.loc - parent_origin, display.size);
        let geometry = positioner.get_unconstrained_geometry(target);
        popup.with_pending_state(|s| {
            s.geometry = geometry;
            s.positioner = *positioner;
        });
        if popup.is_initial_configure_sent() {
            let _ = popup.send_pending_configure();
        }
    }

    /// Gives a window the keyboard on request (the control socket's `focus`). A window that
    /// already has it is deactivated and given it again, so the client sees its window lose
    /// and regain both activation and the keyboard: one that ignored its first activation (sent
    /// while its window was being made) takes the keyboard now.
    pub fn refocus_window(&mut self, id: u64) {
        if self.windows.get(id).is_none() {
            return;
        }
        if self.focused_window() == Some(id) {
            self.deactivate_window(id);
            if let Some(keyboard) = self.seat.get_keyboard() {
                let serial = self.next_serial();
                keyboard.set_focus(self, None, serial);
            }
        }
        self.focus_window(id);
    }

    /// Tells a window it is no longer the active one.
    fn deactivate_window(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        match &w.surface {
            Surface::Toplevel(t) => {
                let changed = t.with_pending_state(|s| {
                    s.states.unset(smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State::Activated)
                });
                if changed && t.is_initial_configure_sent() {
                    t.send_pending_configure();
                }
            }
            Surface::X11(x) => {
                let _ = x.set_activated(false);
            }
            Surface::Popup(_) => {}
        }
    }

    pub fn focus_window(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        self.focus_history.retain(|f| *f != id);
        self.focus_history.push(id);
        let focus = match &w.surface {
            Surface::Toplevel(t) => KeyboardFocus::Wayland(t.wl_surface().clone()),
            Surface::Popup(p) => KeyboardFocus::Wayland(p.wl_surface().clone()),
            Surface::X11(x) => KeyboardFocus::X11(x.clone()),
        };
        let Some(keyboard) = self.seat.get_keyboard() else { return };
        if keyboard.current_focus().as_ref() == Some(&focus) {
            return;
        }
        // Activation state follows focus.
        for other in self.windows.iter() {
            match &other.surface {
                Surface::Toplevel(t) if other.id != id => {
                    let changed = t.with_pending_state(|s| {
                        s.states.unset(
                            smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State::Activated,
                        )
                    });
                    if changed && t.is_initial_configure_sent() {
                        t.send_pending_configure();
                    }
                }
                Surface::X11(x) if other.id != id => {
                    let _ = x.set_activated(false);
                }
                _ => {}
            }
        }
        match &w.surface {
            Surface::Toplevel(t) => {
                t.with_pending_state(|s| {
                    s.states
                        .set(smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State::Activated)
                });
                if t.is_initial_configure_sent() {
                    t.send_pending_configure();
                }
            }
            Surface::X11(x) => {
                let _ = x.set_activated(true);
            }
            Surface::Popup(_) => {}
        }
        tracing::info!("keyboard focus: window {id}");
        let serial = self.next_serial();
        keyboard.set_focus(self, Some(focus), serial);
    }
}

// The global default removes GTK's automatic titlebar. A Client request means
// the app supplies its own header widgets; acknowledge it instead of looping or
// stripping useful application controls.
impl KdeDecorationHandler for State {
    fn kde_decoration_state(&self) -> &KdeDecorationState {
        &self.kde_decoration
    }
}

impl XdgDecorationHandler for State {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(DecorationMode::ServerSide));
        if toplevel.is_initial_configure_sent() {
            toplevel.send_pending_configure();
        }
    }
    fn request_mode(&mut self, toplevel: ToplevelSurface, _mode: DecorationMode) {
        XdgDecorationHandler::new_decoration(self, toplevel);
    }
    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        XdgDecorationHandler::new_decoration(self, toplevel);
    }
}

impl FractionalScaleHandler for State {
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        if let Some(id) = self.window_of_surface(&surface) {
            self.assign_output(id);
        }
    }
}

impl SeatHandler for State {
    type KeyboardFocus = KeyboardFocus;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<State> {
        &mut self.seat_state
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&KeyboardFocus>) {
        self.sync_x11_foreground(focused);
        let surface = focused.and_then(|f| f.wl_surface()).map(|s| s.into_owned());
        let client = surface.as_ref().and_then(|s| self.dh.get_client(s.id()).ok());
        set_data_device_focus(&self.dh, seat, client.clone());
        set_primary_focus(&self.dh, seat, client);
        for toggle in self.text_inputs.set_focus(surface.as_ref()) {
            self.on_text_input_toggle(toggle);
        }
        self.sync_ibus_focus_to(surface);
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        let name = match image {
            CursorImageStatus::Hidden => "none".to_owned(),
            CursorImageStatus::Named(icon) => icon.name().to_owned(),
            // Surface cursors are not streamed yet; the client keeps a pointer arrow.
            CursorImageStatus::Surface(_) => "default".to_owned(),
        };
        let message = proto::Message::CursorNamed { name };
        if self.cursor.as_ref() == Some(&message) {
            return;
        }
        if let Some(s) = self.session.as_ref().filter(|s| s.ready) {
            let conn = s.conn;
            self.net.send(conn, &message);
        }
        self.cursor = Some(message);
    }
}

impl SelectionHandler for State {
    type SelectionUserData = crate::clipboard::Owner;

    fn new_selection(&mut self, ty: SelectionTarget, source: Option<SelectionSource>, _seat: Seat<Self>) {
        self.clipboard_from_wayland(ty, source);
    }

    fn send_selection(
        &mut self,
        ty: SelectionTarget,
        mime_type: String,
        fd: std::os::fd::OwnedFd,
        _seat: Seat<Self>,
        owner: &crate::clipboard::Owner,
    ) {
        match owner {
            // An offer bound to an older selection gives nothing: dropping the
            // descriptor is the refusal, so a stale offer cannot read a later copy.
            crate::clipboard::Owner::Phone(offer) => {
                if offer.is_current(self.clipboard.generation) {
                    offer.send(&mime_type, fd);
                }
            }
            crate::clipboard::Owner::X11(generation) => {
                if *generation != self.clipboard.generation {
                    return;
                }
                // Smithay's window manager transfers text; other types are read directly.
                if ty == SelectionTarget::Clipboard && !crate::x11sel::smithay_transfers(&mime_type) {
                    if let Some(access) = self.x11.clone() {
                        crate::x11sel::copy_into(
                            access,
                            mime_type,
                            fd,
                            crate::clipboard::X11_LIMIT,
                            crate::clipboard::X11_TIMEOUT,
                        );
                    }
                    return;
                }
                let handle = self.handle.clone();
                if let Some(xwm) = self.xwm.as_mut() {
                    if let Err(e) = xwm.send_selection(ty, mime_type, fd, handle) {
                        tracing::debug!("X11 selection: {e}");
                    }
                }
            }
        }
    }
}

impl DataDeviceHandler for State {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device
    }
}

impl ClientDndGrabHandler for State {
    fn started(&mut self, source: Option<WlDataSource>, _icon: Option<WlSurface>, _seat: Seat<Self>) {
        self.drag_started(source);
    }

    fn dropped(&mut self, _target: Option<WlSurface>, _validated: bool, _seat: Seat<Self>) {
        self.drag_ended();
    }
}

/// The compositor's own drag, which carries a drop from the phone (see `dnd.rs`).
impl ServerDndGrabHandler for State {
    fn accept(&mut self, mime_type: Option<String>, _seat: Seat<Self>) {
        self.drop_accepted(mime_type);
    }

    fn action(&mut self, action: DndAction, _seat: Seat<Self>) {
        self.drop_action(action);
    }

    fn cancelled(&mut self, _seat: Seat<Self>) {
        self.drop_cancelled();
    }

    fn send(&mut self, mime_type: String, fd: std::os::fd::OwnedFd, _seat: Seat<Self>) {
        self.drop_send(mime_type, fd);
    }

    fn finished(&mut self, _seat: Seat<Self>) {
        self.drop_finished();
    }
}

impl PrimarySelectionHandler for State {
    fn primary_selection_state(&self) -> &PrimarySelectionState {
        &self.primary_selection
    }
}

impl OutputHandler for State {}

impl XWaylandShellHandler for State {
    fn xwayland_shell_state(&mut self) -> &mut XWaylandShellState {
        &mut self.xwayland_shell
    }

    /// Xwayland's first commit to the surface is seen before the surface is the window's:
    /// that commit's frame callback is the window's to release, or Xwayland never commits
    /// what the X11 client draws next.
    fn surface_associated(&mut self, _xwm: smithay::xwayland::xwm::XwmId, _surface: WlSurface, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            let now = self.now_us();
            if let Some(w) = self.windows.get_mut(id) {
                w.picture.mark_dirty(now);
            }
            self.latency.commit(id, now);
        }
    }
}

impl smithay::wayland::tablet_manager::TabletSeatHandler for State {}

smithay::delegate_compositor!(State);
smithay::delegate_presentation!(State);
smithay::delegate_shm!(State);
smithay::delegate_dmabuf!(State);
smithay::delegate_xdg_shell!(State);
smithay::delegate_xdg_decoration!(State);
smithay::delegate_kde_decoration!(State);
smithay::delegate_seat!(State);
smithay::delegate_relative_pointer!(State);
smithay::delegate_pointer_constraints!(State);

impl smithay::wayland::pointer_constraints::PointerConstraintsHandler for State {
    /// A constraint on the surface the pointer is over takes effect at once; one on
    /// another surface when the pointer enters it (input.rs).
    fn new_constraint(&mut self, surface: &WlSurface, pointer: &smithay::input::pointer::PointerHandle<Self>) {
        if pointer.current_focus().as_ref() == Some(surface) {
            crate::input::activate_constraint(surface, pointer);
        }
    }

    /// The client's cursor position while locked: the phone draws no cursor for it.
    fn cursor_position_hint(
        &mut self,
        _surface: &WlSurface,
        _pointer: &smithay::input::pointer::PointerHandle<Self>,
        _location: smithay::utils::Point<f64, smithay::utils::Logical>,
    ) {
    }
}
smithay::delegate_data_device!(State);
smithay::delegate_pointer_gestures!(State);
smithay::delegate_primary_selection!(State);
smithay::delegate_output!(State);
smithay::delegate_viewporter!(State);
smithay::delegate_fractional_scale!(State);
smithay::delegate_cursor_shape!(State);
smithay::delegate_tablet_manager!(State);
smithay::delegate_xwayland_shell!(State);
/// Whether a subsurface's buffer, at its position relative to its root surface, covers
/// `geometry` (in the root's surface coordinates).
pub(crate) fn covers_geometry(surface: &WlSurface, geometry: smithay::utils::Rectangle<i32, smithay::utils::Logical>) -> bool {
    use smithay::wayland::compositor::{with_states, SubsurfaceCachedState};
    let Some(size) = with_renderer_surface_state(surface, |state| state.surface_size()).flatten() else { return false };
    let mut location = smithay::utils::Point::<i32, smithay::utils::Logical>::from((0, 0));
    let mut current = surface.clone();
    while let Some(parent) = get_parent(&current) {
        location += with_states(&current, |states| states.cached_state.get::<SubsurfaceCachedState>().current().location);
        current = parent;
    }
    smithay::utils::Rectangle::new(location, size).contains_rect(geometry)
}
