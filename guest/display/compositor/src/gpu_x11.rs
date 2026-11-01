//! The X11 side of a live GPU surface bind. A Vulkan swapchain on an X11 window names
//! the window it was created for: a managed top-level, or a child window that covers
//! one (Chromium's GPU process draws into such a child). Only the X server's own record
//! of the process that created the window is authority, never a window property.
use std::os::unix::net::UnixStream;
use x11rb::{
    connection::Connection,
    protocol::{
        res::{ClientIdMask, ClientIdSpec, ConnectionExt as _},
        xproto::{ConnectionExt as _, Window},
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

    /// The top-level in `toplevels` that `window` is, or that it covers, with the PID of the
    /// X client that created `window` and whether `window` is larger than the top-level.
    /// None when it is neither, or unknown. X11 windows are in display pixels at `scale`
    /// (x11_scale.rs) while the compositor sizes top-levels in whole logical pixels, so a
    /// child sized to an odd display (a full-screen game's, 911 pixels high at scale 2) may
    /// fall short of its top-level by less than a logical pixel. A game's child sized to the
    /// screen may also be larger than a top-level the phone holds smaller (a maximized
    /// window below Laptop's title bar).
    pub fn resolve(&self, window: Window, toplevels: &[Window], scale: f64) -> Result<Option<Resolved>, Error> {
        let Some(toplevel) = self.toplevel_of(window, toplevels)? else { return Ok(None) };
        let mut larger = false;
        if window != toplevel {
            match self.covers(window, toplevel, scale)? {
                Cover::No => return Ok(None),
                Cover::Exactly => {}
                Cover::Larger => larger = true,
            }
        }
        Ok(self.client_pid(window)?.map(|pid| Resolved { toplevel, pid, larger }))
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

    fn client_pid(&self, window: Window) -> Result<Option<u32>, Error> {
        let spec = ClientIdSpec { client: window, mask: ClientIdMask::LOCAL_CLIENT_PID };
        let reply = self.conn.res_query_client_ids(&[spec])?.reply()?;
        Ok(local_client_pid(reply.ids.iter().map(|id| (id.spec.mask, id.value.as_slice()))))
    }
}

/// A bound X11 window's top-level, the bound process, and whether the window is larger
/// than the top-level (its window should grow to the display to show all of it).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Resolved {
    pub toplevel: Window,
    pub pid: u32,
    pub larger: bool,
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
