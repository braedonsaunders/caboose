//! X11 applications through Xwayland. Each mapped X11 window is a protocol window:
//! managed windows are toplevels (dialogs when transient for another window), and
//! override-redirect windows (menus, tooltips) are popups of the window they belong to.

use crate::state::State;
use crate::windows::Surface;
use caboose_display_protocol::WindowKind;
use smithay::utils::{Logical, Rectangle};
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
    /// everything else at the display origin, at the size it asked for (clamped to the
    /// display).
    fn place_x11(&self, window: &X11Surface, parent: Option<u64>) -> Rectangle<i32, Logical> {
        let display = match parent.and_then(|p| self.windows.get(p)) {
            Some(p) => self.displays.resolve(Some(p.display)),
            None => self.displays.primary(),
        };
        let area = display.logical_rect();
        let mut geo = window.geometry();
        geo.size.w = geo.size.w.clamp(1, area.size.w);
        geo.size.h = geo.size.h.clamp(1, area.size.h);
        geo.loc = match parent {
            Some(p) => {
                let porigin = self.windows.logical_origin(p, &self.displays);
                let psize = self.windows.get(p).map(|w| w.local_geometry().size).unwrap_or(area.size);
                (porigin.x + (psize.w - geo.size.w) / 2, porigin.y + (psize.h - geo.size.h) / 2).into()
            }
            None => area.loc,
        };
        geo
    }
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
        let geo = self.place_x11(&window, parent);
        let _ = window.configure(geo);
        let kind = if parent.is_some() { WindowKind::Dialog } else { WindowKind::Toplevel };
        let id = self.add_window(Surface::X11(window), kind, parent);
        self.focus_window(id);
    }

    fn mapped_override_redirect_window(&mut self, _xwm: XwmId, window: X11Surface) {
        let parent = self.x11_owner(&window);
        let kind = if parent.is_some() { WindowKind::Popup } else { WindowKind::Toplevel };
        self.add_window(Surface::X11(window), kind, parent);
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
        // Apps may size themselves. Only unmanaged-looking placement requests move a
        // window: a managed window stays where it was placed.
        let mut geo = window.geometry();
        if let Some(w) = w {
            geo.size.w = w as i32;
        }
        if let Some(h) = h {
            geo.size.h = h as i32;
        }
        if self.windows.by_x11(&window).is_none() {
            if let Some(x) = x {
                geo.loc.x = x;
            }
            if let Some(y) = y {
                geo.loc.y = y;
            }
        }
        let _ = window.configure(geo);
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
                w.stream.mark_dirty(now);
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
        // The phone's text is the compositor's own selection: write it directly.
        if selection == SelectionTarget::Clipboard {
            let phone = current_data_device_selection_userdata(&self.seat).and_then(|owner| match &*owner {
                crate::clipboard::Owner::Phone(data) => Some(data.clone()),
                crate::clipboard::Owner::X11 => None,
            });
            if let Some(data) = phone {
                crate::clipboard::write_to(fd, data);
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
                set_data_device_selection(&self.dh, &self.seat, mime_types.clone(), Owner::X11);
                self.clipboard_from_x11(&mime_types);
            }
            SelectionTarget::Primary => set_primary_selection(&self.dh, &self.seat, mime_types, Owner::X11),
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
