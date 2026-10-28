//! Every window the protocol knows: xdg toplevels, xdg popups and X11 windows, each with
//! a stable id, a display, a geometry in that display's pixels, and its stream.

use crate::displays::{DisplayOutput, Displays};
use crate::stream::Stream;
use caboose_display_protocol::{self as proto, Rect, WindowKind};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::{PopupSurface, SurfaceCachedState, ToplevelSurface, XdgToplevelSurfaceData};
use smithay::xwayland::X11Surface;
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub enum Surface {
    Toplevel(ToplevelSurface),
    Popup(PopupSurface),
    X11(X11Surface),
}

impl Surface {
    pub fn wl_surface(&self) -> Option<WlSurface> {
        match self {
            Surface::Toplevel(t) => Some(t.wl_surface().clone()),
            Surface::Popup(p) => Some(p.wl_surface().clone()),
            Surface::X11(x) => x.wl_surface(),
        }
    }

    pub fn is_x11(&self) -> bool {
        matches!(self, Surface::X11(_))
    }
}

pub struct Window {
    pub id: u64,
    pub surface: Surface,
    pub parent: Option<u64>,
    pub kind: WindowKind,
    pub display: u32,
    /// Toplevels: the window geometry origin relative to the display, in display
    /// pixels. Popups and X11 windows derive theirs.
    pub position: Point<i32, Logical>,
    /// What the client was last told, to send only changes.
    pub announced: Option<proto::WindowCreate>,
    pub stream: Stream,
    /// The configure the client asked for that the app has not yet matched.
    pub fullscreen: bool,
    pub maximized: bool,
}

/// The xdg window geometry of a surface: where the window is within the surface
/// (excluding client-side shadows), in surface-local logical coordinates.
pub fn xdg_geometry(surface: &WlSurface) -> Rectangle<i32, Logical> {
    let set = with_states(surface, |states| states.cached_state.get::<SurfaceCachedState>().current().geometry);
    set.unwrap_or_else(|| smithay::desktop::utils::bbox_from_surface_tree(surface, (0, 0)))
}

fn min_max(surface: &WlSurface) -> (Size<i32, Logical>, Size<i32, Logical>) {
    with_states(surface, |states| {
        let mut cached = states.cached_state.get::<SurfaceCachedState>();
        let current = cached.current();
        (current.min_size, current.max_size)
    })
}

fn title_app_id(surface: &WlSurface) -> (String, String) {
    with_states(surface, |states| {
        states
            .data_map
            .get::<XdgToplevelSurfaceData>()
            .map(|d| {
                let d = d.lock().unwrap();
                (d.title.clone().unwrap_or_default(), d.app_id.clone().unwrap_or_default())
            })
            .unwrap_or_default()
    })
}

fn to_px(d: &DisplayOutput, v: i32) -> i32 {
    d.to_pixels(v as f64).round() as i32
}

fn size_px(d: &DisplayOutput, s: Size<i32, Logical>) -> Option<proto::Size> {
    (s.w > 0 || s.h > 0).then(|| proto::Size { w: to_px(d, s.w), h: to_px(d, s.h) })
}

impl Window {
    /// The window's geometry in surface-local logical coordinates (for X11 windows the
    /// whole surface).
    pub fn local_geometry(&self) -> Rectangle<i32, Logical> {
        match &self.surface {
            Surface::Toplevel(t) => xdg_geometry(t.wl_surface()),
            Surface::Popup(p) => {
                let g = xdg_geometry(p.wl_surface());
                let size = p.with_pending_state(|s| s.geometry.size);
                Rectangle::new(g.loc, if g.size.w > 0 { g.size } else { size })
            }
            Surface::X11(x) => Rectangle::from_size(x.geometry().size),
        }
    }
}

#[derive(Default)]
pub struct Windows {
    map: BTreeMap<u64, Window>,
    next_id: u64,
}

impl Windows {
    pub fn insert(&mut self, mut window: Window) -> u64 {
        self.next_id += 1;
        window.id = self.next_id;
        let id = window.id;
        self.map.insert(id, window);
        id
    }

    pub fn remove(&mut self, id: u64) -> Option<Window> {
        self.map.remove(&id)
    }

    pub fn get(&self, id: u64) -> Option<&Window> {
        self.map.get(&id)
    }

    pub fn get_mut(&mut self, id: u64) -> Option<&mut Window> {
        self.map.get_mut(&id)
    }

    pub fn ids(&self) -> Vec<u64> {
        self.map.keys().copied().collect()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Window> {
        self.map.values()
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut Window> {
        self.map.values_mut()
    }

    pub fn find(&self, pred: impl Fn(&Window) -> bool) -> Option<u64> {
        self.map.values().find(|w| pred(w)).map(|w| w.id)
    }

    /// The window whose root surface is `surface`.
    pub fn by_surface(&self, surface: &WlSurface) -> Option<u64> {
        self.find(|w| w.surface.wl_surface().as_ref() == Some(surface))
    }

    pub fn by_toplevel(&self, t: &ToplevelSurface) -> Option<u64> {
        self.find(|w| matches!(&w.surface, Surface::Toplevel(s) if s == t))
    }

    pub fn by_popup(&self, p: &PopupSurface) -> Option<u64> {
        self.find(|w| matches!(&w.surface, Surface::Popup(s) if s == p))
    }

    pub fn by_x11(&self, x: &X11Surface) -> Option<u64> {
        self.find(|w| matches!(&w.surface, Surface::X11(s) if s == x))
    }

    /// Children (popups, dialogs) of a window, recursively, deepest last.
    pub fn descendants(&self, id: u64) -> Vec<u64> {
        let mut out = Vec::new();
        let mut frontier = vec![id];
        while let Some(p) = frontier.pop() {
            for w in self.map.values().filter(|w| w.parent == Some(p)) {
                out.push(w.id);
                frontier.push(w.id);
            }
        }
        out
    }

    /// Ids in an order where every parent precedes its children.
    pub fn parent_first(&self) -> Vec<u64> {
        let mut out: Vec<u64> = Vec::new();
        let mut pending: Vec<u64> = self.ids();
        while !pending.is_empty() {
            let before = pending.len();
            pending.retain(|id| {
                let parent = self.map[id].parent;
                if parent.is_none_or(|p| out.contains(&p) || !self.map.contains_key(&p)) {
                    out.push(*id);
                    false
                } else {
                    true
                }
            });
            if pending.len() == before {
                out.append(&mut pending); // a cycle cannot happen, but never loop forever
            }
        }
        out
    }

    /// The window geometry's origin in the logical space.
    pub fn logical_origin(&self, id: u64, displays: &Displays) -> Point<i32, Logical> {
        let Some(w) = self.map.get(&id) else { return (0, 0).into() };
        match &w.surface {
            Surface::X11(x) => x.geometry().loc,
            Surface::Toplevel(_) => {
                let d = displays.resolve(Some(w.display));
                d.origin + w.position
            }
            Surface::Popup(p) => {
                let parent = w.parent.map(|p| self.logical_origin(p, displays)).unwrap_or_default();
                parent + p.with_pending_state(|s| s.geometry.loc)
            }
        }
    }

    /// Where the root surface's origin is in the logical space.
    pub fn surface_origin(&self, id: u64, displays: &Displays) -> Point<i32, Logical> {
        let Some(w) = self.map.get(&id) else { return (0, 0).into() };
        self.logical_origin(id, displays) - w.local_geometry().loc
    }

    /// The window as the protocol describes it now.
    pub fn describe(&self, id: u64, displays: &Displays) -> Option<proto::WindowCreate> {
        let w = self.map.get(&id)?;
        let d = displays.resolve(Some(w.display));
        let local = w.local_geometry();
        let origin = self.logical_origin(id, displays);
        let relative = match w.parent.and_then(|p| self.map.get(&p).map(|_| p)) {
            Some(p) => origin - self.logical_origin(p, displays),
            None => origin - d.origin,
        };
        let geometry =
            Rect::new(to_px(d, relative.x), to_px(d, relative.y), to_px(d, local.size.w), to_px(d, local.size.h));
        let (title, app_id, min, max, fullscreen) = match &w.surface {
            Surface::Toplevel(t) => {
                let (title, app_id) = title_app_id(t.wl_surface());
                let (min, max) = min_max(t.wl_surface());
                let fullscreen = t.with_pending_state(|s| {
                    s.states.contains(
                        smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State::Fullscreen,
                    )
                });
                (title, app_id, size_px(d, min), size_px(d, max), fullscreen)
            }
            Surface::Popup(p) => {
                let app_id = w.parent.and_then(|p| self.describe(p, displays)).map(|p| p.app_id).unwrap_or_default();
                let _ = p;
                (String::new(), app_id, None, None, false)
            }
            Surface::X11(x) => (
                x.title(),
                x.class(),
                x.min_size().and_then(|s| size_px(d, s)),
                x.max_size().and_then(|s| size_px(d, s)),
                x.is_fullscreen(),
            ),
        };
        Some(proto::WindowCreate {
            id,
            parent: w.parent,
            kind: w.kind,
            title,
            app_id,
            icon: None,
            geometry,
            min,
            max,
            fullscreen,
            display: Some(d.info.id),
            xwayland: w.surface.is_x11(),
            alpha: false,
        })
    }
}

/// The fields of `now` that differ from `before`.
pub fn diff(before: &proto::WindowCreate, now: &proto::WindowCreate) -> proto::WindowUpdate {
    fn changed<T: PartialEq + Clone>(a: &T, b: &T) -> Option<T> {
        (a != b).then(|| b.clone())
    }
    proto::WindowUpdate {
        id: now.id,
        parent: if before.parent != now.parent { now.parent } else { None },
        kind: changed(&before.kind, &now.kind),
        title: changed(&before.title, &now.title),
        app_id: changed(&before.app_id, &now.app_id),
        icon: if before.icon != now.icon { now.icon.clone() } else { None },
        geometry: changed(&before.geometry, &now.geometry),
        min: if before.min != now.min { now.min.or(Some(proto::Size { w: 0, h: 0 })) } else { None },
        max: if before.max != now.max { now.max.or(Some(proto::Size { w: 0, h: 0 })) } else { None },
        fullscreen: changed(&before.fullscreen, &now.fullscreen),
        display: if before.display != now.display { now.display } else { None },
        xwayland: changed(&before.xwayland, &now.xwayland),
        alpha: changed(&before.alpha, &now.alpha),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create() -> proto::WindowCreate {
        proto::WindowCreate {
            id: 3,
            parent: None,
            kind: WindowKind::Toplevel,
            title: "a".into(),
            app_id: "x".into(),
            icon: None,
            geometry: Rect::new(0, 0, 10, 10),
            min: Some(proto::Size { w: 5, h: 5 }),
            max: None,
            fullscreen: false,
            display: Some(1),
            xwayland: false,
            alpha: false,
        }
    }

    #[test]
    fn diff_carries_only_changes() {
        let a = create();
        let mut b = a.clone();
        assert!(diff(&a, &b).is_empty());
        b.title = "b".into();
        b.geometry = Rect::new(1, 2, 30, 40);
        let d = diff(&a, &b);
        assert_eq!(d.title.as_deref(), Some("b"));
        assert_eq!(d.geometry, Some(Rect::new(1, 2, 30, 40)));
        assert_eq!(d.app_id, None);
    }

    #[test]
    fn a_cleared_size_hint_is_sent_as_zero() {
        let a = create();
        let mut b = a.clone();
        b.min = None;
        assert_eq!(diff(&a, &b).min, Some(proto::Size { w: 0, h: 0 }));
    }
}
