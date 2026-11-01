//! Gamepads for container computers, which have no uinput (docs/devices.md, "Gamepads in
//! container computers"). The host makes each pad with its own uinput and puts only the
//! pad's evdev node into the computer. The hub reaches the host over a link the host opens:
//! it runs `caboose-display --pad-link` in the computer, which joins the hub's socket to
//! its standard input and output, and joins those to `caboose-display --host-pads`, which
//! it runs on the host with /dev/uinput and nothing else.
//!
//! One JSON object per line, in both directions:
//!
//! - hub → host: `{"add":ID,"name":TEXT,"rumble":BOOL}`, `{"state":ID,"buttons":N,"axes":[6]}`,
//!   `{"remove":ID}`
//! - host → hub: `{"added":ID,"node":"/dev/input/eventN","dev":"13:M"}`, `{"failed":ID,"error":TEXT}`,
//!   `{"rumble":ID,"strong":F,"weak":F,"ms":N}`
//!
//! The host process treats what the computer sends as untrusted: it makes at most
//! `MAX_PADS` pads, each only ever the gamepad of `uinput::Spec::gamepad`.

use super::sys;
use super::uinput;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::path::{Path, PathBuf};

/// The most pads one computer's host process makes.
pub const MAX_PADS: usize = 4;
/// The longest line either side reads; longer ones are dropped whole.
pub const LINE_MAX: usize = 1024;

/// What the hub asks of the host.
#[derive(Debug, Clone, PartialEq)]
pub enum Request {
    Add { id: u32, name: String, rumble: bool },
    State { id: u32, buttons: u32, axes: [f64; 6] },
    Remove { id: u32 },
}

/// What the host tells the hub.
#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    Added { id: u32, node: PathBuf },
    Failed { id: u32, error: String },
    Rumble { id: u32, rumble: uinput::Rumble },
}

fn id(v: &Value) -> Option<u32> {
    v.as_u64().and_then(|n| u32::try_from(n).ok()).filter(|&n| n > 0)
}

impl Request {
    pub fn parse(line: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(line).ok()?;
        if let Some(i) = v.get("add") {
            let name = v.get("name")?.as_str()?;
            let chars = name.chars().count();
            if chars == 0 || chars > 64 || name.chars().any(char::is_control) {
                return None;
            }
            return Some(Self::Add { id: id(i)?, name: name.into(), rumble: v.get("rumble")?.as_bool()? });
        }
        if let Some(i) = v.get("state") {
            let buttons = u32::try_from(v.get("buttons")?.as_u64()?).ok()?;
            let list = v.get("axes")?.as_array()?;
            if list.len() != 6 {
                return None;
            }
            let mut axes = [0.0; 6];
            for (axis, value) in axes.iter_mut().zip(list) {
                *axis = value.as_f64().filter(|f| f.is_finite())?;
            }
            return Some(Self::State { id: id(i)?, buttons, axes });
        }
        Some(Self::Remove { id: id(v.get("remove")?)? })
    }

    pub fn line(&self) -> String {
        match self {
            Self::Add { id, name, rumble } => json!({"add": id, "name": name, "rumble": rumble}),
            Self::State { id, buttons, axes } => json!({"state": id, "buttons": buttons, "axes": axes}),
            Self::Remove { id } => json!({"remove": id}),
        }
        .to_string()
            + "\n"
    }
}

/// An evdev node path the hub accepts: `/dev/input/eventN`, nothing else.
fn event_node(text: &str) -> Option<PathBuf> {
    let n = text.strip_prefix("/dev/input/event")?;
    (!n.is_empty() && n.len() <= 5 && n.bytes().all(|b| b.is_ascii_digit())).then(|| PathBuf::from(text))
}

impl Reply {
    pub fn parse(line: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(line).ok()?;
        if let Some(i) = v.get("added") {
            return Some(Self::Added { id: id(i)?, node: event_node(v.get("node")?.as_str()?)? });
        }
        if let Some(i) = v.get("failed") {
            let error: String = v.get("error")?.as_str()?.chars().filter(|c| !c.is_control()).take(200).collect();
            return Some(Self::Failed { id: id(i)?, error });
        }
        let i = id(v.get("rumble")?)?;
        let level = |key: &str| v.get(key).and_then(Value::as_f64).filter(|f| f.is_finite()).map(|f| f.clamp(0.0, 1.0));
        let ms = v.get("ms")?.as_u64()?.min(60_000) as u32;
        Some(Self::Rumble { id: i, rumble: uinput::Rumble { strong: level("strong")?, weak: level("weak")?, ms } })
    }
}

/// Splits a byte stream into lines, dropping any longer than `LINE_MAX` whole.
#[derive(Default)]
pub struct Lines {
    buf: Vec<u8>,
    skipping: bool,
}

impl Lines {
    pub fn push(&mut self, data: &[u8]) -> Vec<String> {
        let mut out = Vec::new();
        for &b in data {
            if b == b'\n' {
                if !self.skipping {
                    if let Ok(line) = std::str::from_utf8(&self.buf) {
                        out.push(line.to_owned());
                    }
                }
                self.buf.clear();
                self.skipping = false;
            } else if !self.skipping {
                self.buf.push(b);
                if self.buf.len() > LINE_MAX {
                    self.buf.clear();
                    self.skipping = true;
                }
            }
        }
        out
    }
}

// ---- the host's side ----

/// `13:M`, the device numbers of a pad's evdev node, from sysfs.
fn device_numbers(node: &Path) -> io::Result<String> {
    let name = node.file_name().and_then(|n| n.to_str()).ok_or(io::ErrorKind::NotFound)?;
    Ok(std::fs::read_to_string(Path::new("/sys/class/input").join(name).join("dev"))?.trim().to_owned())
}

/// The host's pads for one computer: makes and feeds them as the hub asks and answers with
/// lines for it. Every pad goes when this is dropped.
#[derive(Default)]
pub struct Pads {
    pads: Vec<(u32, uinput::Device)>,
}

impl Pads {
    pub fn request(&mut self, request: Request) -> Option<Reply> {
        match request {
            Request::Add { id, name, rumble } => {
                if self.pads.iter().any(|(p, _)| *p == id) {
                    return None;
                }
                if self.pads.len() >= MAX_PADS {
                    return Some(Reply::Failed { id, error: format!("This computer already has {MAX_PADS} game controllers") });
                }
                match self.make(&name, rumble) {
                    Ok((device, node)) => {
                        self.pads.push((id, device));
                        Some(Reply::Added { id, node })
                    }
                    Err(error) => Some(Reply::Failed { id, error }),
                }
            }
            Request::State { id, buttons, axes } => {
                if let Some((_, d)) = self.pads.iter().find(|(p, _)| *p == id) {
                    let _ = d.emit(&uinput::gamepad_events(buttons, &axes));
                }
                None
            }
            Request::Remove { id } => {
                self.pads.retain(|(p, _)| *p != id);
                None
            }
        }
    }

    fn make(&self, name: &str, rumble: bool) -> Result<(uinput::Device, PathBuf), String> {
        let mut device = uinput::Device::create(&uinput::Spec::gamepad(name, rumble)).map_err(|e| match e.raw_os_error() {
            Some(libc::ENOENT) | Some(libc::ENODEV) => format!("The host's kernel has no uinput ({})", uinput::UINPUT),
            Some(libc::EACCES) | Some(libc::EPERM) => format!("The host gives its game controller service no {}", uinput::UINPUT),
            _ => format!("{}: {e}", uinput::UINPUT),
        })?;
        // The kernel adds the evdev handler as it registers the device.
        let mut node = device.node();
        for _ in 0..20 {
            if node.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            node = device.node();
        }
        let node = node.ok_or("The host's kernel has no evdev (modprobe evdev)")?;
        let numbers = device_numbers(&node).map_err(|e| format!("{}: {e}", node.display()))?;
        if !numbers.starts_with("13:") {
            return Err(format!("{} is not an input device ({numbers})", node.display()));
        }
        Ok((device, node))
    }

    fn reply_line(reply: &Reply) -> String {
        match reply {
            Reply::Added { id, node } => {
                let dev = device_numbers(node).unwrap_or_default();
                json!({"added": id, "node": node.display().to_string(), "dev": dev})
            }
            Reply::Failed { id, error } => json!({"failed": id, "error": error}),
            Reply::Rumble { id, rumble } => json!({"rumble": id, "strong": rumble.strong, "weak": rumble.weak, "ms": rumble.ms}),
        }
        .to_string()
            + "\n"
    }
}

/// `caboose-display --host-pads`: the host's pads for one computer, asked for on standard
/// input, answered on standard output. Ends when its input does, taking every pad down.
pub fn serve() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    let mut pads = Pads::default();
    let mut lines = Lines::default();
    let mut buf = [0u8; 4096];
    loop {
        let mut fds = vec![libc::pollfd { fd: stdin.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
        fds.extend(pads.pads.iter().map(|(_, d)| libc::pollfd { fd: d.raw_fd(), events: libc::POLLIN, revents: 0 }));
        // SAFETY: `fds` is a valid array of pollfd for its length.
        if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) } < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        let mut out = String::new();
        for (i, pfd) in fds.iter().enumerate().skip(1) {
            if pfd.revents == 0 {
                continue;
            }
            let (id, device) = &mut pads.pads[i - 1];
            if let Ok(Some(rumble)) = device.service() {
                out.push_str(&Pads::reply_line(&Reply::Rumble { id: *id, rumble }));
            }
        }
        if fds[0].revents != 0 {
            // SAFETY: standard input stays open for the process's life.
            let fd = unsafe { BorrowedFd::borrow_raw(stdin.as_raw_fd()) };
            let n = match sys::read_some(&fd, &mut buf) {
                Ok(Some(0)) => return Ok(()),
                Ok(Some(n)) => n,
                Ok(None) => 0,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            for line in lines.push(&buf[..n]) {
                if let Some(reply) = Request::parse(&line).and_then(|r| pads.request(r)) {
                    out.push_str(&Pads::reply_line(&reply));
                }
            }
        }
        if !out.is_empty() {
            stdout.write_all(out.as_bytes())?;
            stdout.flush()?;
        }
    }
}

// ---- the computer's side ----

/// `caboose-display --pad-link`: joins the hub's socket to standard input and output for the
/// host, until either side ends.
pub fn link(socket: &Path) -> io::Result<()> {
    let stream = std::os::unix::net::UnixStream::connect(socket)?;
    let mut to_hub = stream.try_clone()?;
    std::thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut to_hub);
        let _ = to_hub.shutdown(std::net::Shutdown::Write);
    });
    let mut from_hub = stream;
    let mut stdout = io::stdout().lock();
    let mut buf = [0u8; 4096];
    loop {
        let n = from_hub.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        stdout.write_all(&buf[..n])?;
        stdout.flush()?;
    }
}

/// The hub's socket for the host's link, in the owner's runtime directory.
pub fn socket_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join("caboose-pads.sock")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_round_trip() {
        for r in [
            Request::Add { id: 3, name: "iPhone Controller".into(), rumble: true },
            Request::State { id: 3, buttons: 0x11, axes: [0.5, -1.0, 0.0, 0.25, 1.0, 0.0] },
            Request::Remove { id: 3 },
        ] {
            let line = r.line();
            assert!(line.ends_with('\n'));
            assert_eq!(Request::parse(line.trim_end()), Some(r));
        }
    }

    #[test]
    fn requests_outside_the_contract_are_refused() {
        assert_eq!(Request::parse(r#"{"add":0,"name":"Pad","rumble":false}"#), None, "id 0");
        assert_eq!(Request::parse(r#"{"add":1,"name":"","rumble":false}"#), None);
        assert_eq!(Request::parse(r#"{"add":1,"name":"a\nb","rumble":false}"#), None);
        assert_eq!(Request::parse(&format!(r#"{{"add":1,"name":"{}","rumble":false}}"#, "x".repeat(65))), None);
        assert_eq!(Request::parse(r#"{"add":4294967296,"name":"Pad","rumble":false}"#), None);
        assert_eq!(Request::parse(r#"{"state":1,"buttons":1,"axes":[0,0,0,0,0]}"#), None, "five axes");
        assert_eq!(Request::parse(r#"{"state":1,"buttons":-1,"axes":[0,0,0,0,0,0]}"#), None);
        assert_eq!(Request::parse(r#"{"state":1,"buttons":1,"axes":[0,0,0,0,0,"x"]}"#), None);
        assert_eq!(Request::parse(r#"{"mknod":"/dev/uinput"}"#), None);
        assert_eq!(Request::parse("not json"), None);
    }

    #[test]
    fn replies_name_only_evdev_nodes() {
        assert_eq!(
            Reply::parse(r#"{"added":2,"node":"/dev/input/event17","dev":"13:81"}"#),
            Some(Reply::Added { id: 2, node: "/dev/input/event17".into() })
        );
        assert_eq!(Reply::parse(r#"{"added":2,"node":"/dev/uinput"}"#), None);
        assert_eq!(Reply::parse(r#"{"added":2,"node":"/dev/input/event1/../../uinput"}"#), None);
        assert_eq!(Reply::parse(r#"{"added":2,"node":"/dev/input/event"}"#), None);
        assert_eq!(
            Reply::parse(r#"{"rumble":2,"strong":2.0,"weak":-1,"ms":999999}"#),
            Some(Reply::Rumble { id: 2, rumble: uinput::Rumble { strong: 1.0, weak: 0.0, ms: 60_000 } })
        );
        assert_eq!(
            Reply::parse(r#"{"failed":2,"error":"no\nuinput"}"#),
            Some(Reply::Failed { id: 2, error: "nouinput".into() })
        );
    }

    #[test]
    fn host_replies_parse_on_the_computer() {
        let line = Pads::reply_line(&Reply::Rumble { id: 1, rumble: uinput::Rumble { strong: 0.5, weak: 0.25, ms: 100 } });
        assert_eq!(
            Reply::parse(line.trim_end()),
            Some(Reply::Rumble { id: 1, rumble: uinput::Rumble { strong: 0.5, weak: 0.25, ms: 100 } })
        );
        let line = Pads::reply_line(&Reply::Failed { id: 1, error: "no uinput".into() });
        assert_eq!(Reply::parse(line.trim_end()), Some(Reply::Failed { id: 1, error: "no uinput".into() }));
    }

    #[test]
    fn lines_split_and_drop_overlong_ones() {
        let mut lines = Lines::default();
        assert_eq!(lines.push(b"{\"remove\":1}\n{\"rem"), vec!["{\"remove\":1}"]);
        assert_eq!(lines.push(b"ove\":2}\n"), vec!["{\"remove\":2}"]);
        let long = vec![b'x'; LINE_MAX + 1];
        assert!(lines.push(&long).is_empty());
        assert!(lines.push(b"yyy\n").is_empty(), "the rest of the overlong line is dropped too");
        assert_eq!(lines.push(b"ok\n"), vec!["ok"]);
    }

    #[test]
    fn requests_for_unknown_pads_are_ignored() {
        let mut pads = Pads::default();
        assert_eq!(pads.request(Request::State { id: 9, buttons: 1, axes: [0.0; 6] }), None);
        assert_eq!(pads.request(Request::Remove { id: 9 }), None);
    }
}
