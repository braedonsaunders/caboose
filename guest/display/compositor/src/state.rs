//! The compositor's state and the Wayland protocol handlers.

use crate::config::Config;
use crate::displays::Displays;
use crate::encode::Encoders;
use crate::input::InputState;
use crate::net::{HasNet, Net, NetEvent};
use crate::render::Renderer;
use crate::session::Session;
use crate::stream::{Done, Stream};
use crate::text_input::{TextInputs, Toggle};
use crate::windows::{Surface, Window, Windows};
use caboose_display_protocol::{self as proto, WindowKind};
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::renderer::utils::{on_commit_buffer_handler, with_renderer_surface_state};
use smithay::backend::renderer::ImportDma;
use smithay::input::keyboard::{KeyboardTarget, KeysymHandle, ModifiersState};
use smithay::input::pointer::CursorImageStatus;
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::reexports::calloop::channel::Sender;
use smithay::reexports::calloop::{LoopHandle, LoopSignal};
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode as DecorationMode;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_seat, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{Client, DisplayHandle, Resource};
use smithay::utils::{Clock, IsAlive, Monotonic, Serial, SERIAL_COUNTER};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    get_parent, is_sync_subsurface, with_surface_tree_downward, CompositorClientState, CompositorHandler,
    CompositorState, SurfaceAttributes, TraversalAction,
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
}

impl ClientData for ClientState {
    fn initialized(&self, _: ClientId) {}
    fn disconnected(&self, _: ClientId, _: DisconnectReason) {}
}

/// Counters the probe and logs report.
#[derive(Default, Debug, Clone)]
pub struct Stats {
    pub frames: u64,
    pub bytes: u64,
    pub renders: u64,
    /// Renders that copied a shm buffer instead of composing.
    pub direct: u64,
    pub unchanged_renders: u64,
    /// Main-thread time spent rendering windows into their pictures.
    pub render_us: u64,
    /// Encoder-thread CPU time.
    pub encode_cpu_us: u64,
    /// Pixels re-encoded vs pixels in the pictures sent.
    pub damaged_px: u64,
    pub picture_px: u64,
    /// Pictures that only sharpened unchanged content.
    pub refines: u64,
    /// Pictures of motion regions (video.frame).
    pub motion_frames: u64,
    /// Updates sent as tiles instead of a picture, and the tiles.
    pub tile_pictures: u64,
    pub tiles: u64,
    /// Scrolls sent as a copy within the client's picture (with their tiles).
    pub copies: u64,
}

impl Stats {
    pub fn summary(&self) -> String {
        let per = |v: u64| if self.frames > 0 { v as f64 / self.frames as f64 / 1000.0 } else { 0.0 };
        format!(
            "{} frames ({} sharpening) + {} motion frames + {} updates as {} tiles + {} scrolls as copies, {} kB, {} renders ({} direct from shm, {} unchanged), {:.0}% of pixels damaged; per frame: render {:.2} ms, encode {:.2} ms CPU on the worker thread (not counting x264's own threads)",
            self.frames,
            self.refines,
            self.motion_frames,
            self.tile_pictures,
            self.tiles,
            self.copies,
            self.bytes / 1000,
            self.renders,
            self.direct,
            self.unchanged_renders,
            100.0 * self.damaged_px as f64 / self.picture_px.max(1) as f64,
            per(self.render_us),
            per(self.encode_cpu_us)
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
    pub primary_selection: PrimarySelectionState,
    pub xwayland_shell: XWaylandShellState,
    pub seat: Seat<State>,
    pub xwm: Option<X11Wm>,
    pub x11_foreground: Option<crate::x11_focus::Foreground>,
    pub text_inputs: TextInputs,

    pub windows: Windows,
    pub displays: Displays,
    pub renderer: Renderer,
    pub encoders: Encoders,
    pub net: Net,
    pub session: Option<Session>,
    pub done_tx: Sender<Done>,
    pub input: InputState,
    /// Windows in the order they were focused, most recent last.
    pub focus_history: Vec<u64>,
    pub videos: crate::video::server::Videos,
    pub games: crate::game::Games,
    pub control: crate::control::Control,
    pub clipboard: crate::clipboard::Clipboard,
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
    pub stats: Stats,
    /// The cursor last sent, so it is re-sent to a new client.
    pub cursor: Option<proto::Message>,
    /// The wake-up for the next refinement: when (monotonic µs), and its timer.
    pub refine_timer: Option<(u64, smithay::reexports::calloop::RegistrationToken)>,
}

impl HasNet for State {
    fn net(&mut self) -> &mut Net {
        &mut self.net
    }
    fn loop_handle(&self) -> LoopHandle<'static, Self> {
        self.handle.clone()
    }
    fn on_net_events(&mut self, events: Vec<NetEvent>) {
        for event in events {
            self.on_net_event(event);
        }
    }
}

impl State {
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
            stream: Stream::default(),
            fullscreen: false,
            maximized: false,
            lineage: None,
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
        let focused = self.focus_history.last() == Some(&id);
        self.focus_history.retain(|f| *f != id);
        let Some(w) = self.windows.remove(id) else { return };
        self.input.forget_window(id);
        // Closing the focused window (a dialog, a transient surface) gives focus back to
        // the window focused before it, as a desktop does.
        if focused {
            if let Some(previous) = self.focus_history.pop() {
                self.focus_window(previous);
            } else if let Some(keyboard) = self.seat.get_keyboard() {
                let serial = self.next_serial();
                keyboard.set_focus(self, None, serial);
            }
        }
        self.video_window_gone(id);
        self.game_window_gone(id);
        if w.announced.is_some() {
            if let Some(s) = &self.session {
                let conn = s.conn;
                if let Some(m) = &w.stream.motion {
                    self.net.send(conn, &proto::Message::VideoDestroy { id: m.id });
                }
                self.net.send(conn, &proto::Message::WindowDestroy { id });
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
        let Some(w) = self.windows.get_mut(id) else { return };
        w.stream.callbacks_pending = false;
        let Some(root) = w.surface.wl_surface() else { return };
        with_surface_tree_downward(
            &root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |_, states, _| {
                for callback in states.cached_state.get::<SurfaceAttributes>().current().frame_callbacks.drain(..) {
                    callback.done(time);
                }
            },
            |_, _, _| true,
        );
    }

    /// Announces new windows and changes to known ones; retracts unmapped ones.
    pub fn sync_windows(&mut self) {
        let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) else { return };
        for id in self.windows.parent_first() {
            let Some(w) = self.windows.get(id) else { continue };
            // A Vulkan application whose stream the client renders never presents here, so its
            // X11 window is shown once X maps it, without a buffer (docs/gpu-stream.md).
            let mapped = w.surface.wl_surface().is_some_and(|s| Self::is_mapped(&s)) || self.streams_unbuffered(id);
            let parent_announced = w.parent.is_none_or(|p| self.windows.get(p).is_some_and(|p| p.announced.is_some()));
            if !mapped || !parent_announced {
                if w.announced.is_some() {
                    if let Some(m) = &w.stream.motion {
                        self.net.send(conn, &proto::Message::VideoDestroy { id: m.id });
                    }
                    self.window_withdrawn(id);
                    self.net.send(conn, &proto::Message::WindowDestroy { id });
                    let w = self.windows.get_mut(id).unwrap();
                    w.announced = None;
                    w.stream.in_flight.clear();
                    w.stream.motion = None;
                    w.stream.tracker = None;
                }
                continue;
            }
            let Some(now) = self.windows.describe(id, &self.displays) else { continue };
            match &w.announced {
                None => {
                    self.net.send(conn, &proto::Message::WindowCreate(now.clone()));
                    let w = self.windows.get_mut(id).unwrap();
                    w.announced = Some(now);
                    w.stream.need_keyframe = true;
                    w.stream.dirty = true;
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
    }

    pub fn on_text_input_toggle(&mut self, toggle: Toggle) {
        let Some(id) = self.window_of_surface(&toggle.surface) else { return };
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

    /// Runs after every batch of events: announce, render, encode, flush.
    pub fn tick(&mut self) {
        self.sync_windows();
        self.render_streams();
        if let Err(e) = self.dh.flush_clients() {
            tracing::warn!("flushing Wayland clients: {e}");
        }
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
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
        on_commit_buffer_handler::<Self>(surface);
        let Renderer::Pixman(r) = &mut self.renderer;
        // Import now so a client's shm buffer is released as early as possible.
        let _ = smithay::backend::renderer::utils::import_surface_tree(r, surface);
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
            if let Some(w) = self.windows.get_mut(id) {
                w.stream.mark_dirty(now);
            }
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
        let ok = match &mut self.renderer {
            Renderer::Pixman(r) => r.import_dmabuf(&dmabuf, None).is_ok(),
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
            crate::clipboard::Owner::Phone(data) => crate::clipboard::write_to(fd, data.clone()),
            crate::clipboard::Owner::X11 => {
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

impl ClientDndGrabHandler for State {}
impl ServerDndGrabHandler for State {}

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
}

impl smithay::wayland::tablet_manager::TabletSeatHandler for State {}

smithay::delegate_compositor!(State);
smithay::delegate_shm!(State);
smithay::delegate_dmabuf!(State);
smithay::delegate_xdg_shell!(State);
smithay::delegate_xdg_decoration!(State);
smithay::delegate_kde_decoration!(State);
smithay::delegate_seat!(State);
smithay::delegate_relative_pointer!(State);
smithay::delegate_data_device!(State);
smithay::delegate_primary_selection!(State);
smithay::delegate_output!(State);
smithay::delegate_viewporter!(State);
smithay::delegate_fractional_scale!(State);
smithay::delegate_cursor_shape!(State);
smithay::delegate_tablet_manager!(State);
smithay::delegate_xwayland_shell!(State);
