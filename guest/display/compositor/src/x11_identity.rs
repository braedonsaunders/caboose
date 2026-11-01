//! What an X11 window says about the application behind it, beyond what Smithay's window
//! manager reads: its icon (`_NET_WM_ICON`, kept current as the application changes it)
//! and the process the X server knows created it.
//!
//! `_NET_WM_PID` is the client's own claim, in the client's PID namespace: a game in
//! Flatpak's Steam names a process of the sandbox, not of the computer. The X server's
//! record (X-Resource `LocalClientPID`) names the process as the computer sees it.
use crate::state::State;
use crate::windows::Surface;
use smithay::reexports::calloop::{
    generic::Generic,
    ping::{make_ping, Ping},
    Interest, Mode, PostAction,
};
use std::collections::HashSet;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use x11rb::{
    connection::Connection,
    protocol::{
        res::{ClientIdMask, ClientIdSpec, ConnectionExt as _},
        xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, EventMask, Window},
        Event,
    },
    rust_connection::{DefaultStream, RustConnection},
};

type Error = Box<dyn std::error::Error + Send + Sync>;

/// The largest `_NET_WM_ICON` read, in 32-bit items: a 256-pixel image and every smaller
/// size an application commonly adds.
const MAX_ICON_ITEMS: u32 = 128 * 1024;

pub struct X11Identity {
    conn: RustConnection,
    net_wm_icon: u32,
    resource: bool,
    wake: Ping,
}

impl X11Identity {
    pub fn install(state: &mut State, display: u32, cookie: &[u8; 16]) -> Result<(), Error> {
        let socket = UnixStream::connect(format!("/tmp/.X11-unix/X{display}"))?;
        let (stream, _) = DefaultStream::from_unix_stream(socket)?;
        let conn = RustConnection::connect_to_stream_with_auth_info(
            stream,
            0,
            b"MIT-MAGIC-COOKIE-1".to_vec(),
            cookie.to_vec(),
        )?;
        let net_wm_icon = conn.intern_atom(false, b"_NET_WM_ICON")?.reply()?.atom;
        let resource = conn.res_query_version(1, 2).ok().and_then(|c| c.reply().ok())
            .is_some_and(|v| (v.server_major, v.server_minor) >= (1, 2));
        let fd = conn.stream().as_fd().try_clone_to_owned()?;
        let (wake, wake_source) = make_ping()?;
        state.handle.insert_source(wake_source, |_, _, state: &mut State| {
            state.drain_x11_identity();
        })?;
        state.handle.insert_source(Generic::new(fd, Interest::READ, Mode::Level), |_, _, state: &mut State| {
            Ok(if state.drain_x11_identity() { PostAction::Continue } else { PostAction::Remove })
        })?;
        state.x11_identity = Some(Self { conn, net_wm_icon, resource, wake });
        Ok(())
    }

    /// Follows `window`'s icon from now on; answers its icon and the PID of its creator.
    fn watch(&self, window: Window) -> Result<(Option<Vec<u8>>, Option<u32>), Error> {
        // Selected before reading, so a change after the read is never missed.
        self.conn
            .change_window_attributes(window, &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE))?
            .check()?;
        let icon = self.icon(window)?;
        let pid = if self.resource { self.client_pid(window)? } else { None };
        Ok((icon, pid))
    }

    fn icon(&self, window: Window) -> Result<Option<Vec<u8>>, Error> {
        let reply = self.conn.get_property(false, window, self.net_wm_icon, AtomEnum::CARDINAL, 0, MAX_ICON_ITEMS)?.reply()?;
        let Some(value) = reply.value32() else { return Ok(None) };
        let value: Vec<u32> = value.collect();
        Ok(crate::icons::from_net_wm_icon(&value))
    }

    fn client_pid(&self, window: Window) -> Result<Option<u32>, Error> {
        let spec = ClientIdSpec { client: window, mask: ClientIdMask::LOCAL_CLIENT_PID };
        let reply = self.conn.res_query_client_ids(&[spec])?.reply()?;
        Ok(reply.ids.iter().find(|id| id.spec.mask == ClientIdMask::LOCAL_CLIENT_PID).and_then(|id| match id.value[..] {
            [pid] if pid > 0 => Some(pid),
            _ => None,
        }))
    }

    /// The windows whose icon changed since the last call.
    fn changed(&self) -> Result<HashSet<Window>, Error> {
        let mut windows = HashSet::new();
        for _ in 0..256 {
            let Some(event) = self.conn.poll_for_event()? else { return Ok(windows) };
            if let Event::PropertyNotify(n) = event {
                if n.atom == self.net_wm_icon {
                    windows.insert(n.window);
                }
            }
        }
        // More may be buffered: come back on the next turn, bounding the work per turn.
        self.wake.ping();
        Ok(windows)
    }
}

impl State {
    fn drain_x11_identity(&mut self) -> bool {
        let Some(identity) = &self.x11_identity else { return false };
        let changed = match identity.changed() {
            Ok(changed) => changed,
            Err(error) => {
                tracing::warn!("X11 identity connection: {error}");
                self.x11_identity = None;
                return false;
            }
        };
        for id in self.windows.ids() {
            let Some(w) = self.windows.get(id) else { continue };
            let Surface::X11(x) = &w.surface else { continue };
            if !w.identified || !changed.contains(&x.window_id()) {
                continue;
            }
            // A window destroyed meanwhile has no icon to read; it is retracted anyway.
            let icon = identity.icon(x.window_id()).ok().flatten();
            if let Some(w) = self.windows.get_mut(id) {
                w.icon = icon;
            }
        }
        true
    }

    /// Reads, once, what the X server says about a top-level X11 window: its icon, and the
    /// process that created it, which then stands for the window's process (its lineage).
    pub(crate) fn identify_x11(&mut self, id: u64) {
        let Some(w) = self.windows.get(id) else { return };
        let Surface::X11(x) = &w.surface else { return };
        if w.identified || w.parent.is_some() || x.is_override_redirect() {
            return;
        }
        let Some(identity) = &self.x11_identity else { return };
        let window = x.window_id();
        let (icon, pid) = match identity.watch(window) {
            Ok(found) => found,
            Err(error) => {
                tracing::debug!("X11 window {window:#x}: {error}");
                (None, None)
            }
        };
        let w = self.windows.get_mut(id).unwrap();
        w.identified = true;
        w.icon = icon;
        if let Some(pid) = pid {
            w.lineage = Some(crate::video::lineage(pid));
        }
    }
}
