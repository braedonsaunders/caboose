//! The control socket: the seat as local tools see it. Accessibility helpers and agents'
//! desktop tools list the windows (with each one's process, geometry and focus), act on
//! them with the seat's own pointer and keyboard, and take pictures of them. Wayland and
//! X11 (Xwayland) windows are the same here, so the tools need nothing from X.
//!
//! The socket is `control.sock` in the instance's private directory, owner-only, and serves
//! only processes of the compositor's own user. One request per line, one JSON answer per
//! line (`{"ok":true,…}` or `{"ok":false,"error":"…"}`); a screenshot's answer is followed by
//! the PNG's bytes. Positions are in the compositor's logical space, the space X11 clients
//! also see as their root window's.
//!
//! ```text
//! windows                      every window, bottom to top: id, parent, kind, title, app_id,
//!                              pid, x11 (its X window, for Xwayland), rect (the window),
//!                              surface (its root surface's x, y, w, h, shadows included),
//!                              display, scale, focused
//! focus ID                     give a window the keyboard
//! click X Y [BUTTON [COUNT]]   BUTTON is left, middle or right
//! press X Y [BUTTON]           and `release X Y [BUTTON]`, for a drag
//! move X Y
//! scroll X Y DX DY             wheel clicks; positive DY scrolls down
//! key COMBO…                   xdotool-style combos: ctrl+s, alt+F4, shift+Tab, Return
//! type TEXT                    the rest of the line; `\n` and `\\` are escapes
//! settle                       let every window draw now (frame callbacks), as if watched
//! screenshot [ID]              a window, or the whole display: {"png":N,…} then N bytes
//! frames [SINCE]               what happened after SINCE (CLOCK_MONOTONIC µs, default 0):
//!                              now_us; per window its commits and the pictures sent to the
//!                              client as [at, pts, bytes, refined]; input from the client as
//!                              [at, kind] (pointer, scroll, touch, key, text). Each list
//!                              keeps the newest 1024 entries.
//! ```

use crate::encode::CpuImage;
use crate::render::Canvas;
use crate::state::{KeyboardFocus, State};
use crate::windows::Surface;
use caboose_display_protocol::{self as proto, buttons, WindowKind};
use smithay::backend::renderer::utils::with_renderer_surface_state;
use smithay::reexports::calloop::{generic::Generic, Interest, LoopHandle, Mode, PostAction};
use smithay::utils::{Logical, Point, Rectangle};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// The longest request line; anything longer closes the connection.
const MAX_LINE: usize = 1 << 20;
/// The largest picture a screenshot composes, per side, in logical pixels.
const MAX_SHOT: i32 = 8192;

#[derive(Default)]
pub struct Control {
    pub socket: Option<PathBuf>,
    pending: HashMap<u64, Vec<u8>>,
    next_conn: u64,
}

/// One window as `windows` lists it.
struct Listed {
    id: u64,
    rect: Rectangle<i32, Logical>,
}

fn peer_uid(stream: &UnixStream) -> Option<u32> {
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
    (r == 0).then_some(cred.uid)
}

impl Control {
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
                        Ok((stream, _)) => state.accept_control(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("control socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { socket: Some(path.to_owned()), ..Self::default() })
    }
}

/// A JSON string literal.
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn error(message: &str) -> Vec<u8> {
    format!("{{\"ok\":false,\"error\":{}}}\n", json_str(message)).into_bytes()
}

/// `type`'s text: the rest of the line with `\n` and `\\` unescaped.
pub fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn button(name: Option<&str>) -> Result<u32, String> {
    match name.unwrap_or("left") {
        "left" | "1" => Ok(buttons::LEFT),
        "middle" | "2" => Ok(buttons::MIDDLE),
        "right" | "3" => Ok(buttons::RIGHT),
        other => Err(format!("unknown button {other}")),
    }
}

/// One xdotool-style combo (`ctrl+shift+t`, `Return`, `super+F5`) as modifiers and a keysym.
pub fn parse_combo(combo: &str) -> Result<(Vec<String>, u32), String> {
    use smithay::input::keyboard::xkb;
    let parts: Vec<&str> = combo.split('+').filter(|p| !p.is_empty()).collect();
    let Some((key, mods)) = parts.split_last() else { return Err("empty key combo".into()) };
    let mut names = Vec::new();
    for m in mods {
        let name = match m.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => "control",
            "shift" => "shift",
            "alt" | "mod1" => "mod1",
            "super" | "meta" | "cmd" | "mod4" => "mod4",
            other => return Err(format!("unknown modifier {other}")),
        };
        if !names.iter().any(|n: &String| n == name) {
            names.push(name.to_owned());
        }
    }
    let aliases = [("enter", "Return"), ("esc", "Escape"), ("del", "Delete"), ("space", "space"), ("tab", "Tab")];
    let name = aliases.iter().find(|(a, _)| a.eq_ignore_ascii_case(key)).map(|(_, n)| *n).unwrap_or(key);
    let mut sym = xkb::keysym_from_name(name, xkb::KEYSYM_NO_FLAGS);
    if sym.raw() == 0 {
        sym = xkb::keysym_from_name(name, xkb::KEYSYM_CASE_INSENSITIVE);
    }
    if sym.raw() == 0 {
        return Err(format!("unknown key {key}"));
    }
    // A printable key's Shift comes from its level, so shift+t is typed as T.
    let mut raw = sym.raw();
    if names.iter().any(|n| n == "shift") && (0x61..=0x7a).contains(&raw) {
        raw -= 0x20;
    }
    Ok((names, raw))
}

impl State {
    fn accept_control(&mut self, stream: UnixStream) {
        // SAFETY: getuid cannot fail.
        if peer_uid(&stream) != Some(unsafe { libc::getuid() }) {
            tracing::warn!("control socket: refused a peer of another user");
            return;
        }
        if stream.set_nonblocking(true).is_err() {
            return;
        }
        self.control.next_conn += 1;
        let id = self.control.next_conn;
        self.control.pending.insert(id, Vec::new());
        let inserted = self.handle.insert_source(
            Generic::new(stream, Interest::READ, Mode::Level),
            move |_, stream, state: &mut State| {
                let mut buf = [0u8; 16 * 1024];
                // SAFETY: the stream is not dropped while the source exists.
                let stream = unsafe { stream.get_mut() };
                loop {
                    match stream.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            let Some(pending) = state.control.pending.get_mut(&id) else { break };
                            pending.extend_from_slice(&buf[..n]);
                            if pending.len() > MAX_LINE && !pending.contains(&b'\n') {
                                break;
                            }
                            while let Some(end) =
                                state.control.pending.get(&id).and_then(|p| p.iter().position(|b| *b == b'\n'))
                            {
                                let line: Vec<u8> = state.control.pending.get_mut(&id).unwrap().drain(..=end).collect();
                                let line =
                                    String::from_utf8_lossy(&line[..line.len() - 1]).trim_end_matches('\r').to_owned();
                                let answer = state.control_request(&line);
                                // Answers are small except pictures, which the tool is waiting for.
                                let _ = stream.set_nonblocking(false);
                                let written = stream.write_all(&answer);
                                let _ = stream.set_nonblocking(true);
                                if written.is_err() {
                                    state.control.pending.remove(&id);
                                    return Ok(PostAction::Remove);
                                }
                            }
                            continue;
                        }
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(PostAction::Continue),
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                state.control.pending.remove(&id);
                Ok(PostAction::Remove)
            },
        );
        if inserted.is_err() {
            self.control.pending.remove(&id);
        }
    }

    /// Answers one request line.
    pub fn control_request(&mut self, line: &str) -> Vec<u8> {
        let (op, rest) = line.split_once(' ').unwrap_or((line, ""));
        let args: Vec<&str> = rest.split_whitespace().collect();
        let number = |i: usize| -> Result<f64, String> {
            args.get(i)
                .and_then(|a| a.parse::<f64>().ok())
                .filter(|v| v.is_finite())
                .ok_or_else(|| format!("{op}: argument {} must be a number", i + 1))
        };
        let result = match op {
            "windows" => Ok(self.control_windows()),
            "focus" => args
                .first()
                .and_then(|a| a.parse::<u64>().ok())
                .filter(|id| self.windows.get(*id).is_some())
                .map(|id| {
                    self.focus_window(id);
                    b"{\"ok\":true}\n".to_vec()
                })
                .ok_or_else(|| "no such window".to_owned()),
            "click" | "press" | "release" | "move" => (|| {
                let at: Point<f64, Logical> = (number(0)?, number(1)?).into();
                let button = button(args.get(2).copied())?;
                let count = if op == "click" {
                    args.get(3)
                        .map(|c| c.parse::<u32>().map_err(|_| "click: count must be a number"))
                        .transpose()?
                        .unwrap_or(1)
                        .clamp(1, 3)
                } else {
                    0
                };
                let id = self.window_at(at).ok_or("nothing is at that position")?;
                let send = |state: &mut State, pressed: u32| state.pointer_at(id, at, pressed, None);
                match op {
                    "move" => send(self, 0),
                    "press" => send(self, button),
                    "release" => send(self, 0),
                    _ => {
                        for _ in 0..count {
                            send(self, button);
                            send(self, 0);
                        }
                    }
                }
                Ok(format!("{{\"ok\":true,\"window\":{id}}}\n").into_bytes())
            })(),
            "scroll" => (|| {
                let at: Point<f64, Logical> = (number(0)?, number(1)?).into();
                let scroll = proto::Scroll { dx: number(2)?, dy: number(3)?, precise: false, seq: None };
                let id = self.window_at(at).ok_or("nothing is at that position")?;
                self.pointer_at(id, at, 0, Some(scroll));
                Ok(format!("{{\"ok\":true,\"window\":{id}}}\n").into_bytes())
            })(),
            "key" => (|| {
                if args.is_empty() {
                    return Err("key: no combo".to_owned());
                }
                let combos = args.iter().map(|c| parse_combo(c)).collect::<Result<Vec<_>, _>>()?;
                for (mods, keysym) in combos {
                    self.key(&proto::Key { keysym, pressed: true, mods: mods.clone() });
                    self.key(&proto::Key { keysym, pressed: false, mods });
                }
                Ok(b"{\"ok\":true}\n".to_vec())
            })(),
            "type" => {
                let text = unescape(rest);
                if !text.is_empty() {
                    self.text(&proto::Text { commit: Some(text), ..Default::default() });
                }
                Ok(b"{\"ok\":true}\n".to_vec())
            }
            "settle" => {
                // Nothing paces a seat nobody watches, so applications draw once a second;
                // a tool about to look lets them catch up first.
                let ids: Vec<u64> = self
                    .windows
                    .iter()
                    .filter(|w| w.stream.callbacks_pending && w.stream.can_release_callbacks())
                    .map(|w| w.id)
                    .collect();
                for id in ids {
                    self.release_frame_callbacks(id);
                }
                Ok(b"{\"ok\":true}\n".to_vec())
            }
            "screenshot" => match args.first() {
                Some(a) => match a.parse::<u64>().ok().filter(|id| self.windows.get(*id).is_some()) {
                    Some(id) => self.screenshot(Some(id)),
                    None => Err("no such window".to_owned()),
                },
                None => self.screenshot(None),
            },
            "frames" => match args.first().map(|a| a.parse::<u64>()) {
                None => Ok(self.control_frames(0)),
                Some(Ok(since)) => Ok(self.control_frames(since)),
                Some(Err(_)) => Err("frames: SINCE must be a number".to_owned()),
            },
            "" => Err("empty request".to_owned()),
            other => Err(format!("unknown request {other}")),
        };
        if let Err(e) = self.dh.flush_clients() {
            tracing::debug!("control: flush: {e}");
        }
        result.unwrap_or_else(|e| error(&e))
    }

    /// The window under `at`, topmost first.
    fn window_at(&self, at: Point<f64, Logical>) -> Option<u64> {
        self.stacked().into_iter().rev().find(|w| w.rect.to_f64().contains(at)).map(|w| w.id)
    }

    /// A pointer event at a logical position, as the client would send it for window `id`.
    fn pointer_at(&mut self, id: u64, at: Point<f64, Logical>, buttons: u32, scroll: Option<proto::Scroll>) {
        let Some(w) = self.windows.get(id) else { return };
        let display = self.displays.resolve(Some(w.display));
        let origin = self.windows.logical_origin(id, &self.displays).to_f64();
        let (x, y) = (display.to_pixels(at.x - origin.x), display.to_pixels(at.y - origin.y));
        self.pointer(&proto::Pointer { id, x, y, buttons, scroll });
    }

    /// The keyboard's window.
    fn focused_window(&self) -> Option<u64> {
        match self.seat.get_keyboard()?.current_focus()? {
            KeyboardFocus::Wayland(s) => self.window_of_surface(&s),
            KeyboardFocus::X11(x) => self.windows.by_x11(&x),
        }
    }

    /// Windows bottom to top: toplevels by when they or their dialogs last had focus
    /// (never-focused ones first), each followed by its dialogs and popups.
    fn stacked(&self) -> Vec<Listed> {
        let rank = |id: u64| self.focus_history.iter().position(|f| *f == id);
        let mut roots: Vec<u64> = self
            .windows
            .ids()
            .into_iter()
            .filter(|id| self.windows.get(*id).is_some_and(|w| w.parent.is_none_or(|p| self.windows.get(p).is_none())))
            .collect();
        // A window family is as high as its most recently focused member (a dialog raises
        // the window it belongs to).
        let family_rank = |id: u64| {
            std::iter::once(id).chain(self.windows.descendants(id)).filter_map(rank).max().map_or(0, |r| r + 1)
        };
        roots.sort_by_key(|id| (family_rank(*id), *id));
        let mut out = Vec::new();
        for root in roots {
            let mut ids = vec![root];
            let mut children = self.windows.descendants(root);
            children.sort_by_key(|id| (rank(*id).map_or(0, |r| r + 1), *id));
            ids.extend(children);
            for id in ids {
                let Some(w) = self.windows.get(id) else { continue };
                let rect = Rectangle::new(self.windows.logical_origin(id, &self.displays), w.local_geometry().size);
                if rect.size.w > 0 && rect.size.h > 0 {
                    out.push(Listed { id, rect });
                }
            }
        }
        out
    }

    pub(crate) fn window_pid(&self, surface: &Surface) -> Option<u32> {
        use smithay::reexports::wayland_server::Resource;
        match surface {
            Surface::X11(x) => x.pid(),
            s => s
                .wl_surface()
                .and_then(|w| self.dh.get_client(w.id()).ok())
                .and_then(|c| c.get_credentials(&self.dh).ok())
                .map(|c| c.pid as u32),
        }
    }

    fn control_windows(&self) -> Vec<u8> {
        let focused = self.focused_window();
        let mut items = Vec::new();
        for listed in self.stacked() {
            let Some(w) = self.windows.get(listed.id) else { continue };
            let Some(described) = self.windows.describe(listed.id, &self.displays) else { continue };
            let surface = self.windows.surface_origin(listed.id, &self.displays);
            // The root surface's own size: client-side shadows included, unlike `rect`.
            let surface_size = w
                .surface
                .wl_surface()
                .and_then(|s| with_renderer_surface_state(&s, |st| st.surface_size()).flatten())
                .unwrap_or(listed.rect.size);
            let display = self.displays.resolve(Some(w.display));
            let kind = match w.kind {
                WindowKind::Toplevel => "toplevel",
                WindowKind::Dialog => "dialog",
                WindowKind::Popup => "popup",
            };
            let r = listed.rect;
            items.push(format!(
                "{{\"id\":{},\"parent\":{},\"kind\":\"{kind}\",\"title\":{},\"app_id\":{},\"pid\":{},\"x11\":{},\
                 \"rect\":[{},{},{},{}],\"surface\":[{},{},{},{}],\"display\":{},\"scale\":{},\"focused\":{}}}",
                listed.id,
                w.parent.map_or("null".into(), |p| p.to_string()),
                json_str(&described.title),
                json_str(&described.app_id),
                self.window_pid(&w.surface).map_or("null".into(), |p| p.to_string()),
                match &w.surface {
                    Surface::X11(x) => x.window_id().to_string(),
                    _ => "null".into(),
                },
                r.loc.x,
                r.loc.y,
                r.size.w,
                r.size.h,
                surface.x,
                surface.y,
                surface_size.w,
                surface_size.h,
                display.info.id,
                display.info.scale,
                focused == Some(listed.id),
            ));
        }
        let bounds = self
            .displays
            .ids()
            .iter()
            .filter_map(|id| self.displays.get(*id))
            .map(|d| d.logical_rect())
            .fold(None::<Rectangle<i32, Logical>>, |acc, r| Some(acc.map_or(r, |a| a.merge(r))));
        let b = bounds.unwrap_or_default();
        format!(
            "{{\"ok\":true,\"windows\":[{}],\"focused\":{},\"bounds\":[{},{},{},{}]}}\n",
            items.join(","),
            focused.map_or("null".into(), |f| f.to_string()),
            b.loc.x,
            b.loc.y,
            b.size.w,
            b.size.h
        )
        .into_bytes()
    }

    fn control_frames(&self, since: u64) -> Vec<u8> {
        let windows: Vec<String> = self
            .windows
            .ids()
            .into_iter()
            .filter_map(|id| self.windows.get(id).map(|w| (id, &w.stream.trace)))
            .map(|(id, trace)| {
                let commits: Vec<String> = trace.commits.after(since, |t| *t).iter().map(u64::to_string).collect();
                let sent: Vec<String> = trace
                    .sent
                    .after(since, |s| s.at_us)
                    .iter()
                    .map(|s| format!("[{},{},{},{}]", s.at_us, s.pts_us, s.bytes, s.refined))
                    .collect();
                format!("{{\"id\":{id},\"commits\":[{}],\"sent\":[{}]}}", commits.join(","), sent.join(","))
            })
            .collect();
        let input: Vec<String> =
            self.input_trace.after(since, |i| i.at_us).iter().map(|i| format!("[{},\"{}\"]", i.at_us, i.kind)).collect();
        format!(
            "{{\"ok\":true,\"now_us\":{},\"windows\":[{}],\"input\":[{}]}}\n",
            self.now_us(),
            windows.join(","),
            input.join(",")
        )
        .into_bytes()
    }

    /// One window's picture (logical pixels), or every window composed over the displays.
    fn screenshot(&mut self, only: Option<u64>) -> Result<Vec<u8>, String> {
        let stacked = self.stacked();
        let area = match only {
            Some(id) => stacked.iter().find(|w| w.id == id).map(|w| w.rect).ok_or("the window has no picture")?,
            None => {
                let displays = self.displays.ids();
                displays
                    .iter()
                    .filter_map(|id| self.displays.get(*id))
                    .map(|d| d.logical_rect())
                    .fold(None::<Rectangle<i32, Logical>>, |acc, r| Some(acc.map_or(r, |a| a.merge(r))))
                    .ok_or("no display")?
            }
        };
        let (w, h) = (area.size.w.clamp(1, MAX_SHOT), area.size.h.clamp(1, MAX_SHOT));
        // RGB, dark grey where no window is.
        let mut rgb = vec![0x1e_u8; (w * h * 3) as usize];
        for listed in stacked.iter().filter(|l| only.is_none_or(|id| id == l.id)) {
            let Some(win) = self.windows.get(listed.id) else { continue };
            let Some(root) = win.surface.wl_surface() else { continue };
            let local = win.local_geometry();
            let size = (listed.rect.size.w, listed.rect.size.h).into();
            let mut image = CpuImage::new(listed.rect.size.w as u32, listed.rect.size.h as u32);
            let mut canvas = Canvas::new(size, 1.0);
            if let Err(e) = canvas.render(&mut self.renderer, &root, local.loc, &mut image, 0) {
                tracing::debug!("control: window {}: {e}", listed.id);
                continue;
            }
            let (dx, dy) = (listed.rect.loc.x - area.loc.x, listed.rect.loc.y - area.loc.y);
            for row in 0..listed.rect.size.h {
                let ty = dy + row;
                if ty < 0 || ty >= h {
                    continue;
                }
                for col in 0..listed.rect.size.w {
                    let tx = dx + col;
                    if tx < 0 || tx >= w {
                        continue;
                    }
                    let s = row as usize * image.stride + col as usize * 4;
                    let t = (ty * w + tx) as usize * 3;
                    // X8R8G8B8 in memory is B, G, R, X.
                    rgb[t] = image.data[s + 2];
                    rgb[t + 1] = image.data[s + 1];
                    rgb[t + 2] = image.data[s];
                }
            }
        }
        let png = crate::stream::png(w as u32, h as u32, &rgb)?;
        let mut out =
            format!("{{\"ok\":true,\"png\":{},\"rect\":[{},{},{},{}]}}\n", png.len(), area.loc.x, area.loc.y, w, h)
                .into_bytes();
        out.extend_from_slice(&png);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combos_parse_like_xdotool() {
        let ctrl_s = parse_combo("ctrl+s").unwrap();
        assert_eq!(ctrl_s.0, ["control"]);
        assert_eq!(ctrl_s.1, 0x73);
        assert_eq!(parse_combo("Return").unwrap(), (vec![], 0xff0d));
        assert_eq!(parse_combo("enter").unwrap().1, 0xff0d);
        assert_eq!(parse_combo("super+shift+F5").unwrap().0, ["mod4", "shift"]);
        assert_eq!(parse_combo("ctrl+shift+t").unwrap(), (vec!["control".to_owned(), "shift".to_owned()], 0x54));
        assert_eq!(parse_combo("alt+Tab").unwrap(), (vec!["mod1".to_owned()], 0xff09));
        assert!(parse_combo("hyper+x").is_err());
        assert!(parse_combo("NotAKey").is_err());
        assert!(parse_combo("").is_err());
    }

    #[test]
    fn typed_text_unescapes_newlines_and_backslashes() {
        assert_eq!(unescape(r"one\ntwo"), "one\ntwo");
        assert_eq!(unescape(r"a\\nb"), "a\\nb");
        assert_eq!(unescape(r"tab\there"), "tab\there");
        assert_eq!(unescape("plain"), "plain");
    }

    #[test]
    fn json_strings_are_escaped() {
        assert_eq!(json_str("a\"b\\c\nd\u{1}"), "\"a\\\"b\\\\c\\nd\\u0001\"");
    }
}
