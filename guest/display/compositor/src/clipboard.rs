//! The clipboard, between the phone, Wayland applications and X11 applications.
//!
//! Whoever copied last owns the selection:
//! - a Wayland client: its data source is the Wayland selection; X11 applications see it
//!   through Xwayland's window manager;
//! - an X11 application: the window manager announces it and the compositor offers it as
//!   its own Wayland selection ([`Owner::X11`]), reading from X11 on demand;
//! - the phone (`clipboard` from the client): the compositor holds the text and offers it
//!   to both ([`Owner::Phone`]).
//!
//! Text copied on the computer is read through a pipe on a short-lived thread and sent to
//! the phone; text from the phone is written to readers the same way, so a slow client
//! never blocks the compositor.

use crate::state::State;
use caboose_display_protocol::{self as proto, Message};
use smithay::reexports::calloop::channel::Sender;
use smithay::wayland::selection::data_device::{request_data_device_client_selection, set_data_device_selection};
use smithay::wayland::selection::{SelectionSource, SelectionTarget};
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::sync::Arc;

/// The protocol's clipboard type.
pub const MIME: &str = "text/plain;charset=utf-8";
/// Text types offered for the phone's text and looked for in the computer's, best first.
pub const TEXT_MIMES: &[&str] = &[MIME, "UTF8_STRING", "text/plain", "TEXT", "STRING"];
/// The most the phone is sent at once.
pub const MAX_BYTES: usize = 1024 * 1024;

/// Who provides a selection the compositor owns.
#[derive(Debug, Clone)]
pub enum Owner {
    X11,
    Phone(Arc<Vec<u8>>),
}

/// The best text type among those offered.
pub fn text_mime(offered: &[String]) -> Option<String> {
    TEXT_MIMES.iter().find(|m| offered.iter().any(|o| o == *m)).map(|m| m.to_string())
}

fn pipe() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills the two descriptors it is given.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: both descriptors are new and owned from here on.
    unsafe {
        Ok((
            <OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(fds[0]),
            <OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(fds[1]),
        ))
    }
}

/// Writes `data` to a reader's descriptor without blocking the loop.
pub fn write_to(fd: OwnedFd, data: Arc<Vec<u8>>) {
    std::thread::spawn(move || {
        let _ = std::fs::File::from(fd).write_all(&data);
    });
}

/// Reads what a source writes into a pipe, up to [`MAX_BYTES`], on a thread; the text
/// arrives on `done`.
fn read_from(read: OwnedFd, done: Sender<Vec<u8>>) {
    std::thread::spawn(move || {
        let mut data = Vec::new();
        let mut file = std::fs::File::from(read);
        let _ = (&mut file).take(MAX_BYTES as u64 + 1).read_to_end(&mut data);
        if data.len() <= MAX_BYTES && !data.is_empty() {
            let _ = done.send(data);
        }
    });
}

impl State {
    /// The phone copied: offer its text to Wayland and X11 applications.
    pub fn clipboard_from_phone(&mut self, c: proto::Clipboard) {
        if !c.mime.starts_with("text/plain") || c.data.len() > MAX_BYTES {
            return;
        }
        let data = Arc::new(c.data);
        self.clipboard.last_sent = Some(data.clone());
        let mimes: Vec<String> = TEXT_MIMES.iter().map(|m| m.to_string()).collect();
        set_data_device_selection(&self.dh, &self.seat, mimes.clone(), Owner::Phone(data));
        if let Some(xwm) = self.xwm.as_mut() {
            if let Err(e) = xwm.new_selection(SelectionTarget::Clipboard, Some(mimes)) {
                tracing::warn!("cannot offer the clipboard to X11: {e}");
            }
        }
    }

    /// A Wayland client copied: tell X11, and read the text for the phone.
    pub fn clipboard_from_wayland(&mut self, ty: SelectionTarget, source: Option<SelectionSource>) {
        if let Some(xwm) = self.xwm.as_mut() {
            if let Err(e) = xwm.new_selection(ty, source.as_ref().map(|s| s.mime_types())) {
                tracing::warn!("cannot offer the selection to X11: {e}");
            }
        }
        if ty != SelectionTarget::Clipboard {
            return;
        }
        let offered = source.map(|s| s.mime_types()).unwrap_or_default();
        tracing::debug!("clipboard: a Wayland client copied {offered:?}");
        let Some(mime) = text_mime(&offered) else { return };
        // Smithay reports the new selection before it records it as the seat's; ask for
        // the data once the request has been handled.
        self.handle.insert_idle(move |state| {
            let Ok((read, write)) = pipe() else { return };
            match request_data_device_client_selection(&state.seat, mime, write) {
                Ok(()) => read_from(read, state.clipboard.done.clone()),
                Err(e) => tracing::debug!("clipboard: cannot read the new selection: {e}"),
            }
        });
    }

    /// An X11 application copied: read the text for the phone.
    pub fn clipboard_from_x11(&mut self, mime_types: &[String]) {
        let Some(mime) = text_mime(mime_types) else { return };
        let Ok((read, write)) = pipe() else { return };
        let handle = self.handle.clone();
        let Some(xwm) = self.xwm.as_mut() else { return };
        if xwm.send_selection(SelectionTarget::Clipboard, mime, write, handle).is_ok() {
            read_from(read, self.clipboard.done.clone());
        }
    }

    /// Text copied on the computer arrived from its source.
    pub fn clipboard_read(&mut self, data: Vec<u8>) {
        tracing::debug!("clipboard: read {} bytes from the computer", data.len());
        // The phone's own text coming back through an application is not news.
        if self.clipboard.last_sent.as_deref() == Some(&data) {
            return;
        }
        let data = Arc::new(data);
        self.clipboard.last_sent = Some(data.clone());
        if let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) {
            self.net
                .send(conn, &Message::ServerClipboard(proto::Clipboard { mime: MIME.into(), data: (*data).clone() }));
        }
    }
}

/// Clipboard state: the channel text arrives on, and what the phone last saw.
pub struct Clipboard {
    pub done: Sender<Vec<u8>>,
    /// The text the phone has (sent to it, or copied on it).
    pub last_sent: Option<Arc<Vec<u8>>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_text_is_preferred() {
        let offered = |m: &[&str]| m.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(text_mime(&offered(&["STRING", "text/plain;charset=utf-8", "image/png"])).as_deref(), Some(MIME));
        assert_eq!(text_mime(&offered(&["TEXT", "UTF8_STRING"])).as_deref(), Some("UTF8_STRING"));
        assert_eq!(text_mime(&offered(&["image/png"])), None);
    }

    #[test]
    fn a_pipe_carries_text_to_the_reader() {
        let (read, write) = pipe().unwrap();
        write_to(write, Arc::new(b"copied".to_vec()));
        let mut got = String::new();
        std::fs::File::from(read).read_to_string(&mut got).unwrap();
        assert_eq!(got, "copied");
    }
}
