//! The scroll socket: toolkit scroll reporters (the Chromium extension through
//! caboose-scroll-host, GTK and Qt preloads) report each frame's scrollers here, and the
//! compositor passes them to the client as `scroll.tree` and their `scroll.target`
//! input back (docs/display.md, "Scroll reports").
//!
//! The socket is `scroll.sock` in the instance's private directory, owner-only, for the
//! compositor's own user. Each message is a u32 little-endian length and that many bytes
//! of JSON, Chrome's native-messaging framing, so the Chromium host only copies bytes.
//!
//! Reporter to compositor, coordinates in the reporter's device pixels, relative to its
//! viewport (the part of the window its content occupies):
//!
//! ```text
//! {"type":"report","title":T,"outer":[w,h],"viewport":[w,h],"frame":F,"applied":A,
//!  "epoch":E,"tag":[x,y,w,h]|null,"scrollers":[{"id":N,"rect":[x,y,w,h],"offset":[x,y],
//!  "range":[x,y],"fixed":[[x,y,w,h],…]},…]}
//! ```
//!
//! Compositor to reporter:
//!
//! ```text
//! {"type":"bind","reporter":R,"active":B,"overscan":[w,h],"tag_top":Y,"block":S}
//! {"type":"unbind"}
//! {"type":"target","scroller":N,"seq":Q,"delta":[dx,dy]}
//! ```
//!
//! `bind` names the window's bottom overscan in device pixels, where the reporter draws
//! the frame tag (`tag_top`, viewport y, and `block`, the block side), and `active` says a
//! client places pictures by the reports. A reporter is bound to the toplevel of a process
//! in its own lineage (the browser that launched the native host, the GTK app that loaded
//! the preload); among several, the one whose title the report names, then the focused one.

use crate::state::State;
use caboose_display_protocol::{self as proto, scroll_tag, Message, Rect};
use serde_json::{json, Value};
use smithay::reexports::calloop::{generic::Generic, Interest, LoopHandle, Mode, PostAction};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// The largest message a reporter may send.
const MAX_MESSAGE: usize = 1 << 20;
/// Bytes queued for a reporter that stopped reading before it is dropped.
const MAX_QUEUED: usize = 1 << 20;
/// Scrollers and fixed rectangles kept from one report.
const MAX_SCROLLERS: usize = 8;
const MAX_FIXED: usize = 32;

/// One scroller as a reporter sent it, device pixels relative to its viewport.
#[derive(Debug, Clone, PartialEq)]
pub struct RawScroller {
    pub id: u32,
    pub rect: [f64; 4],
    pub offset: [f64; 2],
    pub range: [f64; 2],
    pub fixed: Vec<[f64; 4]>,
}

/// One frame's report.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub title: String,
    /// The whole window and the viewport, device pixels.
    pub outer: [f64; 2],
    pub viewport: [f64; 2],
    pub frame: u16,
    pub applied: u64,
    pub epoch: u64,
    pub tag: Option<[f64; 4]>,
    pub scrollers: Vec<RawScroller>,
}

fn pair(v: &Value) -> Option<[f64; 2]> {
    let a = v.as_array()?;
    match a.as_slice() {
        [x, y] => Some([x.as_f64()?, y.as_f64()?]).filter(|p| p.iter().all(|f| f.is_finite())),
        _ => None,
    }
}

fn quad(v: &Value) -> Option<[f64; 4]> {
    let a = v.as_array()?;
    match a.as_slice() {
        [x, y, w, h] => Some([x.as_f64()?, y.as_f64()?, w.as_f64()?, h.as_f64()?])
            .filter(|q| q.iter().all(|f| f.is_finite()) && q[2] >= 0.0 && q[3] >= 0.0),
        _ => None,
    }
}

impl Report {
    pub fn parse(v: &Value) -> Option<Self> {
        if v.get("type")?.as_str()? != "report" {
            return None;
        }
        let scrollers = v
            .get("scrollers")?
            .as_array()?
            .iter()
            .take(MAX_SCROLLERS)
            .filter_map(|s| {
                Some(RawScroller {
                    id: u32::try_from(s.get("id")?.as_u64()?).ok()?,
                    rect: quad(s.get("rect")?)?,
                    offset: pair(s.get("offset")?)?,
                    range: pair(s.get("range")?)?,
                    fixed: s
                        .get("fixed")
                        .and_then(Value::as_array)
                        .map(|f| f.iter().filter_map(quad).take(MAX_FIXED).collect())
                        .unwrap_or_default(),
                })
            })
            .collect();
        Some(Report {
            title: v.get("title").and_then(Value::as_str).unwrap_or_default().chars().take(512).collect(),
            outer: pair(v.get("outer")?)?,
            viewport: pair(v.get("viewport")?)?,
            frame: (v.get("frame")?.as_u64()? & 0xFFFF) as u16,
            applied: v.get("applied")?.as_u64()?,
            epoch: v.get("epoch")?.as_u64()?,
            tag: v.get("tag").and_then(quad),
            scrollers,
        })
    }
}

/// How a reporter's viewport sits in its window: window px = device px × `k` + origin.
/// The viewport is the window's bottom-left part (browser chrome above it), so it is
/// placed from the window's real size, not the reporter's idea of its outer size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    pub k: f64,
    pub x0: f64,
    pub y0: f64,
}

impl Placement {
    /// For a window of `whole` display pixels (geometry plus overscan).
    pub fn new(report: &Report, whole: (i32, i32)) -> Option<Self> {
        if report.outer[0] <= 0.0 || report.viewport[0] <= 0.0 || whole.0 <= 0 {
            return None;
        }
        let k = whole.0 as f64 / report.outer[0];
        // Within a percent is the same pixels, rounded through CSS.
        let k = if (k - k.round()).abs() < 0.01 && k.round() >= 1.0 { k.round() } else { k };
        let y0 = (whole.1 as f64 - report.viewport[1] * k).max(0.0);
        Some(Placement { k, x0: 0.0, y0 })
    }

    fn rect(&self, r: [f64; 4]) -> Rect {
        let x0 = (r[0] * self.k + self.x0).round();
        let y0 = (r[1] * self.k + self.y0).round();
        let x1 = ((r[0] + r[2]) * self.k + self.x0).round();
        let y1 = ((r[1] + r[3]) * self.k + self.y0).round();
        Rect::new(x0 as i32, y0 as i32, (x1 - x0).max(0.0) as i32, (y1 - y0).max(0.0) as i32)
    }

    /// The report as the client sees it, window-local display pixels.
    pub fn tree(&self, window: u64, reporter: u8, report: &Report) -> proto::ScrollTree {
        let tag_rect = report.tag.map(|t| self.rect(t));
        proto::ScrollTree {
            id: window,
            tag: tag_rect.map(|_| (reporter as u32) << 16 | report.frame as u32),
            tag_rect,
            applied: report.applied,
            epoch: report.epoch,
            scrollers: report
                .scrollers
                .iter()
                .map(|s| proto::Scroller {
                    id: s.id,
                    rect: self.rect(s.rect),
                    offset: [s.offset[0] * self.k, s.offset[1] * self.k],
                    range: [s.range[0] * self.k, s.range[1] * self.k],
                    fixed: s.fixed.iter().map(|&f| self.rect(f)).filter(|r| r.w > 0 && r.h > 0).collect(),
                })
                .collect(),
        }
    }
}

/// What a reporter is told about its window.
#[derive(Debug, Clone, PartialEq)]
pub struct Bind {
    pub active: bool,
    /// The window's overscan, device pixels.
    pub overscan: [f64; 2],
    /// Where the tag goes: the viewport y of the first overscan line, and the block side.
    pub tag_top: f64,
    pub block: f64,
}

impl Bind {
    /// For a window showing `shown` of its `whole` size (display pixels).
    pub fn new(active: bool, placement: &Placement, shown: (i32, i32), whole: (i32, i32)) -> Self {
        let k = placement.k;
        Bind {
            active,
            overscan: [(whole.0 - shown.0).max(0) as f64 / k, (whole.1 - shown.1).max(0) as f64 / k],
            tag_top: (shown.1 as f64 - placement.y0) / k,
            block: scroll_tag::MIN_BLOCK as f64 / k,
        }
    }

    fn json(&self, reporter: u8) -> Value {
        json!({
            "type": "bind",
            "reporter": reporter,
            "active": self.active,
            "overscan": self.overscan,
            "tag_top": self.tag_top,
            "block": self.block,
        })
    }
}

/// A toplevel a reporter may belong to.
pub struct Candidate<'a> {
    pub id: u64,
    pub lineage: &'a [u32],
    pub title: &'a str,
    pub focused: bool,
}

/// The window a reporter in process `peer` (its lineage, itself first) reporting `title`
/// belongs to: a toplevel whose process is the reporter or one of its ancestors.
pub fn choose(peer: &[u32], title: &str, candidates: &[Candidate]) -> Option<u64> {
    let mine: Vec<&Candidate> =
        candidates.iter().filter(|c| c.lineage.first().is_some_and(|pid| peer.contains(pid))).collect();
    if mine.len() <= 1 {
        return mine.first().map(|c| c.id);
    }
    // Browsers title a window after its page: "Page - Chromium".
    let titled: Vec<&&Candidate> =
        mine.iter().filter(|c| !title.is_empty() && (c.title == title || c.title.starts_with(title))).collect();
    let pool: Vec<&Candidate> = if titled.is_empty() { mine } else { titled.into_iter().copied().collect() };
    pool.iter().find(|c| c.focused).or(pool.last()).map(|c| c.id)
}

struct Peer {
    stream: UnixStream,
    read: Vec<u8>,
    queued: Vec<u8>,
    lineage: Vec<u32>,
    reporter: u8,
    window: Option<u64>,
    bind: Option<Bind>,
    report: Option<Report>,
}

#[derive(Default)]
pub struct ScrollHub {
    pub socket: Option<PathBuf>,
    peers: HashMap<u64, Peer>,
    next_conn: u64,
    next_reporter: u8,
}

fn peer_cred(stream: &UnixStream) -> Option<(u32, u32)> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `cred`.
    let r = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (r == 0 && cred.pid > 0).then_some((cred.uid, cred.pid as u32))
}

fn frame(v: &Value) -> Vec<u8> {
    let body = v.to_string().into_bytes();
    let mut out = (body.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(&body);
    out
}

impl Peer {
    /// Queues a message and writes what the socket takes; false once the peer is hopeless.
    fn send(&mut self, v: &Value) -> bool {
        self.queued.extend_from_slice(&frame(v));
        while !self.queued.is_empty() {
            match self.stream.write(&self.queued) {
                Ok(0) => return false,
                Ok(n) => {
                    self.queued.drain(..n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return false,
            }
        }
        self.queued.len() <= MAX_QUEUED
    }
}

impl ScrollHub {
    pub fn listen(path: &Path, handle: &LoopHandle<'static, State>) -> io::Result<Self> {
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        handle
            .insert_source(Generic::new(listener, Interest::READ, Mode::Level), |_, listener, state: &mut State| {
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => state.accept_scroll(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("scroll socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { socket: Some(path.to_owned()), ..Self::default() })
    }

    fn reporter_id(&mut self) -> u8 {
        // 1..=255, skipping ids still in use, so tags of live reporters differ.
        for _ in 0..255 {
            self.next_reporter = self.next_reporter.checked_add(1).unwrap_or(1);
            let id = self.next_reporter;
            if !self.peers.values().any(|p| p.reporter == id) {
                return id;
            }
        }
        self.next_reporter
    }
}

impl State {
    fn accept_scroll(&mut self, stream: UnixStream) {
        // SAFETY: getuid cannot fail.
        let Some((uid, pid)) = peer_cred(&stream) else { return };
        if uid != unsafe { libc::getuid() } {
            tracing::warn!("scroll socket: refused a peer of another user");
            return;
        }
        if stream.set_nonblocking(true).is_err() {
            return;
        }
        let Ok(reader) = stream.try_clone() else { return };
        self.scroll.next_conn += 1;
        let conn = self.scroll.next_conn;
        let reporter = self.scroll.reporter_id();
        let lineage = crate::video::lineage(pid);
        tracing::info!("scroll reporter {reporter}: pid {pid} connected");
        self.scroll.peers.insert(
            conn,
            Peer {
                stream,
                read: Vec::new(),
                queued: Vec::new(),
                lineage,
                reporter,
                window: None,
                bind: None,
                report: None,
            },
        );
        let inserted =
            self.handle.insert_source(Generic::new(reader, Interest::READ, Mode::Level), move |_, stream, state: &mut State| {
                let mut buf = [0u8; 64 * 1024];
                // SAFETY: the stream is not dropped while the source exists.
                let stream = unsafe { stream.get_mut() };
                loop {
                    match stream.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            let Some(peer) = state.scroll.peers.get_mut(&conn) else { break };
                            peer.read.extend_from_slice(&buf[..n]);
                            if !state.scroll_messages(conn) {
                                break;
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(PostAction::Continue),
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                if let Some(peer) = state.scroll.peers.remove(&conn) {
                    tracing::info!("scroll reporter {}: gone", peer.reporter);
                }
                Ok(PostAction::Remove)
            });
        if inserted.is_err() {
            self.scroll.peers.remove(&conn);
        }
    }

    /// Handles every complete message a reporter has sent; false to drop it.
    fn scroll_messages(&mut self, conn: u64) -> bool {
        loop {
            let Some(peer) = self.scroll.peers.get_mut(&conn) else { return false };
            if peer.read.len() < 4 {
                return true;
            }
            let len = u32::from_le_bytes(peer.read[..4].try_into().unwrap()) as usize;
            if len > MAX_MESSAGE {
                tracing::warn!("scroll reporter {}: {len} byte message; dropped", peer.reporter);
                return false;
            }
            if peer.read.len() < 4 + len {
                return true;
            }
            let body: Vec<u8> = peer.read.drain(..4 + len).skip(4).collect();
            let Some(report) = serde_json::from_slice::<Value>(&body).ok().as_ref().and_then(Report::parse) else {
                tracing::debug!("scroll reporter {}: not a report: {}", peer.reporter, String::from_utf8_lossy(&body[..body.len().min(200)]));
                continue;
            };
            peer.report = Some(report);
            if !self.scroll_report(conn) {
                return false;
            }
        }
    }

    fn scroll_candidates(&mut self) -> Vec<(u64, Vec<u32>, String, bool)> {
        let focused = self.focus_history.last().copied();
        let ids: Vec<u64> = self.windows.iter().filter(|w| w.parent.is_none() && w.announced.is_some()).map(|w| w.id).collect();
        ids.into_iter()
            .filter_map(|id| {
                let dh = self.dh.clone();
                let w = self.windows.get_mut(id)?;
                let lineage = w.lineage.get_or_insert_with(|| crate::session::window_lineage(&dh, &w.surface)).clone();
                let title = w.announced.as_ref().map(|a| a.title.clone()).unwrap_or_default();
                Some((id, lineage, title, focused == Some(id)))
            })
            .collect()
    }

    /// The window's size as the client sees it: shown (geometry) and whole (plus overscan).
    fn scroll_sizes(&self, id: u64) -> Option<((i32, i32), (i32, i32))> {
        let a = self.windows.get(id)?.announced.as_ref()?;
        let over = a.overscan.unwrap_or_default();
        Some(((a.geometry.w, a.geometry.h), (a.geometry.w + over.w, a.geometry.h + over.h)))
    }

    fn scroll_client(&self) -> Option<crate::net::ConnId> {
        self.session.as_ref().filter(|s| s.ready && s.scroll).map(|s| s.conn)
    }

    /// Binds a reporter after its newest report and passes the report on.
    fn scroll_report(&mut self, conn: u64) -> bool {
        let candidates = self.scroll_candidates();
        let active = self.scroll_client().is_some();
        let Some(peer) = self.scroll.peers.get(&conn) else { return false };
        let Some(report) = peer.report.clone() else { return true };
        let listed: Vec<Candidate> = candidates
            .iter()
            .map(|(id, lineage, title, focused)| Candidate { id: *id, lineage, title, focused: *focused })
            .collect();
        let window = choose(&peer.lineage, &report.title, &listed);
        let sizes = window.and_then(|id| self.scroll_sizes(id));
        let placement = sizes.and_then(|(_, whole)| Placement::new(&report, whole));
        let bind = match (sizes, placement) {
            (Some((shown, whole)), Some(p)) => Some(Bind::new(active, &p, shown, whole)),
            _ => None,
        };
        let peer = self.scroll.peers.get_mut(&conn).unwrap();
        if peer.window != window || peer.bind != bind {
            if peer.window != window {
                tracing::info!(
                    "scroll reporter {}: window {window:?} (lineage {:?}, {} toplevels)",
                    peer.reporter,
                    peer.lineage,
                    listed.len()
                );
            }
            peer.window = window;
            let message = match &bind {
                Some(b) => b.json(peer.reporter),
                None => json!({"type": "unbind"}),
            };
            peer.bind = bind;
            if !peer.send(&message) {
                return false;
            }
        }
        let reporter = peer.reporter;
        if let (Some(id), Some(p), Some(client)) = (window, placement, self.scroll_client()) {
            // The phone checks the tag's position against what the pictures carry, so a tag
            // drawn outside the overscan, or before the reporter heard of it, is simply
            // never found.
            let tree = p.tree(id, reporter, &report);
            self.net.send(client, &Message::ScrollTree(tree));
        }
        true
    }

    /// The window's reporters learn its new size, overscan or client.
    pub fn scroll_rebind(&mut self) {
        let conns: Vec<u64> = self.scroll.peers.keys().copied().collect();
        for conn in conns {
            if !self.scroll_report(conn) {
                self.scroll.peers.remove(&conn);
            }
        }
    }

    /// The client's `scroll.target`, passed to the window's reporter in its device pixels.
    pub fn scroll_target(&mut self, m: &proto::ScrollTarget) {
        let target = self.scroll.peers.iter_mut().find(|(_, p)| p.window == Some(m.id));
        let Some((&conn, peer)) = target else { return };
        let Some(sizes) = self.windows.get(m.id).and_then(|w| w.announced.as_ref()).map(|a| {
            let over = a.overscan.unwrap_or_default();
            (a.geometry.w + over.w, a.geometry.h + over.h)
        }) else {
            return;
        };
        let Some(k) = peer.report.as_ref().and_then(|r| Placement::new(r, sizes)).map(|p| p.k) else { return };
        let message = json!({
            "type": "target",
            "scroller": m.scroller,
            "seq": m.seq,
            "delta": [m.delta[0] / k, m.delta[1] / k],
        });
        if !peer.send(&message) {
            self.scroll.peers.remove(&conn);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report() -> Report {
        Report::parse(&json!({
            "type": "report", "title": "News", "outer": [1179.0, 4932.0], "viewport": [1179.0, 4752.0],
            "frame": 70_000, "applied": 17, "epoch": 2, "tag": [0.0, 2376.0, 384.0, 12.0],
            "scrollers": [
                {"id": 0, "rect": [0, 0, 1179, 4752], "offset": [0, 2412.75], "range": [0, 18904.5],
                 "fixed": [[0, 0, 1179, 120], [0, 2376, 384, 12]]},
                {"id": 4, "rect": [60, 720, 1059, 600], "offset": [0, 96], "range": [0, 1404], "fixed": "nonsense"},
                {"id": "bad"}
            ]
        }))
        .unwrap()
    }

    #[test]
    fn parses_a_report_and_skips_malformed_scrollers() {
        let r = report();
        assert_eq!(r.frame, (70_000 & 0xFFFF) as u16);
        assert_eq!(r.scrollers.len(), 2);
        assert!(r.scrollers[1].fixed.is_empty());
        assert!(Report::parse(&json!({"type": "hello"})).is_none());
    }

    #[test]
    fn places_the_viewport_at_the_bottom_of_the_window() {
        // A 1179 x 2376 shown window with 2556 px of overscan; 180 px of browser chrome.
        let r = report();
        let p = Placement::new(&r, (1179, 4932)).unwrap();
        assert_eq!(p, Placement { k: 1.0, x0: 0.0, y0: 180.0 });
        let tree = p.tree(7, 3, &r);
        assert_eq!(tree.tag, Some(0x03_0000 | (70_000 & 0xFFFF)));
        assert_eq!(tree.tag_rect, Some(Rect::new(0, 2556, 384, 12)));
        assert_eq!(tree.scrollers[0].rect, Rect::new(0, 180, 1179, 4752));
        assert_eq!(tree.scrollers[0].fixed, vec![Rect::new(0, 180, 1179, 120), Rect::new(0, 2556, 384, 12)]);
        let bind = Bind::new(true, &p, (1179, 2376), (1179, 4932));
        assert_eq!(bind.overscan, [0.0, 2556.0]);
        // The first overscan line, in viewport pixels: 2376 - 180.
        assert_eq!(bind.tag_top, 2196.0);
        assert_eq!(bind.block, 12.0);
    }

    #[test]
    fn scales_an_x11_window_drawn_at_a_lower_scale() {
        let mut r = report();
        r.outer = [393.0, 1644.0];
        r.viewport = [393.0, 1584.0];
        let p = Placement::new(&r, (1179, 4932)).unwrap();
        assert_eq!(p.k, 3.0);
        assert_eq!(p.y0, 180.0);
        let tree = p.tree(7, 1, &r);
        assert_eq!(tree.scrollers[0].offset, [0.0, 2412.75 * 3.0]);
        assert_eq!(Bind::new(true, &p, (1179, 2376), (1179, 4932)).block, 4.0);
    }

    #[test]
    fn binds_to_a_window_of_its_own_lineage() {
        let (browser, other) = ([100u32, 1], [200u32, 1]);
        let windows = [
            Candidate { id: 1, lineage: &other, title: "News - Chromium", focused: true },
            Candidate { id: 2, lineage: &browser, title: "Mail - Chromium", focused: false },
            Candidate { id: 3, lineage: &browser, title: "News - Chromium", focused: false },
        ];
        // The native host is a child of the browser.
        let host = [150u32, 100, 1];
        assert_eq!(choose(&host, "News", &windows), Some(3));
        assert_eq!(choose(&host, "Mail", &windows), Some(2));
        assert_eq!(choose(&host, "", &windows), Some(3));
        assert_eq!(choose(&[999, 1], "News", &windows), None);
        assert_eq!(choose(&host, "News", &windows[..2]), Some(2));
    }
}
