//! Drops from the phone into X11 applications, by the XDND protocol
//! (https://www.freedesktop.org/wiki/Specifications/XDND/, versions 3 to 5).
//!
//! Xwayland does not turn Wayland drags into XDND, and Smithay's X11 window manager does
//! not either, so the compositor is the XDND source itself: for each drop over an X11
//! window it opens its own X connection on a thread, owns `XdndSelection` from a hidden
//! window, and exchanges XdndEnter / XdndPosition / XdndStatus / XdndDrop / XdndFinished
//! with the window. The thread answers the application's selection requests from the
//! drop's content. Every wait is bounded: a status 2 s, the application's finish 30 s
//! after the drop, the session 15 min; anything else ends the session as failed. The
//! action is always XdndActionCopy, so the phone's copy is never removed.

use crate::clipboard::Offer;
use crate::x11sel::{connect, intern, Access};
use smithay::reexports::calloop::channel::Sender;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant};
use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ClientMessageEvent, ConnectionExt as _, CreateWindowAux, EventMask, PropMode, SelectionNotifyEvent,
    Window, WindowClass, SELECTION_NOTIFY_EVENT,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// The newest XDND version this source speaks.
const VERSION: u32 = 5;
const STATUS_TIMEOUT: Duration = Duration::from_secs(2);
const FINISH_TIMEOUT: Duration = Duration::from_secs(30);
const SESSION_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// How long a drop waits for the window to accept it, asking again this often.
const ACCEPT_WAIT: Duration = Duration::from_secs(2);
const ASK_AGAIN: Duration = Duration::from_millis(200);
/// How often the thread looks at its commands and the X connection while a drop lasts.
const TICK: Duration = Duration::from_millis(15);

/// What the compositor tells a session.
pub enum Command {
    /// The pointer is at this root position.
    Position(i16, i16),
    /// The phone dropped: the content to hand over.
    Drop(Arc<Offer>),
    Leave,
}

/// What a session reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Report {
    /// Whether the window accepts the drop where it is.
    Status(bool),
    /// The drop is over: whether the window took it.
    Finished(bool),
    /// The session ended without a drop; `timeout` if a wait ran out.
    Failed { timeout: bool },
}

/// One drop over one X11 window.
pub struct Session {
    commands: mpsc::Sender<Command>,
}

impl Session {
    /// Starts a session over `target` (an X11 client window) offering `types`; reports
    /// arrive on `reports` tagged with `serial`.
    pub fn start(
        access: Access,
        target: Window,
        types: Vec<String>,
        serial: u64,
        reports: Sender<(u64, Report)>,
    ) -> Self {
        let (commands, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("caboose-xdnd".into())
            .spawn(move || {
                let report = match run(&access, target, &types, &rx, &|r| {
                    let _ = reports.send((serial, r));
                }) {
                    Ok(report) => report,
                    Err(e) => {
                        tracing::debug!("xdnd: {e}");
                        Report::Failed { timeout: false }
                    }
                };
                let _ = reports.send((serial, report));
            })
            .ok();
        Self { commands }
    }

    pub fn send(&self, command: Command) {
        let _ = self.commands.send(command);
    }
}

/// `XdndEnter`'s data: the source, the version with "more than three types", and the
/// first three types.
pub fn enter_data(source: Window, version: u32, types: &[Atom]) -> [u32; 5] {
    let more = u32::from(types.len() > 3);
    let t = |i: usize| types.get(i).copied().unwrap_or(0);
    [source, (version << 24) | more, t(0), t(1), t(2)]
}

/// `XdndPosition`'s data: the source, the root position, the time and the action.
pub fn position_data(source: Window, x: i16, y: i16, copy: Atom) -> [u32; 5] {
    [source, 0, ((x as u16 as u32) << 16) | (y as u16 as u32), 0, copy]
}

/// The version a window speaks, from its `XdndAware` property, if this source can talk to it.
pub fn negotiate(aware: Option<u32>) -> Option<u32> {
    aware.filter(|v| *v >= 3).map(|v| v.min(VERSION))
}

/// Whether `XdndStatus` or `XdndFinished` data from `target` says it accepts.
pub fn accepts(data: [u32; 5], target: Window) -> bool {
    data[0] == target && data[1] & 1 == 1
}

struct Atoms {
    aware: Atom,
    proxy: Atom,
    enter: Atom,
    position: Atom,
    status: Atom,
    leave: Atom,
    drop: Atom,
    finished: Atom,
    selection: Atom,
    type_list: Atom,
    copy: Atom,
    targets: Atom,
}

fn atoms(conn: &RustConnection) -> Result<Atoms, Box<dyn std::error::Error>> {
    Ok(Atoms {
        aware: intern(conn, "XdndAware")?,
        proxy: intern(conn, "XdndProxy")?,
        enter: intern(conn, "XdndEnter")?,
        position: intern(conn, "XdndPosition")?,
        status: intern(conn, "XdndStatus")?,
        leave: intern(conn, "XdndLeave")?,
        drop: intern(conn, "XdndDrop")?,
        finished: intern(conn, "XdndFinished")?,
        selection: intern(conn, "XdndSelection")?,
        type_list: intern(conn, "XdndTypeList")?,
        copy: intern(conn, "XdndActionCopy")?,
        targets: intern(conn, "TARGETS")?,
    })
}

fn property_u32(conn: &RustConnection, window: Window, property: Atom, ty: impl Into<Atom>) -> Option<u32> {
    let reply = conn.get_property(false, window, property, ty.into(), 0, 1).ok()?.reply().ok()?;
    let value = reply.value32()?.next();
    value
}

/// Where XDND messages for `target` go and the version it speaks: the window itself, or
/// the window its `XdndProxy` names.
fn find_target(conn: &RustConnection, atoms: &Atoms, target: Window) -> Option<(Window, u32)> {
    if let Some(version) = negotiate(property_u32(conn, target, atoms.aware, AtomEnum::ATOM)) {
        return Some((target, version));
    }
    let proxy = property_u32(conn, target, atoms.proxy, AtomEnum::WINDOW)?;
    negotiate(property_u32(conn, proxy, atoms.aware, AtomEnum::ATOM)).map(|v| (proxy, v))
}

fn send(conn: &RustConnection, to: Window, ty: Atom, data: [u32; 5]) -> Result<(), Box<dyn std::error::Error>> {
    conn.send_event(false, to, EventMask::NO_EVENT, ClientMessageEvent::new(32, to, ty, data))?;
    conn.flush()?;
    Ok(())
}

fn run(
    access: &Access,
    target: Window,
    types: &[String],
    commands: &Receiver<Command>,
    report: &dyn Fn(Report),
) -> Result<Report, Box<dyn std::error::Error>> {
    let conn = connect(access)?;
    let atoms = atoms(&conn)?;
    let root = conn.setup().roots[0].root;
    let source = conn.generate_id()?;
    conn.create_window(0, source, root, -10, -10, 1, 1, 0, WindowClass::INPUT_ONLY, 0, &CreateWindowAux::new())?;
    let type_atoms: Vec<Atom> = types.iter().map(|t| intern(&conn, t)).collect::<Result<_, _>>()?;
    let Some((window, version)) = find_target(&conn, &atoms, target) else {
        // Not an XDND target: it cannot take the drop.
        report(Report::Status(false));
        return wait_without_target(commands);
    };
    if type_atoms.len() > 3 {
        conn.change_property32(PropMode::REPLACE, source, atoms.type_list, AtomEnum::ATOM, &type_atoms)?;
    }
    conn.set_selection_owner(source, atoms.selection, x11rb::CURRENT_TIME)?;
    send(&conn, window, atoms.enter, enter_data(source, version, &type_atoms))?;

    let started = Instant::now();
    let mut accepted = false;
    let mut reported: Option<bool> = None;
    let mut awaiting_status: Option<Instant> = None;
    let mut next_position: Option<(i16, i16)> = None;
    let mut last_position: Option<(i16, i16)> = None;
    // The window asked for data before the phone sent it (toolkits read a drag's data as
    // it hovers); it enters again once the content is here.
    let mut asked_early = false;
    // Since when the drop waits for the window to accept, and how often it was asked again.
    let mut drop_wait: Option<Instant> = None;
    let mut asked_again = 1;
    let mut offer: Option<Arc<Offer>> = None;
    let mut dropped_at: Option<Instant> = None;
    let leave = |conn: &RustConnection| send(conn, window, atoms.leave, [source, 0, 0, 0, 0]);
    loop {
        match commands.recv_timeout(TICK) {
            Ok(Command::Position(x, y)) => {
                next_position = Some((x, y));
                last_position = Some((x, y));
            }
            Ok(Command::Drop(content)) => {
                offer = Some(content);
                if asked_early {
                    leave(&conn)?;
                    send(&conn, window, atoms.enter, enter_data(source, version, &type_atoms))?;
                    next_position = last_position;
                    accepted = false;
                    asked_early = false;
                }
            }
            Ok(Command::Leave) | Err(RecvTimeoutError::Disconnected) => {
                leave(&conn)?;
                return Ok(Report::Failed { timeout: false });
            }
            Err(RecvTimeoutError::Timeout) => {}
        }
        while let Some(event) = conn.poll_for_event()? {
            match event {
                Event::ClientMessage(m) if m.type_ == atoms.status => {
                    accepted = accepts(m.data.as_data32(), window);
                    awaiting_status = None;
                    if reported != Some(accepted) {
                        reported = Some(accepted);
                        report(Report::Status(accepted));
                    }
                }
                Event::ClientMessage(m) if m.type_ == atoms.finished => {
                    // Version 5 says whether the window took it; before that, finishing is taking it.
                    let data = m.data.as_data32();
                    return Ok(Report::Finished(data[0] == window && (version < 5 || data[1] & 1 == 1)));
                }
                Event::SelectionRequest(r) if r.selection == atoms.selection => {
                    tracing::debug!(
                        "dnd: XDND window asks for atom {} ({})",
                        r.target,
                        if offer.is_some() { "ready" } else { "early" }
                    );
                    asked_early |= offer.is_none() && r.target != atoms.targets;
                    answer(&conn, &atoms, &r, &type_atoms, types, offer.as_deref())?;
                }
                _ => {}
            }
        }
        let now = Instant::now();
        if awaiting_status.is_some_and(|since| now - since > STATUS_TIMEOUT) {
            // No answer: it does not take the drop here.
            awaiting_status = None;
            accepted = false;
            if reported != Some(false) {
                reported = Some(false);
                report(Report::Status(false));
            }
        }
        // One position at a time, each answered (or timed out) before the next; the drop
        // follows the answer to the last one.
        if dropped_at.is_none() && awaiting_status.is_none() {
            if let Some((x, y)) = next_position.take() {
                send(&conn, window, atoms.position, position_data(source, x, y, atoms.copy))?;
                awaiting_status = Some(now);
            } else if let Some(waiting) = offer.as_ref().map(|_| *drop_wait.get_or_insert(now)) {
                if !accepted {
                    // An application often refuses the first position of a drag until it has
                    // read the data and asked its page; it is asked again for a while.
                    if now - waiting < ACCEPT_WAIT {
                        if now - waiting >= ASK_AGAIN * asked_again {
                            next_position = last_position;
                            asked_again += 1;
                        }
                        continue;
                    }
                    leave(&conn)?;
                    return Ok(Report::Finished(false));
                }
                send(&conn, window, atoms.drop, [source, 0, 0, 0, 0])?;
                dropped_at = Some(now);
            }
        }
        if dropped_at.is_some_and(|at| now - at > FINISH_TIMEOUT) || now - started > SESSION_TIMEOUT {
            leave(&conn)?;
            return Ok(Report::Failed { timeout: true });
        }
    }
}

/// A session over a window that is not an XDND target: it only waits for the drop or
/// the leave.
fn wait_without_target(commands: &Receiver<Command>) -> Result<Report, Box<dyn std::error::Error>> {
    loop {
        match commands.recv_timeout(SESSION_TIMEOUT) {
            Ok(Command::Position(..)) => continue,
            Ok(Command::Drop(_)) => return Ok(Report::Finished(false)),
            Ok(Command::Leave) | Err(RecvTimeoutError::Disconnected) => return Ok(Report::Failed { timeout: false }),
            Err(RecvTimeoutError::Timeout) => return Ok(Report::Failed { timeout: true }),
        }
    }
}

/// Answers a window's request for the drop's data: the type list, or the bytes of one
/// type written to the property it named (in one request; a type larger than the server
/// takes in one is refused).
fn answer(
    conn: &RustConnection,
    atoms: &Atoms,
    r: &x11rb::protocol::xproto::SelectionRequestEvent,
    type_atoms: &[Atom],
    types: &[String],
    offer: Option<&Offer>,
) -> Result<(), Box<dyn std::error::Error>> {
    let property = if r.property == 0 { r.target } else { r.property };
    let mut stored = false;
    if r.target == atoms.targets {
        let mut list = type_atoms.to_vec();
        list.push(atoms.targets);
        conn.change_property32(PropMode::REPLACE, r.requestor, property, AtomEnum::ATOM, &list)?;
        stored = true;
    } else if let Some(data) =
        type_atoms.iter().position(|a| *a == r.target).and_then(|i| offer.and_then(|o| o.data(&types[i])))
    {
        if data.len() + 1024 <= conn.maximum_request_bytes() {
            conn.change_property8(PropMode::REPLACE, r.requestor, property, r.target, &data)?;
            stored = true;
        }
    }
    let notify = SelectionNotifyEvent {
        response_type: SELECTION_NOTIFY_EVENT,
        sequence: 0,
        time: r.time,
        requestor: r.requestor,
        selection: r.selection,
        target: r.target,
        property: if stored { property } else { 0 },
    };
    conn.send_event(false, r.requestor, EventMask::NO_EVENT, notify)?;
    conn.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enter_names_the_version_and_the_first_three_types() {
        assert_eq!(enter_data(9, 5, &[1, 2]), [9, 5 << 24, 1, 2, 0]);
        assert_eq!(enter_data(9, 4, &[1, 2, 3, 4]), [9, (4 << 24) | 1, 1, 2, 3]);
    }

    #[test]
    fn positions_pack_root_coordinates() {
        assert_eq!(position_data(9, 300, 40, 77), [9, 0, (300 << 16) | 40, 0, 77]);
        // Negative coordinates keep their 16-bit two's complement, as the spec packs them.
        assert_eq!(position_data(9, -1, 2, 77)[2], (0xffff << 16) | 2);
    }

    #[test]
    fn versions_three_to_five_are_spoken() {
        assert_eq!(negotiate(None), None);
        assert_eq!(negotiate(Some(2)), None);
        assert_eq!(negotiate(Some(3)), Some(3));
        assert_eq!(negotiate(Some(7)), Some(5));
    }

    #[test]
    fn only_the_target_can_accept() {
        assert!(accepts([5, 1, 0, 0, 0], 5));
        assert!(!accepts([5, 0, 0, 0, 0], 5));
        assert!(!accepts([6, 1, 0, 0, 0], 5));
    }
}
