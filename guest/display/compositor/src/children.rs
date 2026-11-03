//! Child windows: an application's own GPU surface inset in one of its windows, a browser
//! view CEF draws in an X11 child window or a Wayland subsurface (docs/display.md, "Child
//! windows"). The phone shows each as a sublayer of its parent's picture, so its frames reach
//! the screen without passing through the parent's. A child exists while its surface is
//! granted; the compositor follows where it is and tells the client on every change.
use crate::state::State;
use caboose_display_protocol::{self as proto, Rect, WindowKind};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::Resource;
use smithay::wayland::compositor::{get_parent, with_states, with_surface_tree_downward, SubsurfaceCachedState, TraversalAction};
use std::collections::BTreeMap;

/// What a child is on the computer.
pub enum Source {
    /// An X11 window inset in the parent's X11 top-level.
    X11 { window: u32, toplevel: u32 },
    /// A subsurface in the parent's surface tree.
    Subsurface(WlSurface),
}

/// Where a child is: its geometry and the part its parent shows, relative to the parent's
/// geometry in display pixels, and its order among the parent's children, lowest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Place {
    pub geometry: Rect,
    pub clip: Rect,
    pub stack: u32,
}

pub struct Child {
    pub parent: u64,
    pub source: Source,
    /// Where it was last found; none while it is not shown (unmapped, or not found).
    pub place: Option<Place>,
    /// Its X11 window changed since `place` was read.
    pub dirty: bool,
    pub announced: Option<proto::WindowCreate>,
}

#[derive(Default)]
pub struct Children {
    map: BTreeMap<u64, Child>,
}

impl Children {
    pub fn insert(&mut self, id: u64, child: Child) {
        self.map.insert(id, child);
    }
    pub fn remove(&mut self, id: u64) -> Option<Child> {
        self.map.remove(&id)
    }
    pub fn get(&self, id: u64) -> Option<&Child> {
        self.map.get(&id)
    }
    pub fn ids(&self) -> Vec<u64> {
        self.map.keys().copied().collect()
    }
    pub fn by_x11(&self, window: u32) -> Option<u64> {
        self.map.iter().find(|(_, c)| matches!(c.source, Source::X11 { window: w, .. } if w == window)).map(|(id, _)| *id)
    }
    pub fn by_surface(&self, surface: &WlSurface) -> Option<u64> {
        self.map.iter().find(|(_, c)| matches!(&c.source, Source::Subsurface(s) if s == surface)).map(|(id, _)| *id)
    }
    /// The X11 windows of the children inset in `toplevel`.
    fn x11_of(&self, toplevel: u32) -> Vec<u32> {
        self.map.values().filter_map(|c| match c.source {
            Source::X11 { window, toplevel: t } if t == toplevel => Some(window),
            _ => None,
        }).collect()
    }
    /// Every X11 child is read again: something in some top-level changed.
    pub fn x11_changed(&mut self) {
        for child in self.map.values_mut() {
            if matches!(child.source, Source::X11 { .. }) { child.dirty = true; }
        }
    }
}

/// The child as the protocol describes it, under its parent's description.
pub fn describe(id: u64, child: &Child, place: Place, parent: &proto::WindowCreate) -> proto::WindowCreate {
    proto::WindowCreate {
        id,
        parent: Some(child.parent),
        kind: WindowKind::Child,
        title: String::new(),
        app_id: parent.app_id.clone(),
        icon: None,
        geometry: place.geometry,
        min: None,
        max: None,
        fullscreen: false,
        display: parent.display,
        xwayland: parent.xwayland,
        alpha: false,
        desktop_id: None,
        pid: None,
        clip: Some(place.clip),
        stack: Some(place.stack),
    }
}

/// An X11 child's place: X11 windows are in display pixels, as the protocol's geometry is,
/// and an X11 top-level's geometry is the top-level itself.
fn x11_place(placement: crate::gpu_x11::Placement) -> Place {
    let rect = |r: crate::gpu_x11::Rect| Rect::new(r.x, r.y, r.w, r.h);
    Place { geometry: rect(placement.rect), clip: rect(placement.clip), stack: placement.stack }
}

/// Where a subsurface is in its window, in logical pixels relative to the window geometry,
/// and its size; none while it has no size.
fn subsurface_rect(surface: &WlSurface, geometry: smithay::utils::Rectangle<i32, smithay::utils::Logical>)
    -> Option<smithay::utils::Rectangle<i32, smithay::utils::Logical>> {
    let size = smithay::backend::renderer::utils::with_renderer_surface_state(surface, |state| state.surface_size()).flatten()?;
    let mut location = smithay::utils::Point::<i32, smithay::utils::Logical>::from((0, 0));
    let mut current = surface.clone();
    while let Some(parent) = get_parent(&current) {
        location += with_states(&current, |states| states.cached_state.get::<SubsurfaceCachedState>().current().location);
        current = parent;
    }
    Some(smithay::utils::Rectangle::new(location - geometry.loc, size))
}

/// The surfaces of a window's tree, bottom first.
fn tree_order(root: &WlSurface) -> Vec<WlSurface> {
    let mut out = Vec::new();
    with_surface_tree_downward(root, (), |_, _, _| TraversalAction::DoChildren(()), |surface, _, _| out.push(surface.clone()), |_, _, _| true);
    out
}

/// Display pixels of a logical rectangle at `scale`, rounded as window geometry is.
fn to_px(r: smithay::utils::Rectangle<i32, smithay::utils::Logical>, scale: f64) -> Rect {
    let px = |v: i32| (f64::from(v) * scale).round() as i32;
    Rect::new(px(r.loc.x), px(r.loc.y), px(r.size.w), px(r.size.h))
}

fn intersect(a: Rect, b: Rect) -> Rect {
    let (x0, y0) = (a.x.max(b.x), a.y.max(b.y));
    let (x1, y1) = ((a.x + a.w).min(b.x + b.w), (a.y + a.h).min(b.y + b.h));
    if x1 <= x0 || y1 <= y0 { Rect::new(a.x, a.y, 0, 0) } else { Rect::new(x0, y0, x1 - x0, y1 - y0) }
}

impl State {
    /// The child for X11 window `window` inset in `toplevel`, the X11 top-level of window
    /// `parent`: the one already following it, or a new one. True when it is new.
    pub(crate) fn x11_child(&mut self, parent: u64, window: u32, toplevel: u32) -> (u64, bool) {
        if let Some(id) = self.children.by_x11(window).filter(|id| self.children.get(*id).is_some_and(|c| c.parent == parent)) {
            return (id, false);
        }
        let id = self.windows.reserve_id();
        self.children.insert(id, Child { parent, source: Source::X11 { window, toplevel }, place: None, dirty: true, announced: None });
        tracing::info!("child window {id}: X11 window {window:#x} inset in window {parent}");
        (id, true)
    }

    /// The child for subsurface `surface` of window `parent`, as `x11_child`.
    pub(crate) fn subsurface_child(&mut self, parent: u64, surface: &WlSurface) -> (u64, bool) {
        if let Some(id) = self.children.by_surface(surface) {
            return (id, false);
        }
        let id = self.windows.reserve_id();
        self.children.insert(id, Child { parent, source: Source::Subsurface(surface.clone()), place: None, dirty: true, announced: None });
        tracing::info!("child window {id}: a subsurface of window {parent}");
        (id, true)
    }

    /// The window of a child, or the window itself: the one whose display a bind is on.
    pub(crate) fn bind_window(&self, id: u64) -> Option<&crate::windows::Window> {
        self.windows.get(id).or_else(|| self.children.get(id).and_then(|c| self.windows.get(c.parent)))
    }

    /// Ends a child: its grant is revoked and the client told.
    pub(crate) fn end_child(&mut self, id: u64) {
        let revoke = self.gpu_grants.as_mut().and_then(|grants| grants.begin_revoke(id));
        if let Some(grant) = revoke {
            if self.queue_gpu_revoke(grant).is_err() { self.gpu_control_failed(); }
        }
        let Some(child) = self.children.remove(id) else { return };
        tracing::info!("child window {id} of window {} ended", child.parent);
        if child.announced.is_some() {
            if let Some(s) = &self.session {
                self.net.send(s.conn, &proto::Message::WindowDestroy { id });
            }
        }
    }

    /// Something in an X11 top-level a child is inset in changed.
    pub(crate) fn drain_gpu_x11(&mut self) -> bool {
        let Some(lookup) = &self.gpu_x11 else { return false };
        match lookup.changed() {
            Ok(true) => self.children.x11_changed(),
            Ok(false) => {}
            Err(error) => {
                tracing::warn!("GPU X11 window connection: {error}");
                self.gpu_x11 = None;
                return false;
            }
        }
        true
    }

    /// Announces, moves and ends the children, after their parents are announced.
    pub(crate) fn sync_children(&mut self) {
        let conn = self.session.as_ref().filter(|s| s.ready && s.children).map(|s| s.conn);
        for id in self.children.ids() {
            let Some(child) = self.children.get(id) else { continue };
            let parent = self.windows.get(child.parent);
            // A child lives while its surface is granted and its parent is there.
            let granted = self.gpu_grants.as_ref().is_some_and(|grants| grants.holds(id));
            if parent.is_none() || !granted {
                self.end_child(id);
                continue;
            }
            // Without a client that shows children it waits, announced again to the next.
            let Some(conn) = conn else {
                if let Some(child) = self.children.map.get_mut(&id) { child.announced = None; }
                continue;
            };
            let place = self.child_place(id);
            let Some(child) = self.children.get(id) else { continue };
            let parent_now = self.windows.get(child.parent).and_then(|p| p.announced.clone());
            let now = match (place, parent_now) {
                (Some(place), Some(parent)) => Some(describe(id, child, place, &parent)),
                _ => None,
            };
            let child = self.children.map.get_mut(&id).unwrap();
            child.place = place;
            match (now, &child.announced) {
                (None, Some(_)) => {
                    tracing::info!("child window {id} hidden");
                    self.net.send(conn, &proto::Message::WindowDestroy { id });
                    child.announced = None;
                }
                (None, None) => {}
                (Some(now), None) => {
                    tracing::info!("child window {id} shown at {:?}, clip {:?}, stack {:?}", now.geometry, now.clip, now.stack);
                    self.net.send(conn, &proto::Message::WindowCreate(now.clone()));
                    child.announced = Some(now);
                }
                (Some(now), Some(before)) => {
                    let update = crate::windows::diff(before, &now);
                    if !update.is_empty() {
                        self.net.send(conn, &proto::Message::WindowUpdate(update));
                        child.announced = Some(now);
                    }
                }
            }
        }
    }

    /// Where the child is now: an X11 child read again from the X server when it changed,
    /// a subsurface from its tree.
    fn child_place(&mut self, id: u64) -> Option<Place> {
        let child = self.children.get(id)?;
        match &child.source {
            Source::X11 { window, toplevel } => {
                if !child.dirty { return child.place; }
                let (window, toplevel) = (*window, *toplevel);
                let bound = self.children.x11_of(toplevel);
                let place = match self.gpu_x11.as_ref().map(|lookup| lookup.placement(window, toplevel, &bound)) {
                    Some(Ok(placement)) => placement.map(x11_place),
                    Some(Err(error)) => {
                        // The window is gone (its application destroyed it): nothing to show.
                        tracing::debug!("GPU X11 child {window:#x}: {error}");
                        None
                    }
                    None => None,
                };
                if let Some(child) = self.children.map.get_mut(&id) { child.dirty = false; }
                place
            }
            Source::Subsurface(surface) => {
                let surface = surface.clone();
                let parent = self.windows.get(child.parent)?;
                let root = parent.surface.wl_surface()?;
                if !surface.is_alive() { return None; }
                let order = tree_order(&root);
                order.iter().position(|s| *s == surface)?;
                let geometry = parent.local_geometry();
                let rect = subsurface_rect(&surface, geometry)?;
                let scale = self.displays.resolve(Some(parent.display)).info.scale;
                let px = to_px(rect, scale);
                let bound: Vec<&WlSurface> = order.iter().filter(|s| self.children.by_surface(s).is_some()).collect();
                let stack = bound.iter().position(|s| **s == surface).unwrap_or(0) as u32;
                let whole = to_px(smithay::utils::Rectangle::new((0, 0).into(), geometry.size), scale);
                Some(Place { geometry: px, clip: intersect(px, whole), stack })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parent() -> proto::WindowCreate {
        proto::WindowCreate {
            id: 12,
            parent: None,
            kind: WindowKind::Toplevel,
            title: "Steam".into(),
            app_id: "steam".into(),
            icon: None,
            geometry: Rect::new(0, 0, 1340, 912),
            min: None,
            max: None,
            fullscreen: false,
            display: Some(1),
            xwayland: true,
            alpha: false,
            desktop_id: Some("steam.desktop".into()),
            pid: Some(42),
            clip: None,
            stack: None,
        }
    }

    #[test]
    fn a_child_is_its_parents_with_its_own_place() {
        let child = Child { parent: 12, source: Source::X11 { window: 0x240000b, toplevel: 0x2e00048 }, place: None, dirty: false, announced: None };
        let place = x11_place(crate::gpu_x11::Placement {
            rect: crate::gpu_x11::Rect { x: 1, y: 184, w: 1338, h: 900 },
            clip: crate::gpu_x11::Rect { x: 1, y: 184, w: 1338, h: 728 },
            stack: 1,
        });
        let described = describe(16, &child, place, &parent());
        assert_eq!(described.kind, WindowKind::Child);
        assert_eq!(described.parent, Some(12));
        assert_eq!(described.app_id, "steam");
        assert_eq!(described.display, Some(1));
        assert_eq!(described.geometry, Rect::new(1, 184, 1338, 900));
        assert_eq!(described.clip, Some(Rect::new(1, 184, 1338, 728)));
        assert_eq!(described.stack, Some(1));
        assert!(described.title.is_empty() && described.icon.is_none() && described.pid.is_none() && described.desktop_id.is_none());
    }

    #[test]
    fn a_subsurface_is_cut_by_its_window() {
        assert_eq!(intersect(Rect::new(-4, 10, 100, 50), Rect::new(0, 0, 90, 40)), Rect::new(0, 10, 90, 30));
        assert_eq!(intersect(Rect::new(200, 10, 10, 10), Rect::new(0, 0, 90, 40)), Rect::new(200, 10, 0, 0));
        let r = smithay::utils::Rectangle::<i32, smithay::utils::Logical>::new((3, 5).into(), (100, 50).into());
        assert_eq!(to_px(r, 1.5), Rect::new(5, 8, 150, 75));
    }
}
