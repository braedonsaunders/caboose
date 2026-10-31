//! The compositor as an X client of its own Xwayland, for what Smithay's X11 window
//! manager does not do: reading the X11 clipboard in types other than text.
//!
//! Smithay 0.7 looks the atom of a non-text type up in a `TARGETS` property that it has
//! already consumed, so an X11 application's image never reaches Wayland or the phone
//! through it. The compositor instead converts the selection itself, on a thread, with
//! its own connection: ICCCM `ConvertSelection`, and the `INCR` protocol for an owner
//! that sends a large selection in pieces, bounded in size and time.

use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, Property, Window, WindowClass,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::{DefaultStream, RustConnection};

/// How to reach the seat's Xwayland as a client.
#[derive(Clone)]
pub struct Access {
    pub display: u32,
    pub cookie: [u8; 16],
}

/// A new client connection to the seat's Xwayland, with the seat's cookie.
pub fn connect(access: &Access) -> Result<RustConnection, Box<dyn std::error::Error>> {
    let stream = UnixStream::connect(format!("/tmp/.X11-unix/X{}", access.display))?;
    let (stream, _) = DefaultStream::from_unix_stream(stream)?;
    Ok(RustConnection::connect_to_stream_with_auth_info(
        stream,
        0,
        b"MIT-MAGIC-COOKIE-1".to_vec(),
        access.cookie.to_vec(),
    )?)
}

pub fn intern(conn: &RustConnection, name: &str) -> Result<Atom, Box<dyn std::error::Error>> {
    Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
}

/// Whether Smithay's window manager can transfer `mime` itself: the two text types it
/// maps to atoms without looking at `TARGETS`.
pub fn smithay_transfers(mime: &str) -> bool {
    mime == "text/plain;charset=utf-8" || mime == "text/plain"
}

/// Reads the X11 `CLIPBOARD` as `target` on a thread and writes it to `fd`, at most
/// `limit` bytes within `timeout`; on failure the descriptor is closed with nothing.
pub fn copy_into(access: Access, target: String, fd: OwnedFd, limit: usize, timeout: Duration) {
    std::thread::spawn(move || match read(&access, &target, limit, timeout) {
        Ok(data) => {
            crate::pipes::write_bounded(fd, &data, timeout);
        }
        Err(e) => tracing::debug!("X11 clipboard as {target}: {e}"),
    });
}

/// What a selection transfer does next.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    /// More is coming: wait for the owner's next piece.
    Wait,
    /// The whole selection.
    Done(Vec<u8>),
    /// Too large, out of time, or refused: nothing is kept.
    Fail(&'static str),
}

/// Collects one selection, whole or in `INCR` pieces, within a size and a deadline. It
/// keeps nothing once it fails.
pub struct Collector {
    limit: usize,
    deadline: Instant,
    incremental: bool,
    data: Vec<u8>,
}

impl Collector {
    pub fn new(limit: usize, deadline: Instant) -> Self {
        Self { limit, deadline, incremental: false, data: Vec::new() }
    }

    fn fail(&mut self, why: &'static str) -> Step {
        self.data = Vec::new();
        Step::Fail(why)
    }

    /// Whether the owner is sending `INCR` pieces.
    pub fn incremental(&self) -> bool {
        self.incremental
    }

    /// The owner's answer to the conversion: the property's value, whether its type is
    /// `INCR`, and how much of it was left unread.
    pub fn answer(&mut self, value: Vec<u8>, incr: bool, bytes_after: u32) -> Step {
        if incr {
            self.incremental = true;
            return Step::Wait;
        }
        if bytes_after > 0 || value.len() > self.limit {
            return self.fail("too large");
        }
        Step::Done(value)
    }

    /// One `INCR` piece; an empty one ends the transfer.
    pub fn piece(&mut self, value: &[u8], bytes_after: u32) -> Step {
        if !self.incremental {
            return Step::Wait;
        }
        if value.is_empty() {
            return Step::Done(std::mem::take(&mut self.data));
        }
        if bytes_after > 0 || self.data.len() + value.len() > self.limit {
            return self.fail("too large");
        }
        self.data.extend_from_slice(value);
        Step::Wait
    }

    /// Checked before and after every event, so an owner that keeps sending cannot hold
    /// the transfer past its deadline.
    pub fn expired(&mut self, now: Instant) -> Option<Step> {
        (now > self.deadline).then(|| self.fail("timed out"))
    }
}

/// The X11 `CLIPBOARD` as `target`. The connection, and with it the window and any
/// property left, is gone when this returns, whatever the outcome.
pub fn read(
    access: &Access,
    target: &str,
    limit: usize,
    timeout: Duration,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut collector = Collector::new(limit, Instant::now() + timeout);
    let conn = connect(access)?;
    let clipboard = intern(&conn, "CLIPBOARD")?;
    let target = intern(&conn, target)?;
    let property = intern(&conn, "CABOOSE_SELECTION")?;
    let incr = intern(&conn, "INCR")?;
    let root = conn.setup().roots[0].root;
    let window: Window = conn.generate_id()?;
    conn.create_window(
        0,
        window,
        root,
        -10,
        -10,
        1,
        1,
        0,
        WindowClass::INPUT_ONLY,
        0,
        &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
    )?;
    conn.convert_selection(window, clipboard, target, property, x11rb::CURRENT_TIME)?;
    conn.flush()?;
    // Reading a piece with delete asks the owner for the next one.
    let take = |conn: &RustConnection| -> Result<(Vec<u8>, Atom, u32), Box<dyn std::error::Error>> {
        let reply = conn.get_property(true, window, property, AtomEnum::ANY, 0, (limit / 4 + 1) as u32)?.reply()?;
        conn.flush()?;
        Ok((reply.value, reply.type_, reply.bytes_after))
    };
    loop {
        if let Some(Step::Fail(why)) = collector.expired(Instant::now()) {
            return Err(why.into());
        }
        let Some(event) = conn.poll_for_event()? else {
            std::thread::sleep(Duration::from_millis(5));
            continue;
        };
        let step = match event {
            // No owner, or an owner that refuses the type, answers with no property.
            Event::SelectionNotify(n) if n.requestor == window && n.property == x11rb::NONE => {
                Step::Fail("no owner takes the type")
            }
            Event::SelectionNotify(n) if n.requestor == window => {
                let (value, ty, after) = take(&conn)?;
                collector.answer(value, ty == incr, after)
            }
            // In INCR, each new value is a piece. Before that, the owner storing its whole
            // answer also changes the property: that is read on SelectionNotify, not here.
            Event::PropertyNotify(p)
                if collector.incremental()
                    && p.window == window
                    && p.atom == property
                    && p.state == Property::NEW_VALUE =>
            {
                let (value, _, after) = take(&conn)?;
                collector.piece(&value, after)
            }
            _ => Step::Wait,
        };
        match step {
            Step::Wait => continue,
            Step::Done(data) => return Ok(data),
            Step::Fail(why) => return Err(why.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn later() -> Instant {
        Instant::now() + Duration::from_secs(60)
    }

    #[test]
    fn a_whole_answer_is_the_selection() {
        let mut c = Collector::new(8, later());
        assert_eq!(c.answer(b"pixels".to_vec(), false, 0), Step::Done(b"pixels".to_vec()));
        let mut c = Collector::new(4, later());
        assert_eq!(c.answer(b"pixels".to_vec(), false, 0), Step::Fail("too large"));
        let mut c = Collector::new(64, later());
        assert_eq!(c.answer(b"part".to_vec(), false, 100), Step::Fail("too large"));
    }

    #[test]
    fn incr_pieces_add_up_until_an_empty_one() {
        let mut c = Collector::new(10, later());
        assert_eq!(c.answer(vec![0, 0, 0, 9], true, 0), Step::Wait);
        assert_eq!(c.piece(b"abcd", 0), Step::Wait);
        assert_eq!(c.piece(b"efgh", 0), Step::Wait);
        assert_eq!(c.piece(b"", 0), Step::Done(b"abcdefgh".to_vec()));
    }

    #[test]
    fn incr_past_the_limit_fails_and_keeps_nothing() {
        let mut c = Collector::new(6, later());
        c.answer(vec![], true, 0);
        assert_eq!(c.piece(b"abcd", 0), Step::Wait);
        assert_eq!(c.piece(b"efgh", 0), Step::Fail("too large"));
        assert!(c.data.is_empty());
    }

    #[test]
    fn a_stalled_owner_times_out_and_keeps_nothing() {
        let start = Instant::now();
        let mut c = Collector::new(64, start + Duration::from_secs(1));
        c.answer(vec![], true, 0);
        c.piece(b"some", 0);
        assert_eq!(c.expired(start), None);
        assert_eq!(c.expired(start + Duration::from_secs(2)), Some(Step::Fail("timed out")));
        assert!(c.data.is_empty());
    }

    #[test]
    fn pieces_before_an_incr_answer_are_ignored() {
        let mut c = Collector::new(64, later());
        assert_eq!(c.piece(b"stray", 0), Step::Wait);
        assert_eq!(c.answer(b"x".to_vec(), false, 0), Step::Done(b"x".to_vec()));
    }

    #[test]
    fn only_text_goes_through_smithay() {
        assert!(smithay_transfers("text/plain;charset=utf-8"));
        assert!(smithay_transfers("text/plain"));
        assert!(!smithay_transfers("image/png"));
        assert!(!smithay_transfers("text/uri-list"));
    }
}
