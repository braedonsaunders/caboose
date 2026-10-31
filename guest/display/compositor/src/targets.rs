//! Touch targets: the controls of the focused window, from its accessibility tree, for a
//! client that aims touches at them (docs/display.md, "Touch targets").
//!
//! While a client that asked for `targets` is connected, the compositor runs the provider,
//! `guest/desktop-mcp/caboose-targets.py serve`, with the seat's launch environment. It
//! prints one JSON line whenever the focused window's controls change, rectangles in the
//! seat's logical space:
//!
//! ```text
//! {"window":ID,"targets":[[x,y,w,h,kind],…]}
//! ```
//!
//! and reads `input ID` lines, written after the client's input to a window, when controls
//! most often change. The compositor gives each control to the topmost window of the
//! focused window's family (its popups, then itself) that holds its centre, converts it to
//! that window's display pixels, and sends `targets` for each window whose list changed.
//! Without a client nothing runs.

use crate::state::State;
use caboose_display_protocol::{self as proto, Message, Rect};
use serde_json::Value;
use smithay::reexports::calloop::{generic::Generic, Interest, Mode, PostAction, RegistrationToken};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

/// Where guest/desktop-mcp/install.sh puts the provider.
pub const PROVIDER: &str = "/opt/caboose/caboose-targets.py";
/// The most controls kept for one window, and the longest line read from the provider.
const MAX_TARGETS: usize = 1024;
const MAX_LINE: usize = 1 << 20;
/// Input hints are at most this frequent; the provider waits for input to settle anyway.
const HINT_GAP: Duration = Duration::from_millis(40);

#[derive(Default)]
pub struct Targets {
    /// The seat's launch environment, once the compositor is ready.
    pub env: Vec<(String, String)>,
    provider: Option<Provider>,
    /// What each window's client was last sent.
    sent: HashMap<u64, Vec<proto::Target>>,
    serial: u64,
}

struct Provider {
    child: Child,
    stdin: ChildStdin,
    source: Option<RegistrationToken>,
    read: Vec<u8>,
    hinted: Option<Instant>,
}

impl Drop for Provider {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A window a control can belong to: its id, its geometry's logical origin and size, and
/// its display's scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Place {
    pub id: u64,
    pub origin: (f64, f64),
    pub size: (f64, f64),
    pub scale: f64,
}

/// Each control, in the window (topmost of `family` first) that holds its centre, in that
/// window's display pixels. Every window of the family gets a list, empty or not.
pub fn distribute(controls: &[[f64; 5]], family: &[Place]) -> HashMap<u64, Vec<proto::Target>> {
    let mut out: HashMap<u64, Vec<proto::Target>> = family.iter().map(|p| (p.id, Vec::new())).collect();
    for &[x, y, w, h, kind] in controls {
        if !(w > 0.0 && h > 0.0) || !(0.0..=255.0).contains(&kind) {
            continue;
        }
        let (cx, cy) = (x + w / 2.0, y + h / 2.0);
        let Some(place) = family.iter().find(|p| {
            cx >= p.origin.0 && cy >= p.origin.1 && cx < p.origin.0 + p.size.0 && cy < p.origin.1 + p.size.1
        }) else {
            continue;
        };
        let list = out.get_mut(&place.id).unwrap();
        if list.len() >= MAX_TARGETS {
            continue;
        }
        let px = |v: f64| (v * place.scale).round() as i32;
        let (left, top) = (px(x - place.origin.0), px(y - place.origin.1));
        let (right, bottom) = (px(x + w - place.origin.0), px(y + h - place.origin.1));
        list.push(proto::Target { rect: Rect::new(left, top, (right - left).max(1), (bottom - top).max(1)), kind: kind as u8 });
    }
    out
}

/// One provider line: the focused window and its controls; None when it is not one.
pub fn parse(line: &[u8]) -> Option<(u64, Vec<[f64; 5]>)> {
    let v: Value = serde_json::from_slice(line).ok()?;
    let window = v.get("window")?.as_u64()?;
    let controls = v
        .get("targets")?
        .as_array()?
        .iter()
        .filter_map(|t| {
            let t = t.as_array()?;
            (t.len() == 5).then_some(())?;
            let mut out = [0.0; 5];
            for (slot, value) in out.iter_mut().zip(t) {
                *slot = value.as_f64()?;
            }
            Some(out)
        })
        .collect();
    Some((window, controls))
}

impl State {
    fn targets_client(&self) -> Option<crate::net::ConnId> {
        self.session.as_ref().filter(|s| s.ready && s.targets).map(|s| s.conn)
    }

    /// Runs the provider while a client wants targets, and stops it when none does.
    pub fn targets_session_changed(&mut self) {
        let wanted = self.targets_client().is_some();
        self.targets.sent.clear();
        if !wanted {
            if let Some(provider) = self.targets.provider.take() {
                if let Some(token) = provider.source {
                    self.handle.remove(token);
                }
            }
            return;
        }
        if self.targets.provider.is_some() || !Path::new(PROVIDER).is_file() {
            return;
        }
        let mut command = Command::new("python3");
        command
            .arg(PROVIDER)
            .arg("serve")
            .envs(self.targets.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(e) => {
                tracing::warn!("touch targets: cannot start {PROVIDER}: {e}");
                return;
            }
        };
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else { return };
        for fd in [stdin.as_raw_fd(), stdout.as_raw_fd()] {
            // SAFETY: fcntl on descriptors this process owns.
            unsafe { libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK) };
        }
        let pid = child.id();
        let source = self.handle.insert_source(Generic::new(stdout, Interest::READ, Mode::Level), move |_, out, state: &mut State| {
            let mut buf = [0u8; 64 * 1024];
            // SAFETY: the pipe is not dropped while the source exists.
            let out = unsafe { out.get_mut() };
            loop {
                match out.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if !state.targets_read(pid, &buf[..n]) {
                            break;
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(PostAction::Continue),
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            if state.targets.provider.as_ref().is_some_and(|p| p.child.id() == pid) {
                tracing::info!("touch targets: provider ended");
                state.targets.provider = None;
            }
            Ok(PostAction::Remove)
        });
        tracing::info!("touch targets: provider {pid} started");
        self.targets.provider = Some(Provider { child, stdin, source: source.ok(), read: Vec::new(), hinted: None });
    }

    /// Bytes from provider `pid`; false to stop reading it.
    fn targets_read(&mut self, pid: u32, bytes: &[u8]) -> bool {
        let Some(provider) = self.targets.provider.as_mut().filter(|p| p.child.id() == pid) else { return false };
        provider.read.extend_from_slice(bytes);
        let mut lines = Vec::new();
        while let Some(end) = provider.read.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = provider.read.drain(..=end).collect();
            lines.push(line);
        }
        if provider.read.len() > MAX_LINE {
            tracing::warn!("touch targets: provider line over {MAX_LINE} bytes; stopped");
            return false;
        }
        for line in lines {
            if let Some((window, controls)) = parse(&line) {
                self.targets_update(window, &controls);
            }
        }
        true
    }

    /// The focused window's family, topmost first: its popups, newest first, then itself.
    fn targets_family(&self, root: u64) -> Vec<Place> {
        let mut ids: Vec<u64> = self
            .windows
            .iter()
            .filter(|w| {
                let mut parent = w.parent;
                while let Some(p) = parent {
                    if p == root {
                        return true;
                    }
                    parent = self.windows.get(p).and_then(|w| w.parent);
                }
                false
            })
            .map(|w| w.id)
            .collect();
        ids.sort_unstable_by(|a, b| b.cmp(a));
        ids.push(root);
        ids.into_iter()
            .filter_map(|id| {
                let w = self.windows.get(id)?;
                w.announced.as_ref()?;
                let origin = self.windows.logical_origin(id, &self.displays);
                let size = w.local_geometry().size;
                let scale = self.displays.resolve(Some(w.display)).info.scale;
                Some(Place { id, origin: (origin.x as f64, origin.y as f64), size: (size.w as f64, size.h as f64), scale })
            })
            .collect()
    }

    fn targets_update(&mut self, root: u64, controls: &[[f64; 5]]) {
        let Some(conn) = self.targets_client() else { return };
        let family = self.targets_family(root);
        for (id, list) in distribute(controls, &family) {
            if self.targets.sent.get(&id) == Some(&list) || (list.is_empty() && !self.targets.sent.contains_key(&id)) {
                continue;
            }
            self.targets.serial += 1;
            self.net.send(conn, &Message::Targets(proto::Targets { id, serial: self.targets.serial, targets: list.clone() }));
            self.targets.sent.insert(id, list);
        }
    }

    /// The client's input reached window `id`: the provider reads again once it settles.
    pub fn targets_input(&mut self, id: u64) {
        let Some(provider) = self.targets.provider.as_mut() else { return };
        let now = Instant::now();
        if provider.hinted.is_some_and(|t| now.duration_since(t) < HINT_GAP) {
            return;
        }
        provider.hinted = Some(now);
        // A full pipe drops the hint: the provider is already behind and reads anyway.
        let _ = provider.stdin.write_all(format!("input {id}\n").as_bytes());
    }

    pub fn targets_window_gone(&mut self, id: u64) {
        self.targets.sent.remove(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(id: u64, x: f64, y: f64, w: f64, h: f64, scale: f64) -> Place {
        Place { id, origin: (x, y), size: (w, h), scale }
    }

    #[test]
    fn parses_the_providers_lines() {
        let (window, controls) = parse(br#"{"window":7,"targets":[[10,20,30,40,1],[1,2,3],"x",[0,0,5,5,129]]}"#).unwrap();
        assert_eq!(window, 7);
        assert_eq!(controls, vec![[10.0, 20.0, 30.0, 40.0, 1.0], [0.0, 0.0, 5.0, 5.0, 129.0]]);
        assert!(parse(b"not json").is_none());
        assert!(parse(br#"{"window":null,"targets":[]}"#).is_none());
    }

    #[test]
    fn controls_go_to_the_topmost_window_holding_their_centre_in_its_pixels() {
        // A menu popup (id 9) over its window (id 7) on a 2x display.
        let family = [place(9, 100.0, 50.0, 80.0, 60.0, 2.0), place(7, 10.0, 10.0, 400.0, 300.0, 2.0)];
        let controls = [
            [110.0, 60.0, 60.0, 20.0, 4.0],  // a menu item
            [20.0, 20.0, 16.0, 16.0, 1.0],   // a toolbar button
            [500.0, 500.0, 10.0, 10.0, 1.0], // outside every window
            [30.0, 30.0, 0.0, 10.0, 1.0],    // empty
        ];
        let out = distribute(&controls, &family);
        assert_eq!(out[&9], vec![proto::Target { rect: Rect::new(20, 20, 120, 40), kind: 4 }]);
        assert_eq!(out[&7], vec![proto::Target { rect: Rect::new(20, 20, 32, 32), kind: 1 }]);
    }

    #[test]
    fn every_window_of_the_family_gets_a_list() {
        let out = distribute(&[], &[place(3, 0.0, 0.0, 10.0, 10.0, 1.0)]);
        assert_eq!(out[&3], vec![]);
    }
}
