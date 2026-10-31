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

    /// The top-level in `toplevels` that `window` is, or that it covers exactly, with the
    /// PID of the X client that created `window`. None when it is neither, or unknown.
    pub fn resolve(&self, window: Window, toplevels: &[Window]) -> Result<Option<(Window, u32)>, Error> {
        let Some(toplevel) = self.toplevel_of(window, toplevels)? else { return Ok(None) };
        if window != toplevel && !self.covers(window, toplevel)? {
            return Ok(None);
        }
        Ok(self.client_pid(window)?.map(|pid| (toplevel, pid)))
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

    /// The window lies at the top-level's origin and has its size, so its pictures are
    /// the top-level's whole content.
    fn covers(&self, window: Window, toplevel: Window) -> Result<bool, Error> {
        let inner = self.conn.get_geometry(window)?.reply()?;
        let outer = self.conn.get_geometry(toplevel)?.reply()?;
        let at = self.conn.translate_coordinates(window, toplevel, 0, 0)?.reply()?;
        Ok(at.same_screen && (at.dst_x, at.dst_y) == (0, 0) && (inner.width, inner.height) == (outer.width, outer.height))
    }

    fn client_pid(&self, window: Window) -> Result<Option<u32>, Error> {
        let spec = ClientIdSpec { client: window, mask: ClientIdMask::LOCAL_CLIENT_PID };
        let reply = self.conn.res_query_client_ids(&[spec])?.reply()?;
        Ok(local_client_pid(reply.ids.iter().map(|id| (id.spec.mask, id.value.as_slice()))))
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
