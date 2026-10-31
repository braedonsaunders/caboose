//! Input from the client into the seat: pointer, touch, keys and text. Every event names
//! the window it is for and a window-local position in display pixels; it is turned
//! into the logical position of the surface under it within that window's tree.

use crate::keymap::{self, Keysyms};
use crate::state::State;
use crate::windows::Surface;
use caboose_display_protocol::{self as proto, buttons, TouchPhase};
use smithay::backend::input::{Axis, AxisSource, ButtonState, KeyState};
use smithay::desktop::utils::under_from_surface_tree;
use smithay::desktop::WindowSurfaceType;
use smithay::input::keyboard::{FilterResult, Keycode};
use smithay::input::pointer::{AxisFrame, ButtonEvent, MotionEvent, RelativeMotionEvent};
use smithay::input::touch::{DownEvent, MotionEvent as TouchMotionEvent, UpEvent};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point};
use std::collections::{HashMap, HashSet};

/// evdev button codes.
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const BTN_SIDE: u32 = 0x113;
const BTN_EXTRA: u32 = 0x114;

const BUTTONS: [(u32, u32); 5] = [
    (buttons::LEFT, BTN_LEFT),
    (buttons::MIDDLE, BTN_MIDDLE),
    (buttons::RIGHT, BTN_RIGHT),
    (buttons::BACK, BTN_SIDE),
    (buttons::FORWARD, BTN_EXTRA),
];

/// Logical pixels per wheel click, as libinput reports for a mouse wheel.
const WHEEL_STEP: f64 = 15.0;

/// A surface and its origin in the logical space.
type Focus = (WlSurface, Point<f64, Logical>);

#[derive(Default)]
pub struct InputState {
    pub keysyms: Keysyms,
    pointer_buttons: u32,
    /// Touch slots that are down, with the window they started on.
    touches: HashMap<u32, u64>,
    /// Keycodes the client holds down.
    held: HashSet<u32>,
    /// Modifiers pressed on the client's behalf for one key, released with it.
    implied: HashMap<u32, Vec<u32>>,
    /// The innermost popup holding an xdg_popup grab.
    pub popup_grab: Option<u64>,
    /// Apple Pencil, as the seat's tablet pen (pencil.rs).
    pub pencil: crate::pencil::PencilState,
    /// The timer that ends a finger scroll sequence with axis_stop once samples stop.
    scroll_stop: Option<smithay::reexports::calloop::RegistrationToken>,
}

/// A finger scroll sequence ends when no sample has come for this long: the phone sends
/// one every display refresh while the content moves.
const SCROLL_STOP_AFTER: std::time::Duration = std::time::Duration::from_millis(50);

/// One scroll sample as wl_pointer axis events: precise samples are finger scrolling in
/// logical pixels, with no discrete steps; wheel clicks are 15 logical pixels and 120
/// value120 units each.
fn scroll_axes(scroll: &proto::Scroll, display_scale: f64) -> (AxisSource, Vec<(Axis, f64, Option<i32>)>) {
    let axes = [(Axis::Horizontal, scroll.dx), (Axis::Vertical, scroll.dy)];
    if scroll.precise {
        (AxisSource::Finger, axes.into_iter().filter(|(_, v)| *v != 0.0).map(|(a, v)| (a, v / display_scale, None)).collect())
    } else {
        (AxisSource::Wheel, axes.into_iter().filter(|(_, v)| *v != 0.0)
            .map(|(a, v)| (a, v * WHEEL_STEP, Some((v * 120.0).round() as i32))).collect())
    }
}

impl InputState {
    /// wl_touch.cancel ends every touch of the client, so the slots go with it.
    pub fn clear_touches(&mut self) {
        self.touches.clear();
    }

    /// Forgets the window; true if a touch was still down on it.
    pub fn forget_window(&mut self, id: u64) -> bool {
        let touched = self.touches.len();
        self.touches.retain(|_, w| *w != id);
        self.pencil.forget_window(id);
        if self.popup_grab == Some(id) {
            self.popup_grab = None;
        }
        self.touches.len() != touched
    }
}

impl State {
    /// The logical position of a window-local display-pixel point, and the surface
    /// under it with that surface's origin.
    pub(crate) fn locate(&self, id: u64, x: f64, y: f64) -> Option<(Point<f64, Logical>, Option<Focus>)> {
        let w = self.windows.get(id)?;
        let display = self.displays.resolve(Some(w.display));
        let origin = self.windows.logical_origin(id, &self.displays).to_f64();
        let point = origin + Point::from((display.to_logical(x), display.to_logical(y)));
        let root = w.surface.wl_surface()?;
        let surface_origin = self.windows.surface_origin(id, &self.displays);
        let under = under_from_surface_tree(&root, point, surface_origin, WindowSurfaceType::ALL)
            .map(|(s, loc)| (s, loc.to_f64()))
            // Outside every input region (a shadow, say): the root keeps the event, so a
            // drag that leaves the window still reaches it.
            .or(Some((root, surface_origin.to_f64())));
        Some((point, under))
    }

    /// A press outside the grabbing popup chain dismisses it, as a desktop would.
    fn dismiss_popups_unless(&mut self, id: u64) {
        let Some(grab) = self.input.popup_grab else { return };
        let mut chain = vec![grab];
        let mut cursor = grab;
        while let Some(p) = self.windows.get(cursor).and_then(|w| w.parent) {
            if !matches!(self.windows.get(p).map(|w| &w.surface), Some(Surface::Popup(_))) {
                break;
            }
            chain.push(p);
            cursor = p;
        }
        if chain.contains(&id) {
            return;
        }
        for popup in chain {
            if let Some(Surface::Popup(p)) = self.windows.get(popup).map(|w| &w.surface) {
                p.send_popup_done();
            }
        }
        self.input.popup_grab = None;
    }

    /// Focus follows a press: the window, or for a popup the popup itself.
    pub(crate) fn press_focus(&mut self, id: u64) {
        self.dismiss_popups_unless(id);
        if self.input.popup_grab.is_none() {
            self.focus_window(id);
        }
    }

    pub fn pointer(&mut self, m: &proto::Pointer) {
        let Some((location, under)) = self.locate(m.id, m.x, m.y) else { return };
        let Some(pointer) = self.seat.get_pointer() else { return };
        let utime = self.now_us();
        let time = (utime / 1000) as u32;
        let serial = self.next_serial();
        let delta = location - pointer.current_location();
        pointer.motion(self, under.clone(), &MotionEvent { location, serial, time });
        // Pair the virtual pointer's absolute position with relative motion in the
        // same frame. Xwayland otherwise alternates its absolute and relative X
        // devices for motion and axes, resetting XI2 clients' scroll baselines.
        // Both vectors are identical: this virtual device adds no acceleration.
        pointer.relative_motion(self, under, &RelativeMotionEvent { delta, delta_unaccel: delta, utime });
        let changed = self.input.pointer_buttons ^ m.buttons;
        if changed & m.buttons != 0 {
            self.press_focus(m.id);
        }
        for (bit, code) in BUTTONS {
            if changed & bit != 0 {
                let state = if m.buttons & bit != 0 { ButtonState::Pressed } else { ButtonState::Released };
                let serial = self.next_serial();
                pointer.button(self, &ButtonEvent { serial, time, button: code, state });
            }
        }
        self.input.pointer_buttons = m.buttons;
        if let Some(scroll) = &m.scroll {
            if let (Some(seq), Some(w)) = (scroll.seq, self.windows.get_mut(m.id)) {
                w.scroll_seq_delivered = w.scroll_seq_delivered.max(seq);
            }
            let display_scale =
                self.windows.get(m.id).map(|w| self.displays.resolve(Some(w.display)).info.scale).unwrap_or(1.0);
            let (source, axes) = scroll_axes(scroll, display_scale);
            let mut frame = AxisFrame::new(time).source(source);
            for (axis, value, v120) in axes {
                frame = frame.value(axis, value);
                if let Some(v120) = v120 {
                    frame = frame.v120(axis, v120);
                }
            }
            pointer.axis(self, frame);
            if scroll.precise {
                self.arm_scroll_stop();
            }
        }
        // One sample is one wl_pointer.frame: Xwayland turns each frame into its events.
        pointer.frame(self);
    }

    /// (Re)starts the wait after which a finger scroll sequence gets its axis_stop, the
    /// end Wayland clients use to finish a gesture (and start their own fling, if any).
    fn arm_scroll_stop(&mut self) {
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        if let Some(token) = self.input.scroll_stop.take() {
            self.handle.remove(token);
        }
        let inserted = self.handle.insert_source(Timer::from_duration(SCROLL_STOP_AFTER), |_, _, state: &mut State| {
            state.input.scroll_stop = None;
            if let Some(pointer) = state.seat.get_pointer() {
                let time = state.now_ms();
                let frame = AxisFrame::new(time).source(AxisSource::Finger).stop(Axis::Vertical).stop(Axis::Horizontal);
                pointer.axis(state, frame);
                pointer.frame(state);
                if let Err(e) = state.dh.flush_clients() {
                    tracing::warn!("flushing Wayland clients: {e}");
                }
            }
            TimeoutAction::Drop
        });
        self.input.scroll_stop = inserted.ok();
    }

    pub fn touch(&mut self, m: &proto::Touch) {
        let Some(touch) = self.seat.get_touch() else { return };
        let time = self.now_ms();
        for p in &m.points {
            let slot = Some(p.slot).into();
            match p.phase {
                TouchPhase::Down => {
                    let Some((location, under)) = self.locate(m.id, p.x, p.y) else { continue };
                    // A client never reuses a slot that is down; if its release was lost,
                    // release it here so the application does not reject the new touch.
                    if self.input.touches.contains_key(&p.slot) {
                        let serial = self.next_serial();
                        touch.up(self, &UpEvent { slot, serial, time });
                    }
                    self.press_focus(m.id);
                    self.input.touches.insert(p.slot, m.id);
                    let serial = self.next_serial();
                    touch.down(self, under, &DownEvent { slot, location, serial, time });
                }
                TouchPhase::Motion => {
                    let window = self.input.touches.get(&p.slot).copied().unwrap_or(m.id);
                    let Some((location, under)) = self.locate(window, p.x, p.y) else { continue };
                    touch.motion(self, under, &TouchMotionEvent { slot, location, time });
                }
                TouchPhase::Up => {
                    self.input.touches.remove(&p.slot);
                    let serial = self.next_serial();
                    touch.up(self, &UpEvent { slot, serial, time });
                }
                TouchPhase::Cancel => {
                    self.input.touches.clear();
                    touch.cancel(self);
                }
            }
        }
        touch.frame(self);
    }

    fn send_keycode(&mut self, keycode: u32, pressed: bool) {
        let Some(keyboard) = self.seat.get_keyboard() else { return };
        let serial = self.next_serial();
        let time = self.now_ms();
        let state = if pressed { KeyState::Pressed } else { KeyState::Released };
        keyboard.input::<(), _>(self, Keycode::new(keycode), state, serial, time, |_, _, _| FilterResult::Forward);
        if pressed {
            self.input.held.insert(keycode);
        } else {
            self.input.held.remove(&keycode);
        }
    }

    /// Presses the modifiers the key needs that are not already held; returns them.
    fn imply_modifiers(&mut self, names: &[&str]) -> Vec<u32> {
        let mut pressed = Vec::new();
        for name in names {
            let Some(pos) = keymap::modifier_keysym(name).and_then(|s| self.input.keysyms.lookup(s)) else { continue };
            if !self.input.held.contains(&pos.keycode) {
                self.send_keycode(pos.keycode, true);
                pressed.push(pos.keycode);
            }
        }
        pressed
    }

    pub fn key(&mut self, m: &proto::Key) {
        let Some(pos) = self.input.keysyms.lookup(m.keysym) else {
            // Not on the layout: text-input-v3 can still take it as text.
            if m.pressed {
                if let Some(c) = char::from_u32(smithay::input::keyboard::xkb::keysym_to_utf32(m.keysym.into()))
                    .filter(|c| *c != '\0')
                {
                    self.type_text(&c.to_string());
                } else {
                    tracing::debug!("keysym 0x{:x} is not on the keymap", m.keysym);
                }
            }
            return;
        };
        if m.pressed {
            // For a printable keysym the level decides Shift, whatever the client
            // reported, so "A" is typed as Shift+a and "a" never picks up a stale Shift.
            // Other keys keep the client's Shift (Shift+Tab, Shift+arrows).
            let printable = smithay::input::keyboard::xkb::keysym_to_utf32(m.keysym.into()) >= 0x20;
            let mut mods: Vec<&str> =
                m.mods.iter().map(String::as_str).filter(|n| !(printable && *n == "shift")).collect();
            if pos.shift && !mods.contains(&"shift") {
                mods.push("shift");
            }
            let implied = self.imply_modifiers(&mods);
            self.send_keycode(pos.keycode, true);
            self.input.implied.insert(pos.keycode, implied);
        } else {
            self.send_keycode(pos.keycode, false);
            for code in self.input.implied.remove(&pos.keycode).unwrap_or_default().into_iter().rev() {
                self.send_keycode(code, false);
            }
        }
    }

    /// Types text as key presses, for surfaces without text-input-v3. Characters that
    /// are not on the keymap are skipped.
    fn type_text(&mut self, text: &str) {
        for c in text.chars() {
            let keysym = keymap::char_to_keysym(c);
            let Some(pos) = self.input.keysyms.lookup(keysym) else {
                tracing::debug!("cannot type {c:?}: not on the keymap");
                continue;
            };
            let implied = if pos.shift { self.imply_modifiers(&["shift"]) } else { Vec::new() };
            self.send_keycode(pos.keycode, true);
            self.send_keycode(pos.keycode, false);
            for code in implied.into_iter().rev() {
                self.send_keycode(code, false);
            }
        }
    }

    fn tap_keysym(&mut self, keysym: u32, times: u32) {
        let Some(pos) = self.input.keysyms.lookup(keysym) else { return };
        for _ in 0..times {
            self.send_keycode(pos.keycode, true);
            self.send_keycode(pos.keycode, false);
        }
    }

    pub fn text(&mut self, m: &proto::Text) {
        let Some(surface) = self.keyboard_focus_surface() else { return };
        // Deletions are BackSpace and Delete presses, for every surface. They remove one
        // grapheme cluster in every toolkit, which is what the client counts; text-input-v3's
        // delete_surrounding_text instead needs the application's surrounding-text
        // bookkeeping, and Chromium drops it. The presses go out before the commit in the
        // same dispatch, so the application sees them first.
        self.tap_keysym(keymap::sym::BACKSPACE, m.delete_before.unwrap_or(0));
        self.tap_keysym(keymap::sym::DELETE, m.delete_after.unwrap_or(0));
        let preedit = m.preedit.as_deref().map(|p| {
            let [b, e] = m.cursor.unwrap_or([p.len() as u32; 2]);
            (p, b as i32, e as i32)
        });
        if m.commit.is_none() && preedit.is_none() {
            return;
        }
        if !self.text_inputs.send(&surface, m.commit.as_deref(), preedit) {
            // No text-input-v3 here (X11 through Xwayland, a terminal emulator without it):
            // the commit is typed. Pre-edit text has no key equivalent and is not shown.
            if let Some(commit) = &m.commit {
                self.type_text(commit);
            }
        }
    }

    /// Applies a `configure` from the client to the window.
    pub fn configure_window(&mut self, m: &proto::Configure) {
        let Some(w) = self.windows.get_mut(m.id) else { return };
        if let Some(d) = m.display.filter(|d| self.displays.get(*d).is_some()) {
            w.display = d;
        }
        if let Some(f) = m.fullscreen {
            w.fullscreen = f;
        }
        if let Some(mx) = m.maximized {
            w.maximized = mx;
        }
        let display = self.displays.resolve(Some(w.display));
        let to_logical = |v: i32| (v as f64 / display.info.scale).round() as i32;
        let (fullscreen, maximized) = (w.fullscreen, w.maximized);
        let display_size = display.logical_size();
        let display_origin = display.origin;
        let mut geometry = m.geometry.map(|g| {
            smithay::utils::Rectangle::<i32, Logical>::new(
                (to_logical(g.x), to_logical(g.y)).into(),
                (to_logical(g.w).max(1), to_logical(g.h).max(1)).into(),
            )
        });
        // Overscan (docs/display.md): lay the window out wider/taller than the geometry the
        // client shows. It stays asked for until [0, 0]; fullscreen and maximized windows
        // have a fixed size and get none.
        let shown = w.shown.unwrap_or_else(|| w.shown_size());
        if let Some(o) = m.overscan {
            w.overscan = (to_logical(o.w.max(0)), to_logical(o.h.max(0))).into();
            // Only the size changes: the window stays where it is.
            let at = match &w.surface {
                Surface::Toplevel(_) => Some(w.position),
                Surface::X11(x) => Some(x.geometry().loc - display_origin),
                Surface::Popup(_) => None,
            };
            if geometry.is_none() {
                geometry = at.map(|at| smithay::utils::Rectangle::new(at, shown));
            }
        }
        if fullscreen || maximized {
            w.overscan_size = None;
        }
        if let Some(g) = geometry.as_mut() {
            w.overscan_size = None;
            w.shown = Some(g.size);
            if !fullscreen && !maximized && (w.overscan.w > 0 || w.overscan.h > 0) {
                let limit = to_logical(crate::windows::OVERSCAN_MAX_PICTURE);
                let (whole, applied) = crate::windows::overscan_layout(g.size, w.overscan, w.max_size(), limit);
                if applied.w > 0 || applied.h > 0 {
                    g.size = whole;
                    w.overscan_size = Some(whole);
                }
            }
        }
        let id = m.id;
        match &w.surface {
            Surface::Toplevel(t) => {
                use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State as XdgState;
                if let Some(g) = geometry {
                    w.position = g.loc;
                }
                let size = if fullscreen || maximized { Some(display_size) } else { geometry.map(|g| g.size) };
                if fullscreen || maximized {
                    w.position = (0, 0).into();
                }
                let t = t.clone();
                t.with_pending_state(|s| {
                    if let Some(size) = size {
                        s.size = Some(size);
                    }
                    if fullscreen {
                        s.states.set(XdgState::Fullscreen)
                    } else {
                        s.states.unset(XdgState::Fullscreen)
                    };
                    if maximized {
                        s.states.set(XdgState::Maximized)
                    } else {
                        s.states.unset(XdgState::Maximized)
                    };
                });
                if t.is_initial_configure_sent() {
                    t.send_pending_configure();
                }
            }
            Surface::X11(x) => {
                let x = x.clone();
                let rect = if fullscreen || maximized {
                    Some(smithay::utils::Rectangle::new(display_origin, display_size))
                } else {
                    geometry.map(|g| smithay::utils::Rectangle::new(display_origin + g.loc, g.size))
                };
                let _ = x.set_fullscreen(fullscreen);
                let _ = x.set_maximized(maximized);
                if let Some(rect) = rect {
                    let _ = x.configure(rect);
                }
            }
            Surface::Popup(_) => {}
        }
        if m.display.is_some() {
            self.assign_output(id);
        }
        if m.activated == Some(true) {
            self.focus_window(id);
        }
    }

    pub fn close_window(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        match &w.surface {
            Surface::Toplevel(t) => t.send_close(),
            Surface::Popup(p) => p.send_popup_done(),
            Surface::X11(x) => {
                let _ = x.close();
            }
        }
    }

    /// Releases everything the client held: buttons, keys, touches.
    pub fn release_input(&mut self) {
        if let Some(pointer) = self.seat.get_pointer() {
            let time = self.now_ms();
            for (bit, code) in BUTTONS {
                if self.input.pointer_buttons & bit != 0 {
                    let serial = self.next_serial();
                    pointer.button(self, &ButtonEvent { serial, time, button: code, state: ButtonState::Released });
                }
            }
            pointer.frame(self);
        }
        self.input.pointer_buttons = 0;
        for code in self.input.held.clone() {
            self.send_keycode(code, false);
        }
        self.input.implied.clear();
        if !self.input.touches.is_empty() {
            if let Some(touch) = self.seat.get_touch() {
                touch.cancel(self);
            }
            self.input.touches.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{scroll_axes, Axis, AxisSource, InputState};
    use caboose_display_protocol as proto;

    #[test]
    fn precise_scroll_is_finger_pixels_without_discrete_steps() {
        let (source, axes) = scroll_axes(&proto::Scroll { dx: 0.0, dy: 60.0, precise: true, seq: None }, 2.0);
        assert_eq!(source, AxisSource::Finger);
        assert_eq!(axes, vec![(Axis::Vertical, 30.0, None)]);
        let (source, axes) = scroll_axes(&proto::Scroll { dx: -1.0, dy: 2.0, precise: false, seq: None }, 2.0);
        assert_eq!(source, AxisSource::Wheel);
        assert_eq!(axes, vec![(Axis::Horizontal, -15.0, Some(-120)), (Axis::Vertical, 30.0, Some(240))]);
    }

    #[test]
    fn forgetting_a_window_reports_touches_left_on_it() {
        let mut input = InputState::default();
        input.touches.insert(0, 7);
        input.touches.insert(1, 9);
        assert!(!input.forget_window(8));
        assert!(input.forget_window(7));
        assert_eq!(input.touches.len(), 1);
        input.clear_touches();
        assert!(!input.forget_window(9));
    }
}
