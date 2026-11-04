//! X11 applications through Xwayland. Each mapped X11 window is a protocol window:
//! managed windows are toplevels (dialogs when transient for another window), and
//! override-redirect windows (menus, tooltips) are popups of the window they belong to.

use crate::state::State;
use crate::windows::Surface;
use caboose_display_protocol::WindowKind;
use smithay::utils::{Logical, Point, Rectangle, Size};
use smithay::wayland::selection::data_device::{
    clear_data_device_selection, current_data_device_selection_userdata, request_data_device_client_selection,
    set_data_device_selection,
};
use smithay::wayland::selection::primary_selection::{
    clear_primary_selection, current_primary_selection_userdata, request_primary_client_selection,
    set_primary_selection,
};
use smithay::wayland::selection::SelectionTarget;
use smithay::xwayland::xwm::{Reorder, ResizeEdge, XwmId};
use smithay::xwayland::{X11Surface, X11Wm, XwmHandler};
use std::os::unix::io::OwnedFd;

impl State {
    /// An X11 window became a bindable surface: GPU binds held for windows that were not
    /// bindable yet are answered once this turn's window changes are done (gpu_pending.rs).
    fn x11_window_bindable(&mut self) {
        if self.gpu_pending_binds.is_empty() { return; }
        self.handle.insert_idle(|state| state.answer_pending_gpu_binds());
    }

    /// The window an X11 window belongs to: the one it is transient for, else the
    /// focused X11 window, else the X11 toplevel under its origin.
    fn x11_owner(&self, window: &X11Surface) -> Option<u64> {
        if let Some(parent) = window.is_transient_for() {
            if let Some(id) = self
                .windows
                .find(|w| matches!(&w.surface, Surface::X11(x) if x.window_id() == parent && !x.is_override_redirect()))
            {
                return Some(id);
            }
        }
        if let Some(crate::state::KeyboardFocus::X11(focused)) =
            self.seat.get_keyboard().and_then(|k| k.current_focus())
        {
            if let Some(id) = self.windows.by_x11(&focused) {
                return Some(id);
            }
        }
        let loc = window.geometry().loc;
        self.windows.find(|w| match &w.surface {
            Surface::X11(x) => !x.is_override_redirect() && x.geometry().contains(loc),
            _ => false,
        })
    }

    /// Places a new managed window on its display: dialogs centred over their parent,
    /// everything else at the display origin, at its first size (`first_size`). Returns the
    /// geometry, and the size it is held at when it is larger than the display.
    fn place_x11(&self, window: &X11Surface, parent: Option<u64>) -> (Rectangle<i32, Logical>, Option<Size<i32, Logical>>) {
        let display = match parent.and_then(|p| self.windows.get(p)) {
            Some(p) => self.displays.resolve(Some(p.display)),
            None => self.displays.primary(),
        };
        let area = display.logical_rect();
        let mut geo = window.geometry();
        let hinted = window.min_size().is_some() || window.max_size().is_some();
        let (size, held) = first_size(geo.size, area.size, hinted, parent.is_none());
        geo.size = size;
        let positioned = window.size_hints().is_some_and(|h| h.position.is_some());
        geo.loc = match parent {
            Some(p) => {
                let porigin = self.windows.logical_origin(p, &self.displays);
                let psize = self.windows.get(p).map(|w| w.local_geometry().size).unwrap_or(area.size);
                (porigin.x + (psize.w - geo.size.w) / 2, porigin.y + (psize.h - geo.size.h) / 2).into()
            }
            None => first_position(geo, area, positioned),
        };
        (geo, held)
    }
}

/// A new X11 top-level's place on a display of `area`: where it asked to be when it gave a
/// position (WM_NORMAL_HINTS, as Wine does for every window, and a splash centres itself),
/// otherwise centred, and moved only as far as keeps it on the display.
fn first_position(geo: Rectangle<i32, Logical>, area: Rectangle<i32, Logical>, positioned: bool) -> Point<i32, Logical> {
    let place = |at: i32, size: i32, start: i32, extent: i32| {
        let wanted = if positioned { at } else { start + (extent - size) / 2 };
        wanted.clamp(start, start + (extent - size).max(0))
    };
    (place(geo.loc.x, geo.size.w, area.loc.x, area.size.w), place(geo.loc.y, geo.size.h, area.loc.y, area.size.h)).into()
}

/// A new X11 window's first size on a display of `area`: what it asked for, clamped to the
/// display, except a top-level without size hints that asked to be larger. That one, a
/// Wine virtual desktop of a fixed resolution, keeps its size and is held at it: the
/// phone gets it as the window's minimum and shows it scaled to fit, as a window held
/// larger by its minimum size. Shrinking it would cut its picture, since the app keeps
/// drawing at the size it chose.
fn first_size(
    requested: Size<i32, Logical>,
    area: Size<i32, Logical>,
    hinted: bool,
    toplevel: bool,
) -> (Size<i32, Logical>, Option<Size<i32, Logical>>) {
    let larger = requested.w > area.w || requested.h > area.h;
    if toplevel && !hinted && larger {
        let size = Size::from((requested.w.max(1), requested.h.max(1)));
        return (size, Some(size));
    }
    ((requested.w.clamp(1, area.w), requested.h.clamp(1, area.h)).into(), None)
}

/// What an X11 window's own configure request gets. Apps may size themselves, as a Wayland
/// app may, and move themselves as under any window manager while `movable`: until the
/// phone lays the window out (fills, snaps or places it), after which it stays where it was
/// placed. A maximized or full-screen window keeps the size it was configured to as well:
/// it is the compositor's (and the phone's) while that state lasts, so an app restoring a
/// saved size cannot shrink it out of it.
fn requested_geometry(
    current: Rectangle<i32, Logical>,
    (x, y): (Option<i32>, Option<i32>),
    (w, h): (Option<u32>, Option<u32>),
    movable: bool,
    locked: bool,
) -> Rectangle<i32, Logical> {
    let mut geo = current;
    if !locked {
        if let Some(w) = w {
            geo.size.w = w as i32;
        }
        if let Some(h) = h {
            geo.size.h = h as i32;
        }
    }
    if movable && !locked {
        if let Some(x) = x {
            geo.loc.x = x;
        }
        if let Some(y) = y {
            geo.loc.y = y;
        }
    }
    geo
}

impl XwmHandler for State {
    fn xwm_state(&mut self, _xwm: XwmId) -> &mut X11Wm {
        self.xwm.as_mut().expect("X11 window manager")
    }

    fn new_window(&mut self, _xwm: XwmId, _window: X11Surface) {}
    fn new_override_redirect_window(&mut self, _xwm: XwmId, _window: X11Surface) {}

    fn map_window_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Err(e) = window.set_mapped(true) {
            tracing::warn!("X11 map: {e}");
            return;
        }
        let parent = window.is_transient_for().and_then(|_| self.x11_owner(&window));
        let (geo, held) = self.place_x11(&window, parent);
        let _ = window.configure(geo);
        let kind = if parent.is_some() { WindowKind::Dialog } else { WindowKind::Toplevel };
        let id = self.add_window(Surface::X11(window), kind, parent);
        if let Some(w) = self.windows.get_mut(id) {
            w.held_min = held;
        }
        self.focus_window(id);
        self.x11_window_bindable();
    }

    fn mapped_override_redirect_window(&mut self, _xwm: XwmId, window: X11Surface) {
        let parent = self.x11_owner(&window);
        let kind = if parent.is_some() { WindowKind::Popup } else { WindowKind::Toplevel };
        self.add_window(Surface::X11(window), kind, parent);
        self.x11_window_bindable();
    }

    fn unmapped_window(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.remove_window(id);
        }
        if !window.is_override_redirect() {
            let _ = window.set_mapped(false);
        }
    }

    fn destroyed_window(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.remove_window(id);
        }
        self.refuse_pending_gpu_binds_of(window.window_id());
    }

    fn configure_request(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        x: Option<i32>,
        y: Option<i32>,
        w: Option<u32>,
        h: Option<u32>,
        _reorder: Option<Reorder>,
    ) {
        // A window the phone has not laid out floats: it moves itself, as under any window
        // manager. One the phone filled, snapped or placed stays where the phone put it.
        let (movable, locked) = match self.windows.by_x11(&window).and_then(|id| self.windows.get(id)) {
            Some(w) => (!w.placed, w.maximized || w.fullscreen),
            None => (true, false),
        };
        let _ = window.configure(requested_geometry(window.geometry(), (x, y), (w, h), movable, locked));
    }

    fn configure_notify(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        _geometry: Rectangle<i32, Logical>,
        _above: Option<u32>,
    ) {
        if let Some(id) = self.windows.by_x11(&window) {
            let now = self.now_us();
            if let Some(w) = self.windows.get_mut(id) {
                w.picture.mark_dirty(now);
            }
        }
    }

    fn maximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.configure_window(&caboose_display_protocol::Configure {
                id,
                maximized: Some(true),
                ..Default::default()
            });
        }
    }

    fn unmaximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.configure_window(&caboose_display_protocol::Configure {
                id,
                maximized: Some(false),
                ..Default::default()
            });
        }
    }

    fn fullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.configure_window(&caboose_display_protocol::Configure {
                id,
                fullscreen: Some(true),
                ..Default::default()
            });
        }
    }

    fn unfullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(id) = self.windows.by_x11(&window) {
            self.configure_window(&caboose_display_protocol::Configure {
                id,
                fullscreen: Some(false),
                ..Default::default()
            });
        }
    }

    // Moving and resizing are the client's (the phone lays windows out).
    fn resize_request(&mut self, _xwm: XwmId, _window: X11Surface, _button: u32, _edges: ResizeEdge) {}
    fn move_request(&mut self, _xwm: XwmId, _window: X11Surface, _button: u32) {}

    fn allow_selection_access(&mut self, xwm: XwmId, _selection: SelectionTarget) -> bool {
        matches!(
            self.seat.get_keyboard().and_then(|k| k.current_focus()),
            Some(crate::state::KeyboardFocus::X11(x)) if x.xwm_id() == Some(xwm)
        )
    }

    fn send_selection(&mut self, _xwm: XwmId, selection: SelectionTarget, mime_type: String, fd: OwnedFd) {
        // The phone's copy is the compositor's own selection: write it directly.
        if selection == SelectionTarget::Clipboard {
            let phone = current_data_device_selection_userdata(&self.seat).and_then(|owner| match &*owner {
                crate::clipboard::Owner::Phone(offer) => Some(offer.clone()),
                crate::clipboard::Owner::X11(_) => None,
            });
            if let Some(offer) = phone {
                // Secrets never go to X11: in X the pasted text is readable by
                // any client (docs/display.md, Clipboard).
                if !offer.secret && offer.is_current(self.clipboard.generation) {
                    offer.send(&mime_type, fd);
                }
                return;
            }
        }
        let result = match selection {
            SelectionTarget::Clipboard => {
                request_data_device_client_selection(&self.seat, mime_type, fd).map_err(|e| e.to_string())
            }
            SelectionTarget::Primary => {
                request_primary_client_selection(&self.seat, mime_type, fd).map_err(|e| e.to_string())
            }
        };
        if let Err(e) = result {
            tracing::debug!("X11 selection request: {e}");
        }
    }

    fn new_selection(&mut self, _xwm: XwmId, selection: SelectionTarget, mime_types: Vec<String>) {
        use crate::clipboard::Owner;
        match selection {
            SelectionTarget::Clipboard => {
                self.clipboard.generation += 1;
                set_data_device_selection(&self.dh, &self.seat, mime_types.clone(), Owner::X11(self.clipboard.generation));
                self.clipboard_from_x11(&mime_types);
            }
            SelectionTarget::Primary => {
                self.clipboard.generation += 1;
                set_primary_selection(&self.dh, &self.seat, mime_types, Owner::X11(self.clipboard.generation))
            }
        }
    }

    fn cleared_selection(&mut self, _xwm: XwmId, selection: SelectionTarget) {
        match selection {
            SelectionTarget::Clipboard => {
                if current_data_device_selection_userdata(&self.seat).is_some() {
                    clear_data_device_selection(&self.dh, &self.seat)
                }
            }
            SelectionTarget::Primary => {
                if current_primary_selection_userdata(&self.seat).is_some() {
                    clear_primary_selection(&self.dh, &self.seat)
                }
            }
        }
    }

    fn disconnected(&mut self, _xwm: XwmId) {
        tracing::warn!("the X11 window manager lost Xwayland");
        self.xwm = None;
    }
}

#[cfg(test)]
mod tests {
    use super::{first_position, first_size, requested_geometry};
    use smithay::utils::{Logical, Rectangle, Size};

    fn size(w: i32, h: i32) -> Size<i32, Logical> {
        (w, h).into()
    }

    #[test]
    fn a_top_level_without_hints_larger_than_its_display_is_held_at_its_size() {
        // A 1920x1080 Wine desktop on a portrait phone at scale 3 (311x452 logical).
        let desktop = size(640, 360);
        assert_eq!(first_size(desktop, size(311, 452), false, true), (desktop, Some(desktop)));
        // Larger on either axis is enough.
        assert_eq!(first_size(size(300, 500), size(311, 452), false, true), (size(300, 500), Some(size(300, 500))));
    }

    fn rect(x: i32, y: i32, w: i32, h: i32) -> Rectangle<i32, Logical> {
        Rectangle::new((x, y).into(), (w, h).into())
    }

    #[test]
    fn a_top_level_goes_where_it_asked_or_centred() {
        let area = rect(0, 0, 669, 455);
        // A Wine splash centred by the game: 600x338 at 369,286 on a 1338x911 screen at scale 2.
        assert_eq!(first_position(rect(184, 143, 300, 169), area, true), (184, 143).into());
        // A window that gave no position is centred.
        assert_eq!(first_position(rect(0, 0, 300, 169), area, false), (184, 143).into());
        // A full-screen window at the origin stays there.
        assert_eq!(first_position(rect(0, 0, 669, 455), area, true), (0, 0).into());
    }

    #[test]
    fn a_top_level_is_kept_on_its_display() {
        let area = rect(100, 50, 669, 455);
        // Off the far edges: moved back just far enough.
        assert_eq!(first_position(rect(700, 600, 300, 169), area, true), (469, 336).into());
        // Before the display's origin, or larger than it: at the origin.
        assert_eq!(first_position(rect(-40, 10, 300, 169), area, true), (100, 50).into());
        assert_eq!(first_position(rect(300, 300, 960, 540), area, true), (100, 50).into());
        assert_eq!(first_position(rect(0, 0, 960, 540), area, false), (100, 50).into());
    }

    #[test]
    fn other_first_sizes_are_clamped_to_the_display() {
        let area = size(311, 452);
        // Within the display: as asked, not held.
        assert_eq!(first_size(size(200, 100), area, false, true), (size(200, 100), None));
        // With size hints, the phone has the app's own minimum to work with.
        assert_eq!(first_size(size(640, 360), area, true, true), (size(311, 360), None));
        // A dialog stays within the display.
        assert_eq!(first_size(size(640, 360), area, false, false), (size(311, 360), None));
        // Nothing is ever empty.
        assert_eq!(first_size(size(0, 0), area, false, true), (size(1, 1), None));
    }

    #[test]
    fn a_placed_window_sizes_itself_but_stays_in_place() {
        let current = Rectangle::new((0, 0).into(), (669, 424).into());
        let geo = requested_geometry(current, (Some(12), Some(0)), (Some(535), Some(380)), false, false);
        assert_eq!(geo, Rectangle::new((0, 0).into(), (535, 380).into()));
    }

    #[test]
    fn a_floating_window_moves_itself() {
        // A splash the app re-centres after creating it at the screen's size.
        let current = Rectangle::new((0, 0).into(), (669, 456).into());
        let geo = requested_geometry(current, (Some(185), Some(143)), (Some(300), Some(169)), true, false);
        assert_eq!(geo, Rectangle::new((185, 143).into(), (300, 169).into()));
        // Only what it asked for changes.
        let geo = requested_geometry(current, (Some(12), None), (None, Some(380)), true, false);
        assert_eq!(geo, Rectangle::new((12, 0).into(), (669, 380).into()));
    }

    #[test]
    fn a_maximized_window_keeps_its_configured_size() {
        let current = Rectangle::new((0, 0).into(), (669, 424).into());
        assert_eq!(requested_geometry(current, (Some(12), Some(0)), (Some(535), Some(380)), true, true), current);
        assert_eq!(requested_geometry(current, (Some(12), Some(0)), (Some(535), Some(380)), false, true), current);
    }
}
