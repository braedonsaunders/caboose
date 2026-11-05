//! The X11 side of a live GPU surface bind. A Vulkan swapchain on an X11 window names
//! the window it was created for: a managed top-level, a child window that covers one
//! (Chromium's GPU process draws into such a child), or a child inset in one (a browser
//! view CEF draws in its own child window), which the phone shows as a child window of
//! the top-level (docs/display.md, "Child windows"). A bind of an override-redirect window
//! that is not bindable yet (not mapped yet) is held until it is (gpu_pending.rs). Only the
//! X server's own record of the process that created the window is authority, never a
//! window property.
use std::os::unix::net::UnixStream;
use x11rb::{
    connection::Connection,
    protocol::{
        res::{ClientIdMask, ClientIdSpec, ConnectionExt as _},
        xproto::{ChangeWindowAttributesAux, ConnectionExt as _, EventMask, MapState, Window},
        Event,
    },
    rust_connection::{DefaultStream, RustConnection},
};

type Error = Box<dyn std::error::Error + Send + Sync>;

/// Child windows nest a few levels at most; a deeper chain is not a surface to bind.
const MAX_DEPTH: usize = 16;

pub struct X11Windows {
    conn: RustConnection,
    root: Window,
}

impl X11Windows {
    pub fn connect(display: u32, cookie: &[u8; 16]) -> Result<Self, Error> {
        let socket = UnixStream::connect(format!("/tmp/.X11-unix/X{display}"))?;
        let (stream, _) = DefaultStream::from_unix_stream(socket)?;
        let conn = RustConnection::connect_to_stream_with_auth_info(
            stream,
            0,
            b"MIT-MAGIC-COOKIE-1".to_vec(),
            cookie.to_vec(),
        )?;
        let root = conn.setup().roots[0].root;
        // The X server's client records need X-Resource 1.2 (LocalClientPID).
        let version = conn.res_query_version(1, 2)?.reply()?;
        if (version.server_major, version.server_minor) < (1, 2) {
            return Err("X-Resource 1.2 is unavailable".into());
        }
        Ok(Self { conn, root })
    }

    /// The top-level in `toplevels` that `window` is, covers or is inset in, with the PID of
    /// the X client that created `window`, whether `window` is larger than the top-level and
    /// whether it is inset in it. None when it is in none of them, or unknown. X11 windows are in display pixels at `scale`
    /// (x11_scale.rs) while the compositor sizes top-levels in whole logical pixels, so a
    /// child sized to an odd display (a full-screen game's, 911 pixels high at scale 2) may
    /// fall short of its top-level by less than a logical pixel. A game's child sized to the
    /// screen may also be larger than a top-level the phone holds smaller (a maximized
    /// window below Laptop's title bar).
    pub fn resolve(&self, window: Window, toplevels: &[Window], scale: f64) -> Result<Option<Resolved>, Error> {
        let Some(toplevel) = self.toplevel_of(window, toplevels)? else { return Ok(None) };
        let (mut larger, mut inset) = (false, false);
        if window != toplevel {
            match self.covers(window, toplevel, scale)? {
                Cover::No => inset = true,
                Cover::Exactly => {}
                Cover::Larger => larger = true,
            }
        }
        Ok(self.client_pid(window)?.map(|pid| Resolved { toplevel, pid, larger, inset }))
    }

    /// Whether a bind of `window` by process `pid` is held until the window is bindable
    /// (gpu_pending.rs): the window exists in an override-redirect window (or is one) that
    /// no top-level in `toplevels` holds yet, because it is not mapped or the compositor has
    /// not taken in its map yet, and the X server records `pid` as the client that created it.
    pub fn holds_until_bindable(&self, window: Window, toplevels: &[Window], pid: u32) -> Result<bool, Error> {
        if self.toplevel_of(window, toplevels)?.is_some() { return Ok(false); }
        // A window still in the tree (destroyed ones are not).
        if self.outermost(window)?.is_none() { return Ok(false); }
        Ok(crate::gpu_pending::holdable(self.client_pid(window)?, pid))
    }

    /// The child of the root window that `window` is or is in.
    fn outermost(&self, window: Window) -> Result<Option<Window>, Error> {
        let mut current = window;
        for _ in 0..MAX_DEPTH {
            let parent = self.conn.query_tree(current)?.reply()?.parent;
            if parent == self.root { return Ok(Some(current)); }
            if parent == x11rb::NONE { return Ok(None); }
            current = parent;
        }
        Ok(None)
    }

    /// Where an inset child is in its top-level now, in X pixels relative to the top-level:
    /// its rectangle, the part of it its ancestors show, and its place in the top-level's
    /// stacking among `bound` (bottom first). None when it or an ancestor is unmapped or it
    /// has left the top-level. It and its ancestors report their changes from now on
    /// (`changed`).
    pub fn placement(&self, child: Window, toplevel: Window, bound: &[Window]) -> Result<Option<Placement>, Error> {
        let mut chain = vec![child];
        let mut current = child;
        let mut inside = false;
        for _ in 0..MAX_DEPTH {
            let parent = self.conn.query_tree(current)?.reply()?.parent;
            if parent == toplevel { inside = true; break; }
            if parent == x11rb::NONE || parent == self.root { break; }
            chain.push(parent);
            current = parent;
        }
        if !inside { return Ok(None); }
        // Selected before reading, so a change after the read is never missed.
        for (i, window) in chain.iter().chain(std::iter::once(&toplevel)).enumerate() {
            let mask = if i == 0 { EventMask::STRUCTURE_NOTIFY } else { EventMask::STRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_NOTIFY };
            self.conn.change_window_attributes(*window, &ChangeWindowAttributesAux::new().event_mask(mask))?.check()?;
        }
        let mut clip: Option<Rect> = None;
        let mut rect = None;
        for window in &chain {
            if self.conn.get_window_attributes(*window)?.reply()?.map_state != MapState::VIEWABLE {
                return Ok(None);
            }
            let geometry = self.conn.get_geometry(*window)?.reply()?;
            let at = self.conn.translate_coordinates(*window, toplevel, 0, 0)?.reply()?;
            if !at.same_screen { return Ok(None); }
            let r = Rect { x: at.dst_x.into(), y: at.dst_y.into(), w: geometry.width.into(), h: geometry.height.into() };
            if rect.is_none() { rect = Some(r); }
            clip = Some(clip.map_or(r, |c| c.intersect(r)));
        }
        let outer = self.conn.get_geometry(toplevel)?.reply()?;
        let clip = clip.unwrap_or_default().intersect(Rect { x: 0, y: 0, w: outer.width.into(), h: outer.height.into() });
        let order = self.stacking(toplevel)?;
        let stack = order.iter().filter(|w| bound.contains(w)).position(|w| *w == child).unwrap_or(0) as u32;
        Ok(rect.map(|rect| Placement { rect, clip, stack }))
    }

    /// The top-level's descendants, bottom of the stacking first (a window below its children).
    fn stacking(&self, toplevel: Window) -> Result<Vec<Window>, Error> {
        let mut out = Vec::new();
        let mut frontier = vec![(toplevel, 0usize)];
        while let Some((window, depth)) = frontier.pop() {
            if window != toplevel { out.push(window); }
            if depth >= MAX_DEPTH { continue; }
            // Bottom first: popped last-in first, so push the topmost first.
            for child in self.conn.query_tree(window)?.reply()?.children.into_iter().rev() {
                frontier.push((child, depth + 1));
            }
        }
        Ok(out)
    }

    /// Whether any window this connection follows changed (moved, resized, restacked,
    /// mapped, unmapped, reparented or destroyed) since the last call; drains the events.
    pub fn changed(&self) -> Result<bool, Error> {
        let mut changed = false;
        for _ in 0..1024 {
            match self.conn.poll_for_event()? {
                None => break,
                Some(Event::ConfigureNotify(_) | Event::MapNotify(_) | Event::UnmapNotify(_) |
                     Event::DestroyNotify(_) | Event::ReparentNotify(_) | Event::GravityNotify(_) |
                     Event::CirculateNotify(_)) => changed = true,
                Some(_) => {}
            }
        }
        Ok(changed)
    }

    /// The connection's descriptor, for the event loop.
    pub fn fd(&self) -> std::io::Result<std::os::fd::OwnedFd> {
        use std::os::fd::AsFd;
        self.conn.stream().as_fd().try_clone_to_owned()
    }

    fn toplevel_of(&self, window: Window, toplevels: &[Window]) -> Result<Option<Window>, Error> {
        let mut current = window;
        for _ in 0..MAX_DEPTH {
            if toplevels.contains(&current) {
                return Ok(Some(current));
            }
            let parent = self.conn.query_tree(current)?.reply()?.parent;
            if parent == x11rb::NONE || parent == self.root {
                return Ok(None);
            }
            current = parent;
        }
        Ok(None)
    }

    /// Whether the window lies at the top-level's origin with at least its size, to within a
    /// logical pixel, so its pictures hold the top-level's whole content.
    fn covers(&self, window: Window, toplevel: Window, scale: f64) -> Result<Cover, Error> {
        let inner = self.conn.get_geometry(window)?.reply()?;
        let outer = self.conn.get_geometry(toplevel)?.reply()?;
        let at = self.conn.translate_coordinates(window, toplevel, 0, 0)?.reply()?;
        if !at.same_screen {
            return Ok(Cover::No);
        }
        Ok(covers((at.dst_x, at.dst_y), (inner.width, inner.height), (outer.width, outer.height), scale))
    }

    /// Why `window` does not bind for `pid`, for the log: no bindable top-level above it
    /// (its X ancestors), a child that does not cover its top-level (both geometries), or
    /// a window another process made.
    pub fn refusal(&self, window: Window, toplevels: &[Window], scale: f64, pid: u32) -> String {
        self.explain(window, toplevels, scale, pid).unwrap_or_else(|error| format!("the X server could not say: {error}"))
    }

    fn explain(&self, window: Window, toplevels: &[Window], scale: f64, pid: u32) -> Result<String, Error> {
        let Some(toplevel) = self.toplevel_of(window, toplevels)? else {
            let mut ancestors = Vec::new();
            let mut current = window;
            for _ in 0..MAX_DEPTH {
                let parent = self.conn.query_tree(current)?.reply()?.parent;
                if parent == x11rb::NONE || parent == self.root {
                    break;
                }
                ancestors.push(format!("{parent:#x}"));
                current = parent;
            }
            return Ok(format!("no bindable top-level holds it (its ancestors: [{}]; bindable: {:x?})",
                              ancestors.join(", "), toplevels));
        };
        if window != toplevel {
            let inner = self.conn.get_geometry(window)?.reply()?;
            let outer = self.conn.get_geometry(toplevel)?.reply()?;
            let at = self.conn.translate_coordinates(window, toplevel, 0, 0)?.reply()?;
            if !at.same_screen ||
                covers((at.dst_x, at.dst_y), (inner.width, inner.height), (outer.width, outer.height), scale) == Cover::No {
                return Ok(format!("it is {}x{} at ({}, {}) in top-level {toplevel:#x} of {}x{} (scale {scale})",
                                  inner.width, inner.height, at.dst_x, at.dst_y, outer.width, outer.height));
            }
        }
        Ok(match self.client_pid(window)? {
            Some(maker) if maker != pid => format!("process {maker} made it, under top-level {toplevel:#x}"),
            Some(_) => format!("it binds to top-level {toplevel:#x} (the process changed meanwhile)"),
            None => "the X server does not know which process made it".into(),
        })
    }

    fn client_pid(&self, window: Window) -> Result<Option<u32>, Error> {
        let spec = ClientIdSpec { client: window, mask: ClientIdMask::LOCAL_CLIENT_PID };
        let reply = self.conn.res_query_client_ids(&[spec])?.reply()?;
        Ok(local_client_pid(reply.ids.iter().map(|id| (id.spec.mask, id.value.as_slice()))))
    }
}

/// A bound X11 window's top-level, the bound process, whether the window is larger than
/// the top-level (its window should grow to the display to show all of it) and whether it
/// is inset in it (a child window of the top-level on the phone).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Resolved {
    pub toplevel: Window,
    pub pid: u32,
    pub larger: bool,
    pub inset: bool,
}

/// A rectangle in X pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    /// The overlap of two rectangles; empty (zero-sized, at the first's origin) when none.
    pub fn intersect(self, other: Rect) -> Rect {
        let (x0, y0) = (self.x.max(other.x), self.y.max(other.y));
        let (x1, y1) = ((self.x + self.w).min(other.x + other.w), (self.y + self.h).min(other.y + other.h));
        if x1 <= x0 || y1 <= y0 { Rect { x: self.x, y: self.y, w: 0, h: 0 } } else { Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } }
    }
}

/// An inset child's place in its top-level (`X11Windows::placement`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub rect: Rect,
    pub clip: Rect,
    pub stack: u32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Cover {
    No,
    /// The top-level's size, to within a logical pixel.
    Exactly,
    /// Larger than the top-level on at least one side, and covering it on the other.
    Larger,
}

/// Whether a child at `at` in its top-level, of size `inner`, covers a top-level of size
/// `outer`: at its origin, and no more than the rounding of one logical pixel at `scale`
/// smaller in either direction. A larger child covers it too: it is a game's swapchain
/// sized to the screen in a top-level held smaller.
fn covers(at: (i16, i16), inner: (u16, u16), outer: (u16, u16), scale: f64) -> Cover {
    let slack = if scale.is_finite() && scale > 1.0 { scale.ceil() as u16 - 1 } else { 0 };
    let reaches = |inner: u16, outer: u16| inner >= outer || outer - inner <= slack;
    if at != (0, 0) || !reaches(inner.0, outer.0) || !reaches(inner.1, outer.1) {
        Cover::No
    } else if inner.0 > outer.0 || inner.1 > outer.1 {
        Cover::Larger
    } else {
        Cover::Exactly
    }
}

/// The one LocalClientPID record, if the X server reported exactly one.
fn local_client_pid<'a>(ids: impl Iterator<Item = (ClientIdMask, &'a [u32])>) -> Option<u32> {
    let mut pids = ids.filter(|(mask, _)| mask.contains(ClientIdMask::LOCAL_CLIENT_PID)).map(|(_, value)| value);
    match (pids.next(), pids.next()) {
        (Some(&[pid]), None) if pid != 0 => Some(pid),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_child_covers_its_toplevel_to_within_a_logical_pixel() {
        use Cover::*;
        // Exactly, at any scale.
        assert_eq!(covers((0, 0), (1338, 912), (1338, 912), 1.0), Exactly);
        assert_eq!(covers((0, 0), (1338, 912), (1338, 912), 2.0), Exactly);
        // A full-screen game's child on a 911-pixel display, its top-level 456 logical pixels at 2.
        assert_eq!(covers((0, 0), (1338, 911), (1338, 912), 2.0), Exactly);
        assert_eq!(covers((0, 0), (1338, 911), (1338, 912), 1.0), No);
        // Up to two pixels at scale 3, one at a fractional scale below 2.
        assert_eq!(covers((0, 0), (930, 1354), (932, 1356), 3.0), Exactly);
        assert_eq!(covers((0, 0), (929, 1356), (932, 1356), 3.0), No);
        assert_eq!(covers((0, 0), (1599, 900), (1600, 900), 1.5), Exactly);
        assert_eq!(covers((0, 0), (1598, 900), (1600, 900), 1.5), No);
        // Never offset, and no slack for a scale that is not one.
        assert_eq!(covers((1, 0), (1338, 912), (1338, 912), 2.0), No);
        assert_eq!(covers((0, 0), (1337, 912), (1338, 912), f64::NAN), No);
        assert_eq!(covers((0, 0), (1337, 912), (1338, 912), 0.5), No);
    }

    #[test]
    fn a_screen_sized_child_covers_a_toplevel_held_smaller() {
        use Cover::*;
        // Halo: The Master Chief Collection's swapchain child at the 1338x911 screen in a
        // top-level maximized below Laptop's title bar, 1338x848.
        assert_eq!(covers((0, 0), (1338, 911), (1338, 848), 2.0), Larger);
        assert_eq!(covers((0, 0), (1339, 912), (1338, 912), 2.0), Larger);
        // Larger on one side does not make up for falling short on the other.
        assert_eq!(covers((0, 0), (1338, 911), (1300, 960), 2.0), No);
        assert_eq!(covers((0, 4), (1338, 911), (1338, 848), 2.0), No);
    }

    #[test]
    fn a_child_is_cut_by_what_holds_it() {
        let view = Rect { x: 1, y: 184, w: 1338, h: 900 };
        let frame = Rect { x: 0, y: 0, w: 1340, h: 912 };
        assert_eq!(view.intersect(frame), Rect { x: 1, y: 184, w: 1338, h: 728 });
        assert_eq!(view.intersect(Rect { x: 2000, y: 0, w: 10, h: 10 }), Rect { x: 1, y: 184, w: 0, h: 0 });
    }

    #[test]
    fn exactly_one_nonzero_local_pid_is_an_answer() {
        let pid = ClientIdMask::LOCAL_CLIENT_PID;
        let xid = ClientIdMask::CLIENT_XID;
        assert_eq!(local_client_pid([(xid, &[0x400000][..]), (pid, &[42][..])].into_iter()), Some(42));
        assert_eq!(local_client_pid([(pid, &[0][..])].into_iter()), None);
        assert_eq!(local_client_pid([(pid, &[42][..]), (pid, &[43][..])].into_iter()), None);
        assert_eq!(local_client_pid([(pid, &[42, 43][..])].into_iter()), None);
        assert_eq!(local_client_pid([(xid, &[0x400000][..])].into_iter()), None);
    }
}
