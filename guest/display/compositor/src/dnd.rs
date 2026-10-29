//! Drag and drop between the phone and applications (docs/display.md, Drag and drop).
//!
//! **Drops from the phone** (`drop.*`). While the phone drags something over a window,
//! the compositor drags it there too, so the application under the finger sees a real
//! drag: over a Wayland window a compositor-owned Wayland drag (Smithay's server
//! drag-and-drop grab on the seat's pointer), over an X11 window an XDND session
//! ([`crate::xdnd`]). Whether the application accepts goes back as `drop.status`. The
//! phone uploads files to the transfer area before it sends `drop.perform`; only then is
//! the drag released, so the application finds the content ready when it asks. The
//! content is checked as a clipboard copy is, and the result is `drop.result`.
//!
//! **Drags to the phone** (`drag.*`). When a Wayland application starts dragging, the
//! phone is told the types it could take (`drag.start`). If the finger lifts on the
//! phone's own drop target, the phone sends `drag.take` before the lift: the compositor
//! moves the drag off every window, reads the content from the application's source
//! (bounded, as a copy is) while it holds back the phone's input, sends `drag.data`, and
//! then lets the lift end the drag, which the application sees as not dropped anywhere,
//! so it removes nothing. X11 applications' drags stay within X11.

use crate::clipboard::{self, Offer, Read};
use crate::state::State;
use crate::windows::Surface;
use crate::xdnd;
use caboose_display_protocol::{self as proto, clipboard as types, DropFailure, Message};
use smithay::input::pointer::{GrabStartData as PointerGrabStartData, MotionEvent};
use smithay::input::touch::MotionEvent as TouchMotionEvent;
use smithay::reexports::calloop::channel::Sender;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::wayland_server::protocol::wl_data_device_manager::DndAction;
use smithay::reexports::wayland_server::protocol::wl_data_source::WlDataSource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point};
use smithay::wayland::selection::data_device::{start_dnd, with_source_metadata, SourceMetadata};
use std::os::fd::{AsFd, OwnedFd};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// evdev's left button, the button the compositor's own drag is held with.
const BTN_LEFT: u32 = 0x110;
/// An application has this long to finish taking a drop.
const FINISH_TIMEOUT: Duration = Duration::from_secs(30);
/// How long an application that accepted the content is left to read it before the drag
/// moves once more, and as long again before the release.
const SETTLE: Duration = Duration::from_millis(250);
/// How long after the last of the content is written the release waits, so the
/// application has asked for every type it wants and handed it to its page.
const READ_SETTLE: Duration = Duration::from_millis(600);
/// An application has this long to accept the drop again once the content is ready.
const REENTER_TIMEOUT: Duration = Duration::from_secs(3);
/// A drop the phone neither performs nor leaves ends after this long.
const HOVER_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// The most input messages held back while a drag's content is read.
const MAX_DEFERRED: usize = 256;

/// Where a drop from the phone is.
enum Target {
    /// Over no window that can take it.
    None,
    /// Over a Wayland surface, through the compositor's Wayland drag.
    Wayland(WlSurface),
    /// Over an X11 window (the compositor's window id), through an XDND session.
    X11 { window: u64, serial: u64, session: xdnd::Session },
}

/// A drop from the phone in progress.
struct Drop {
    /// This drop, among the session's.
    id: u64,
    /// The protocol types the phone offers.
    types: Vec<String>,
    target: Target,
    location: Point<f64, Logical>,
    /// The last `drop.status` sent.
    status: Option<Option<bool>>,
    /// What the Wayland application under the drop said: the type it takes and the action.
    accepted_mime: Option<String>,
    action: DndAction,
    content: Option<Arc<Offer>>,
    performed: Option<Instant>,
    /// The Wayland surface under the drop, with its origin.
    focus: Option<crate::input::Focus>,
    /// When the drag re-entered the surface with the content ready, waiting for the
    /// application to accept the fresh offer before the release.
    reentered: Option<Instant>,
    /// The application accepted the content and is given a moment to read it.
    settling: bool,
    /// That moment is over: the next acceptance releases the drag.
    settled: bool,
    /// Content being written to the application, and when the last write ended.
    writes: Arc<Mutex<(usize, Option<Instant>)>>,
    touched: Instant,
}

/// An application's drag the phone may take.
struct Drag {
    source: WlDataSource,
    /// The types the client could take, in the protocol's terms.
    types: Vec<String>,
    /// The serial of the reads of a take, while they are in flight.
    taking: Option<u64>,
    expected: usize,
    read: Vec<(&'static str, Vec<u8>)>,
    /// The take's content was sent; the drag ends with the next lift.
    taken: bool,
}

/// Drag and drop state.
pub struct Dnd {
    serial: u64,
    drop: Option<Drop>,
    drag: Option<Drag>,
    /// Input held back while a drag's content is read.
    deferred: Vec<Message>,
    /// The compositor is ending its own drag: the grab's callbacks are not news.
    ending_grab: bool,
    pub xdnd_reports: Sender<(u64, xdnd::Report)>,
    pub drag_reads: Sender<Read>,
}

impl Dnd {
    pub fn new(xdnd_reports: Sender<(u64, xdnd::Report)>, drag_reads: Sender<Read>) -> Self {
        Self { serial: 0, drop: None, drag: None, deferred: Vec::new(), ending_grab: false, xdnd_reports, drag_reads }
    }

    /// Whether the phone's input is held back now.
    pub fn defers_input(&self) -> bool {
        self.drag.as_ref().is_some_and(|d| d.taking.is_some())
    }

    /// Whether the phone's pointer is driving a drop (and its own pointer events wait).
    pub fn drops(&self) -> bool {
        self.drop.is_some()
    }

    fn next_serial(&mut self) -> u64 {
        self.serial += 1;
        self.serial
    }
}

/// Whether a drop's status, from what the Wayland application said, accepts it.
fn wayland_accepts(mime: &Option<String>, action: DndAction) -> bool {
    mime.is_some() && !action.is_empty()
}

impl State {
    fn send_to_client(&mut self, message: &Message) {
        if let Some(conn) = self.session.as_ref().filter(|s| s.ready).map(|s| s.conn) {
            self.net.send(conn, message);
        }
    }

    // MARK: Drops from the phone

    pub fn drop_enter(&mut self, m: proto::DropEnter) {
        self.drop_cancel();
        let mut types: Vec<String> = Vec::new();
        for t in m.mimes {
            if types::TYPES.contains(&t.as_str()) && !types.contains(&t) {
                types.push(t);
            }
        }
        let Some((location, _)) = self.locate(m.id, m.x, m.y) else {
            self.send_to_client(&Message::DropStatus { accepted: Some(false) });
            return;
        };
        let app_types = Offer::app_types(&types);
        let id = self.dnd.next_serial();
        self.dnd.drop = Some(Drop {
            id,
            types,
            target: Target::None,
            location,
            status: None,
            accepted_mime: None,
            action: DndAction::empty(),
            content: None,
            performed: None,
            focus: None,
            reentered: None,
            settling: false,
            settled: false,
            writes: Arc::new(Mutex::new((0, None))),
            touched: Instant::now(),
        });
        if self.seat.get_pointer().is_some() {
            let serial = self.next_serial();
            let start = PointerGrabStartData { focus: None, button: BTN_LEFT, location };
            let metadata = SourceMetadata { mime_types: app_types, dnd_action: DndAction::Copy };
            let (dh, seat) = (self.dh.clone(), self.seat.clone());
            start_dnd(&dh, &seat, self, serial, Some(start), None, metadata);
        }
        self.drop_motion(m.id, m.x, m.y);
    }

    pub fn drop_motion(&mut self, id: u64, x: f64, y: f64) {
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        if drop.performed.is_some() {
            return;
        }
        drop.touched = Instant::now();
        let Some((location, under)) = self.locate(id, x, y) else { return };
        let x11 = match self.windows.get(id).map(|w| &w.surface) {
            Some(Surface::X11(x)) => Some(x.window_id()),
            _ => None,
        };
        let drop = self.dnd.drop.as_mut().unwrap();
        drop.location = location;
        // The target: an X11 window takes the drop by XDND, a Wayland surface by the
        // Wayland drag.
        let same = match (&drop.target, x11, &under) {
            (Target::X11 { window, .. }, Some(_), _) => *window == id,
            (Target::Wayland(s), None, Some((u, _))) => s == u,
            (Target::None, None, None) => true,
            _ => false,
        };
        if !same {
            let types = drop.types.clone();
            if let Target::X11 { session, .. } = std::mem::replace(&mut drop.target, Target::None) {
                session.send(xdnd::Command::Leave);
            }
            let target = match (x11, &under) {
                (Some(window), _) => match self.x11.clone() {
                    Some(access) => {
                        let serial = self.dnd.next_serial();
                        let reports = self.dnd.xdnd_reports.clone();
                        let session = xdnd::Session::start(access, window, Offer::app_types(&types), serial, reports);
                        Target::X11 { window: id, serial, session }
                    }
                    None => Target::None,
                },
                (None, Some((surface, _))) => Target::Wayland(surface.clone()),
                (None, None) => Target::None,
            };
            let drop = self.dnd.drop.as_mut().unwrap();
            drop.target = target;
            drop.accepted_mime = None;
            drop.action = DndAction::empty();
            // A Wayland application is entered only with the content (see `drop_perform`),
            // so it answers on the drop; an X11 window answers by XDND as the drag moves.
            let wayland = matches!(drop.target, Target::Wayland(_));
            self.drop_status(if wayland { None } else { Some(false) });
        }
        let drop = self.dnd.drop.as_mut().unwrap();
        // Over a Wayland surface the drag only follows the finger: the surface is not
        // entered until the content is here (`drop_perform`), because applications read
        // what they are offered as it enters, and the phone has nothing to give before the
        // drop.
        drop.focus = match &drop.target {
            Target::Wayland(_) => under,
            _ => None,
        };
        let wayland_focus: Option<crate::input::Focus> = None;
        if let Target::X11 { session, .. } = &drop.target {
            session.send(xdnd::Command::Position(location.x.round() as i16, location.y.round() as i16));
        }
        if let Some(pointer) = self.seat.get_pointer() {
            let serial = self.next_serial();
            let time = self.now_ms();
            pointer.motion(self, wayland_focus, &MotionEvent { location, serial, time });
            pointer.frame(self);
        }
    }

    /// The phone's drag left, or it gave up: the applications see the drag leave.
    pub fn drop_leave(&mut self) {
        self.drop_cancel();
    }

    /// Ends a drop without a result to the phone.
    fn drop_cancel(&mut self) {
        let Some(drop) = self.dnd.drop.take() else { return };
        if let Target::X11 { session, .. } = drop.target {
            session.send(xdnd::Command::Leave);
        }
        self.end_drop_grab(false);
    }

    /// Ends the compositor's Wayland drag: as a drop on the surface under it when `drop`,
    /// otherwise by leaving every surface first.
    fn end_drop_grab(&mut self, drop: bool) {
        let Some(pointer) = self.seat.get_pointer() else { return };
        if !pointer.is_grabbed() {
            return;
        }
        let serial = self.next_serial();
        let time = self.now_ms();
        if !drop {
            let location = pointer.current_location();
            self.dnd.ending_grab = true;
            pointer.motion(self, None, &MotionEvent { location, serial, time });
        }
        pointer.unset_grab(self, serial, time);
        self.dnd.ending_grab = false;
    }

    pub fn drop_perform(&mut self, content: proto::Clipboard) {
        let Some(drop) = self.dnd.drop.as_ref() else {
            self.send_to_client(&Message::DropResult { ok: false, reason: Some(DropFailure::Cancelled) });
            return;
        };
        let offered = content.entries().all(|(m, _)| drop.types.iter().any(|t| t == m));
        if types::validate(&content).is_err() || !offered || !clipboard::files_in_transfer_area(&content) {
            tracing::warn!("drop: refused the phone's content");
            self.drop_cancel();
            self.send_to_client(&Message::DropResult { ok: false, reason: Some(DropFailure::Invalid) });
            return;
        }
        let offer = Arc::new(Offer::new(&content));
        let drop = self.dnd.drop.as_mut().unwrap();
        drop.performed = Some(Instant::now());
        drop.content = Some(offer.clone());
        match &drop.target {
            Target::X11 { session, .. } => {
                session.send(xdnd::Command::Drop(offer));
                // The Wayland drag only carried the pointer; it ends without a drop.
                self.end_drop_grab(false);
            }
            Target::Wayland(_) => {
                // The surface is entered now, with the content ready to read, and once the
                // application accepts the offer it is released on it (`drop_answered`).
                tracing::debug!("dnd: entering with the content");
                drop.reentered = Some(Instant::now());
                drop.accepted_mime = None;
                drop.action = DndAction::empty();
                let (focus, location) = (drop.focus.clone(), drop.location);
                if let Some(pointer) = self.seat.get_pointer() {
                    let time = self.now_ms();
                    let serial = self.next_serial();
                    pointer.motion(self, None, &MotionEvent { location, serial, time });
                    let serial = self.next_serial();
                    pointer.motion(self, focus, &MotionEvent { location, serial, time });
                    pointer.frame(self);
                }
            }
            Target::None => self.drop_finish(false, DropFailure::Rejected),
        }
    }

    /// Ends the drop with its result to the phone.
    fn drop_finish(&mut self, ok: bool, failure: DropFailure) {
        let Some(drop) = self.dnd.drop.take() else { return };
        if let Target::X11 { session, .. } = drop.target {
            if !ok {
                session.send(xdnd::Command::Leave);
            }
        }
        self.end_drop_grab(false);
        self.send_to_client(&Message::DropResult { ok, reason: (!ok).then_some(failure) });
    }

    /// Tells the phone whether the application under the drop accepts it; `None` when
    /// it answers only on the drop.
    fn drop_status(&mut self, accepted: Option<bool>) {
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        if drop.status != Some(accepted) {
            drop.status = Some(accepted);
            self.send_to_client(&Message::DropStatus { accepted });
        }
    }

    // The Wayland drag's callbacks (ServerDndGrabHandler).

    pub fn drop_accepted(&mut self, mime: Option<String>) {
        tracing::debug!("dnd: the application accepts {mime:?}");
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        drop.accepted_mime = mime;
        self.drop_answered();
    }

    pub fn drop_action(&mut self, action: DndAction) {
        tracing::debug!("dnd: the application chose {action:?}");
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        drop.action = action;
        self.drop_answered();
    }

    /// The Wayland application answered: release the drag once it accepts the offer
    /// made with the content.
    fn drop_answered(&mut self) {
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        let accepted = matches!(drop.target, Target::Wayland(_)) && wayland_accepts(&drop.accepted_mime, drop.action);
        if drop.reentered.is_none() {
            return;
        }
        let read = matches!(*drop.writes.lock().unwrap(), (0, t) if t.is_none_or(|t| t.elapsed() >= READ_SETTLE));
        if accepted && drop.settled && read {
            // Smithay holds the offer's lock while it reports an answer; the release, which
            // takes it again, waits for the loop.
            drop.reentered = None;
            self.handle.insert_idle(|state| state.release_drop());
        } else if accepted && !drop.settling {
            // The application has the content now, but reading it and asking its page (a
            // drop target in a web page) takes a moment, and it may change its answer
            // meanwhile: the drag moves over it once more, and is released at the end of
            // the moment if it still accepts, or as soon as it accepts again after.
            drop.settling = true;
            let id = drop.id;
            for (delay, last) in [(SETTLE, false), (SETTLE * 2, true)] {
                let timer = Timer::from_duration(delay);
                let _ = self.handle.insert_source(timer, move |_, _, state| {
                    state.settle_drop(id, last);
                    TimeoutAction::Drop
                });
            }
        }
    }

    fn settle_drop(&mut self, id: u64, last: bool) {
        let Some(drop) = self.dnd.drop.as_mut().filter(|d| d.id == id && d.reentered.is_some()) else { return };
        if last {
            // The application must have all of the content, a moment ago, before the release.
            let (writing, last_write) = *drop.writes.lock().unwrap();
            let read = writing == 0 && last_write.is_none_or(|t| t.elapsed() >= READ_SETTLE);
            drop.settled = read;
            if read && wayland_accepts(&drop.accepted_mime, drop.action) {
                drop.reentered = None;
                self.release_drop();
                return;
            }
            // Not now: the drag keeps moving over it, so it can answer again, until the
            // drop's time is up.
            let timer = Timer::from_duration(SETTLE);
            let _ = self.handle.insert_source(timer, move |_, _, state| {
                state.settle_drop(id, false);
                state.settle_drop(id, true);
                TimeoutAction::Drop
            });
        } else if let Some(pointer) = self.seat.get_pointer() {
            let (focus, location) = (drop.focus.clone(), drop.location);
            let (serial, time) = (self.next_serial(), self.now_ms());
            pointer.motion(self, focus, &MotionEvent { location, serial, time });
            pointer.frame(self);
        }
    }

    fn release_drop(&mut self) {
        tracing::debug!("dnd: released on the application");
        self.end_drop_grab(true);
    }

    pub fn drop_send(&mut self, mime: String, fd: OwnedFd) {
        let Some(drop) = self.dnd.drop.as_mut() else { return };
        tracing::debug!(
            "dnd: the application reads {mime} ({})",
            if drop.content.is_some() { "ready" } else { "held" }
        );
        match &drop.content {
            Some(offer) => {
                // Written on a thread; the release waits until every write is done.
                let writes = drop.writes.clone();
                {
                    let mut w = writes.lock().unwrap();
                    *w = (w.0 + 1, None);
                }
                offer.send_then(&mime, fd, move || {
                    let mut w = writes.lock().unwrap();
                    *w = (w.0 - 1, Some(Instant::now()));
                });
            }
            // Only an offer made with the content is read.
            None => std::mem::drop(fd),
        }
    }

    pub fn drop_cancelled(&mut self) {
        tracing::debug!("dnd: the drag was cancelled (ending: {})", self.dnd.ending_grab);
        if self.dnd.ending_grab {
            return;
        }
        // Released where nothing accepted it.
        if self.dnd.drop.as_ref().is_some_and(|d| d.performed.is_some() && matches!(d.target, Target::Wayland(_))) {
            let drop = self.dnd.drop.take();
            drop_without_grab(drop);
            self.send_to_client(&Message::DropResult { ok: false, reason: Some(DropFailure::Rejected) });
        }
    }

    pub fn drop_finished(&mut self) {
        tracing::debug!("dnd: the application finished");
        if self.dnd.drop.as_ref().is_some_and(|d| d.performed.is_some() && matches!(d.target, Target::Wayland(_))) {
            self.dnd.drop = None;
            self.send_to_client(&Message::DropResult { ok: true, reason: None });
        }
    }

    /// A report from an XDND session.
    pub fn on_xdnd_report(&mut self, serial: u64, report: xdnd::Report) {
        tracing::debug!("dnd: XDND session {serial}: {report:?}");
        let current =
            self.dnd.drop.as_ref().is_some_and(|d| matches!(d.target, Target::X11 { serial: s, .. } if s == serial));
        if !current {
            return;
        }
        match report {
            xdnd::Report::Status(accepted) => self.drop_status(Some(accepted)),
            xdnd::Report::Finished(true) => self.drop_finish(true, DropFailure::Rejected),
            xdnd::Report::Finished(false) => self.drop_finish(false, DropFailure::Rejected),
            xdnd::Report::Failed { timeout } => {
                if self.dnd.drop.as_ref().is_some_and(|d| d.performed.is_some()) {
                    self.drop_finish(false, if timeout { DropFailure::Timeout } else { DropFailure::Rejected });
                } else {
                    // The window could not be reached; the drop goes on over nothing there.
                    if let Some(drop) = self.dnd.drop.as_mut() {
                        drop.target = Target::None;
                    }
                    self.drop_status(Some(false));
                }
            }
        }
    }

    // MARK: Drags to the phone

    /// A Wayland application started dragging (ClientDndGrabHandler::started).
    pub fn drag_started(&mut self, source: Option<WlDataSource>) {
        self.dnd.drag = None;
        // A drag with no source stays within its application.
        let Some(source) = source else { return };
        let offered = with_source_metadata(&source, |m| m.mime_types.clone()).unwrap_or_default();
        let takes = self.session.as_ref().map(|s| s.clipboard_types.clone()).unwrap_or_default();
        let types: Vec<String> = clipboard::wanted(&offered)
            .iter()
            .map(|w| w.mime.to_string())
            .filter(|m| m == types::TEXT || takes.contains(m))
            .collect();
        if types.is_empty() {
            return;
        }
        self.send_to_client(&Message::DragStart { mimes: types.clone() });
        self.dnd.drag = Some(Drag { source, types, taking: None, expected: 0, read: Vec::new(), taken: false });
    }

    /// The application's drag ended (ClientDndGrabHandler::dropped).
    pub fn drag_ended(&mut self) {
        let Some(drag) = self.dnd.drag.as_ref() else { return };
        if drag.taking.is_some() {
            // Reading; the end comes once the content is sent.
            return;
        }
        let taken = drag.taken;
        self.dnd.drag = None;
        self.send_to_client(&Message::DragEnd { taken });
    }

    /// The phone takes the drag: off every window, then read.
    pub fn drag_take(&mut self) {
        let Some(drag) = self.dnd.drag.as_ref().filter(|d| d.taking.is_none() && !d.taken) else {
            self.send_to_client(&Message::DragEnd { taken: false });
            return;
        };
        let offered = with_source_metadata(&drag.source, |m| m.mime_types.clone()).unwrap_or_default();
        let types = drag.types.clone();
        let source = drag.source.clone();
        let serial = self.dnd.next_serial();
        // The drag hovers over nothing from now on, so the lift drops it nowhere.
        self.drag_leave_windows();
        let sinks: Vec<_> = clipboard::sinks(serial, &offered, &self.dnd.drag_reads)
            .into_iter()
            .filter(|(_, sink)| types.iter().any(|t| t == sink.mime()))
            .collect();
        let drag = self.dnd.drag.as_mut().unwrap();
        drag.taking = Some(serial);
        drag.expected = sinks.len();
        if sinks.is_empty() {
            self.drag_read_done();
            return;
        }
        for (mime, sink) in sinks {
            match crate::pipes::pipe() {
                Ok((read, write)) => {
                    source.send(mime, write.as_fd());
                    sink.read_from(read);
                }
                Err(_) => sink.failed(),
            }
        }
    }

    /// Moves the application's drag (pointer or touch) off every window.
    fn drag_leave_windows(&mut self) {
        let time = self.now_ms();
        if let Some(pointer) = self.seat.get_pointer().filter(|p| p.is_grabbed()) {
            let location = pointer.current_location();
            let serial = self.next_serial();
            pointer.motion(self, None, &MotionEvent { location, serial, time });
            pointer.frame(self);
        }
        if let Some(touch) = self.seat.get_touch().filter(|t| t.is_grabbed()) {
            if let Some(start) = touch.grab_start_data() {
                touch.motion(self, None, &TouchMotionEvent { slot: start.slot, location: start.location, time });
                touch.frame(self);
            }
        }
    }

    /// One representation of a taken drag arrived.
    pub fn on_drag_read(&mut self, read: Read) {
        let Some(drag) = self.dnd.drag.as_mut().filter(|d| d.taking == Some(read.serial)) else { return };
        drag.expected = drag.expected.saturating_sub(1);
        if let Some(data) = read.data {
            drag.read.push((read.mime, data));
        }
        if drag.expected == 0 {
            self.drag_read_done();
        }
    }

    fn drag_read_done(&mut self) {
        let Some(drag) = self.dnd.drag.as_mut() else { return };
        drag.taking = None;
        drag.taken = true;
        let content = clipboard::assemble(std::mem::take(&mut drag.read));
        let takes = self.session.as_ref().map(|s| s.clipboard_types.clone()).unwrap_or_default();
        match content.and_then(|c| clipboard::for_client(&c, &takes)) {
            Some(c) => self.send_to_client(&Message::DragData(c)),
            None => tracing::debug!("drag: nothing readable in the taken drag"),
        }
        // The input held back meanwhile (the lift) ends the drag now.
        for message in std::mem::take(&mut self.dnd.deferred) {
            self.apply_input(message);
        }
        // If the drag already ended, say so; otherwise its end does.
        if !self.seat.get_pointer().is_some_and(|p| p.is_grabbed())
            && !self.seat.get_touch().is_some_and(|t| t.is_grabbed())
        {
            self.drag_ended();
        }
    }

    /// Holds back an input message while a drag's content is read; false if it is to be
    /// applied now.
    pub fn defer_input(&mut self, message: Message) -> Option<Message> {
        if !self.dnd.defers_input() {
            return Some(message);
        }
        if self.dnd.deferred.len() < MAX_DEFERRED {
            self.dnd.deferred.push(message);
        }
        None
    }

    // MARK: Housekeeping

    /// Drops that have waited too long end; called once a second.
    pub fn dnd_tick(&mut self) {
        let now = Instant::now();
        let Some(drop) = self.dnd.drop.as_ref() else { return };
        let finish_late =
            drop.performed.is_some_and(|t| now - t > FINISH_TIMEOUT) && !matches!(drop.target, Target::X11 { .. });
        let hover_late = drop.performed.is_none() && now - drop.touched > HOVER_TIMEOUT;
        let reenter_late = drop.reentered.is_some_and(|t| now - t > REENTER_TIMEOUT);
        if reenter_late {
            self.drop_finish(false, DropFailure::Rejected);
        } else if finish_late || hover_late {
            self.drop_finish(false, DropFailure::Timeout);
        }
    }

    /// The client went away: its drop ends, and a drag it was taking is let go.
    pub fn dnd_session_ended(&mut self) {
        self.drop_cancel();
        if self.dnd.defers_input() {
            if let Some(drag) = self.dnd.drag.as_mut() {
                drag.taking = None;
            }
            self.dnd.deferred.clear();
        }
    }
}

/// A drop ended by its grab: only its XDND session needs telling.
fn drop_without_grab(drop: Option<Drop>) {
    if let Some(Drop { target: Target::X11 { session, .. }, .. }) = drop {
        session.send(xdnd::Command::Leave);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wayland_target_accepts_with_a_type_and_an_action() {
        assert!(!wayland_accepts(&None, DndAction::Copy));
        assert!(!wayland_accepts(&Some("text/uri-list".into()), DndAction::empty()));
        assert!(wayland_accepts(&Some("text/uri-list".into()), DndAction::Copy));
    }
}
