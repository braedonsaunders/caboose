//! What applications tell the compositor about their windows that only the phone can act
//! on: idle inhibition (the screen stays awake), content type (how fast to refresh),
//! keyboard grabs (keys the phone would keep for itself) and activation requests (bring a
//! window forward). Each is announced as a window field or message (docs/display.md,
//! "Window hints"); none is tied to an application.

use crate::state::{KeyboardFocus, State};
use crate::windows::Surface;
use caboose_display_protocol::{self as proto, ContentType};
use smithay::reexports::wayland_protocols::wp::content_type::v1::server::wp_content_type_v1::Type as WpContentType;
use smithay::reexports::wayland_protocols::xwayland::keyboard_grab::zv1::server::zwp_xwayland_keyboard_grab_v1::ZwpXwaylandKeyboardGrabV1;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{DisplayHandle, Resource};
use smithay::utils::IsAlive;
use smithay::wayland::compositor::{get_parent, with_surface_tree_downward, TraversalAction};
use smithay::wayland::content_type::{ContentTypeState, ContentTypeSurfaceCachedState};
use smithay::wayland::idle_inhibit::{IdleInhibitHandler, IdleInhibitManagerState};
use smithay::wayland::keyboard_shortcuts_inhibit::{
    KeyboardShortcutsInhibitHandler, KeyboardShortcutsInhibitState, KeyboardShortcutsInhibitor,
    KeyboardShortcutsInhibitorSeat,
};
use smithay::wayland::xdg_activation::{
    XdgActivationHandler, XdgActivationState, XdgActivationToken, XdgActivationTokenData,
};
use smithay::wayland::xwayland_keyboard_grab::{XWaylandKeyboardGrab, XWaylandKeyboardGrabHandler, XWaylandKeyboardGrabState};
use std::time::Duration;

/// How long an activation token stays good after the application that holds the keyboard
/// made it.
const TOKEN_LIFE: Duration = Duration::from_secs(10);

/// The globals this module registers, held so they stay registered.
#[allow(dead_code)]
pub struct Protocols {
    idle_inhibit: IdleInhibitManagerState,
    content_type: ContentTypeState,
    shortcuts: KeyboardShortcutsInhibitState,
    xwayland_grab: XWaylandKeyboardGrabState,
}

impl Protocols {
    pub fn new(dh: &DisplayHandle) -> (Self, XdgActivationState) {
        (
            Self {
                idle_inhibit: IdleInhibitManagerState::new::<State>(dh),
                content_type: ContentTypeState::new::<State>(dh),
                shortcuts: KeyboardShortcutsInhibitState::new::<State>(dh),
                xwayland_grab: XWaylandKeyboardGrabState::new::<State>(dh),
            },
            XdgActivationState::new::<State>(dh),
        )
    }
}

/// What the clients hold now: one entry for each idle inhibitor, and each Xwayland keyboard
/// grab with the surface it grabs for.
#[derive(Default)]
pub struct Hints {
    idle: Vec<WlSurface>,
    x_grabs: Vec<(WlSurface, ZwpXwaylandKeyboardGrabV1)>,
}

impl Hints {
    /// Forgets what a client that went away held.
    pub fn prune(&mut self) {
        self.idle.retain(|s| s.alive());
        self.x_grabs.retain(|(s, g)| s.alive() && g.is_alive());
    }
}

fn root_of(surface: &WlSurface) -> WlSurface {
    let mut root = surface.clone();
    while let Some(parent) = get_parent(&root) {
        root = parent;
    }
    root
}

/// The content type a surface tree declares: the most demanding one in it.
fn content_type_of(root: &WlSurface) -> ContentType {
    let mut found = ContentType::None;
    with_surface_tree_downward(
        root,
        (),
        |_, _, _| TraversalAction::DoChildren(()),
        |surface, states, _| {
            let _ = surface;
            let declared = match states.cached_state.get::<ContentTypeSurfaceCachedState>().current().content_type() {
                WpContentType::Photo => ContentType::Photo,
                WpContentType::Video => ContentType::Video,
                WpContentType::Game => ContentType::Game,
                _ => ContentType::None,
            };
            let rank = |c: ContentType| match c {
                ContentType::None => 0,
                ContentType::Photo => 1,
                ContentType::Video => 2,
                ContentType::Game => 3,
            };
            if rank(declared) > rank(found) {
                found = declared;
            }
        },
        |_, _, _| true,
    );
    found
}

impl State {
    /// The window's idle inhibition, content type and keyboard grab, as its application
    /// last set them.
    pub fn window_hints(&self, id: u64) -> (bool, ContentType, bool) {
        let Some(root) = self.windows.get(id).and_then(|w| w.surface.wl_surface()) else {
            return (false, ContentType::None, false);
        };
        let idle = self.hints.idle.iter().any(|s| root_of(s) == root);
        let keys = self.seat.keyboard_shortcuts_inhibitor_for_surface(&root).is_some_and(|i| i.is_active())
            || self.hints.x_grabs.iter().any(|(s, _)| root_of(s) == root);
        (idle, content_type_of(&root), keys)
    }
}

impl IdleInhibitHandler for State {
    fn inhibit(&mut self, surface: WlSurface) {
        self.hints.idle.push(surface);
    }

    fn uninhibit(&mut self, surface: WlSurface) {
        if let Some(at) = self.hints.idle.iter().position(|s| *s == surface) {
            self.hints.idle.remove(at);
        }
    }
}

impl KeyboardShortcutsInhibitHandler for State {
    fn keyboard_shortcuts_inhibit_state(&mut self) -> &mut KeyboardShortcutsInhibitState {
        &mut self.hint_protocols.shortcuts
    }

    /// The phone is the only user: a request is granted, and the phone decides what
    /// keeping the shortcuts means.
    fn new_inhibitor(&mut self, inhibitor: KeyboardShortcutsInhibitor) {
        inhibitor.activate();
    }
}

impl XWaylandKeyboardGrabHandler for State {
    /// Every key already reaches the focused window; the grab only tells the phone to send
    /// the keys it would keep for itself, so the seat's keyboard is left as it is.
    fn grab(
        &mut self,
        surface: WlSurface,
        _seat: smithay::input::Seat<Self>,
        grab: XWaylandKeyboardGrab<Self>,
    ) {
        self.hints.x_grabs.push((surface, grab.grab().clone()));
    }

    fn keyboard_focus_for_xsurface(&self, surface: &WlSurface) -> Option<KeyboardFocus> {
        let id = self.windows.by_surface(surface)?;
        match &self.windows.get(id)?.surface {
            Surface::X11(x) => Some(KeyboardFocus::X11(x.clone())),
            _ => None,
        }
    }
}

impl XdgActivationHandler for State {
    fn activation_state(&mut self) -> &mut XdgActivationState {
        &mut self.activation
    }

    /// Only an application that holds the keyboard can have a window brought forward, and
    /// for a few seconds: a background application cannot take the screen.
    fn token_created(&mut self, _token: XdgActivationToken, data: XdgActivationTokenData) -> bool {
        let focus = self.keyboard_focus_surface();
        match (&data.surface, &focus) {
            (Some(surface), Some(focus)) => root_of(surface) == root_of(focus),
            (None, Some(focus)) => {
                let focused_client = self.dh.get_client(focus.id()).ok().map(|c| c.id());
                data.client_id.is_some() && data.client_id == focused_client
            }
            _ => false,
        }
    }

    fn request_activation(&mut self, token: XdgActivationToken, data: XdgActivationTokenData, surface: WlSurface) {
        self.activation.remove_token(&token);
        if data.timestamp.elapsed() > TOKEN_LIFE {
            return;
        }
        let Some(id) = self.window_of_surface(&surface) else { return };
        match self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) {
            Some(conn) => {
                self.net.send(conn, &proto::Message::WindowActivate { id });
            }
            None => self.focus_window(id),
        }
    }
}

smithay::delegate_idle_inhibit!(State);
smithay::delegate_content_type!(State);
smithay::delegate_keyboard_shortcuts_inhibit!(State);
smithay::delegate_xwayland_keyboard_grab!(State);
smithay::delegate_xdg_activation!(State);
