//! EWMH foreground follows the compositor seat, including globally active X11 clients.
//!
//! Smithay 0.7 writes FocusOut's event window into _NET_ACTIVE_WINDOW. Root/ancestor
//! notifications can consequently replace the focused client. Observe that property
//! and reconcile it on events; never alter X input focus or poll on a timer.
use crate::state::{KeyboardFocus, State};
use smithay::reexports::calloop::{
    generic::Generic,
    ping::{make_ping, Ping},
    Interest, Mode, PostAction,
};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use x11rb::{
    connection::Connection,
    protocol::{
        xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt, EventMask, PropMode},
        Event,
    },
    rust_connection::{DefaultStream, RustConnection},
    wrapper::ConnectionExt as _,
};

type Error = Box<dyn std::error::Error + Send + Sync>;

pub struct Foreground {
    conn: RustConnection,
    root: u32,
    atom: u32,
    wake: Ping,
}

impl Foreground {
    pub fn install(state: &mut State, display: u32, cookie: &[u8; 16]) -> Result<(), Error> {
        let socket = UnixStream::connect(format!("/tmp/.X11-unix/X{display}"))?;
        let (stream, _) = DefaultStream::from_unix_stream(socket)?;
        let conn = RustConnection::connect_to_stream_with_auth_info(
            stream,
            0,
            b"MIT-MAGIC-COOKIE-1".to_vec(),
            cookie.to_vec(),
        )?;
        let root = conn.setup().roots[0].root;
        let atom = conn.intern_atom(false, b"_NET_ACTIVE_WINDOW")?.reply()?.atom;
        conn.change_window_attributes(root, &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE))?
            .check()?;
        let fd = conn.stream().as_fd().try_clone_to_owned()?;
        let (wake, wake_source) = make_ping()?;
        let foreground = Self { conn, root, atom, wake };
        foreground.sync(state.active_x11_window())?;
        state.handle.insert_source(wake_source, |_, _, state: &mut State| {
            state.drain_x11_foreground();
        })?;
        state.handle.insert_source(Generic::new(fd, Interest::READ, Mode::Level), |_, _, state: &mut State| {
            Ok(if state.drain_x11_foreground() { PostAction::Continue } else { PostAction::Remove })
        })?;
        state.x11_foreground = Some(foreground);
        Ok(())
    }

    fn sync(&self, desired: u32) -> Result<(), Error> {
        let reply = self.conn.get_property(false, self.root, self.atom, AtomEnum::WINDOW, 0, 1)?.reply()?;
        let current = reply.value32().and_then(|mut values| values.next());
        if needs_update(current, desired) {
            self.conn.change_property32(PropMode::REPLACE, self.root, self.atom, AtomEnum::WINDOW, &[desired])?;
            self.conn.flush()?;
        }
        // Also drain notifications queued by this synchronous reply on focus changes.
        self.wake.ping();
        Ok(())
    }

    fn dispatch(&self, desired: u32) -> Result<(), Error> {
        for _ in 0..64 {
            let Some(event) = self.conn.poll_for_event()? else { return Ok(()) };
            if matches!(event, Event::PropertyNotify(n) if n.window == self.root && n.atom == self.atom) {
                self.sync(desired)?;
            }
        }
        // x11rb may have buffered notifications while waiting for a reply. Wake the
        // next dispatch even if the socket has no unread bytes; bound work per turn.
        self.wake.ping();
        Ok(())
    }
}

fn needs_update(current: Option<u32>, desired: u32) -> bool {
    current != Some(desired)
}

impl State {
    fn drain_x11_foreground(&mut self) -> bool {
        let Some(foreground) = &self.x11_foreground else { return false };
        if let Err(error) = foreground.dispatch(self.active_x11_window()) {
            tracing::warn!("X11 foreground connection: {error}");
            self.x11_foreground = None;
            return false;
        }
        true
    }

    pub(crate) fn active_x11_window(&self) -> u32 {
        match self.seat.get_keyboard().and_then(|keyboard| keyboard.current_focus()) {
            Some(KeyboardFocus::X11(window)) if window.alive() => window.window_id(),
            _ => 0,
        }
    }

    pub(crate) fn sync_x11_foreground(&self, focused: Option<&KeyboardFocus>) {
        let desired = match focused {
            Some(KeyboardFocus::X11(window)) if window.alive() => window.window_id(),
            _ => 0,
        };
        if let Some(foreground) = &self.x11_foreground {
            if let Err(error) = foreground.sync(desired) {
                tracing::warn!("X11 foreground update: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_root_or_previous_window_is_replaced() {
        assert!(needs_update(Some(0x240), 42));
        assert!(needs_update(Some(41), 42));
        assert!(needs_update(None, 42));
    }
    #[test]
    fn wayland_or_no_focus_clears_x11_foreground() {
        assert!(needs_update(Some(42), 0));
        assert!(!needs_update(Some(0), 0));
    }
    #[test]
    fn own_property_notification_converges_without_another_write() {
        assert!(!needs_update(Some(42), 42));
    }
}
