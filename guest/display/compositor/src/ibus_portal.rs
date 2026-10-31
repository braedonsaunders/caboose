//! The input-method service (ibus.rs) for sandboxed applications. Flatpak's IBus clients
//! do not open an IBus address: they call `org.freedesktop.portal.IBus` on the session
//! bus, which the sandbox lets them reach, and own the input contexts it makes for them.
//! The compositor takes that name on the seat's session bus. A sandboxed process's ID is
//! not visible through the bus, so a context belongs to the window that had keyboard focus
//! when its field gained focus, which is the window the toolkit focused it for.
use crate::dbus::{self, Message, Value};
use crate::ibus::{context_method, input_signals, Context, Field, Outcome, CONTEXT_INTERFACE, CONTEXT_PATH, MAX_CONTEXTS, MAX_QUEUED};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const NAME: &str = "org.freedesktop.portal.IBus";
const INTERFACE: &str = "org.freedesktop.IBus.Portal";
const BUS: &str = "org.freedesktop.DBus";
/// RequestName: fail rather than queue behind another owner (an IBus daemon's portal).
const DO_NOT_QUEUE: u32 = 4;
const PRIMARY_OWNER: u32 = 1;

struct Owned {
    /// The client's unique name on the bus.
    sender: String,
    context: Context,
    /// The window with keyboard focus when the field last gained focus.
    surface: Option<WlSurface>,
    /// The focus that `surface` is for.
    bound: u64,
}

pub struct Portal {
    stream: UnixStream,
    input: Vec<u8>,
    output: Vec<u8>,
    serial: u32,
    contexts: BTreeMap<u32, Owned>,
}

/// The socket path of a `unix:path=` D-Bus address, percent-escapes decoded.
pub fn socket_path(address: &str) -> Option<PathBuf> {
    address.split(';').find_map(|entry| {
        let options = entry.strip_prefix("unix:")?;
        let raw = options.split(',').find_map(|kv| kv.strip_prefix("path="))?;
        let bytes = raw.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' {
                out.push(u8::from_str_radix(raw.get(i + 1..i + 3)?, 16).ok()?);
                i += 3;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        Some(PathBuf::from(String::from_utf8(out).ok()?))
    })
}

impl Portal {
    /// Joins the session bus at `address` and takes the portal's name; None when the name
    /// has another owner. Blocks for at most a few seconds: the bus is local.
    pub fn connect(address: &str) -> io::Result<Option<Self>> {
        let path = socket_path(address).ok_or_else(|| io::Error::other("not a unix:path= address"))?;
        let at = |stage: &'static str| move |e: io::Error| io::Error::new(e.kind(), format!("{stage}: {e}"));
        let stream = UnixStream::connect(path).map_err(at("connecting"))?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        // SAFETY: getuid cannot fail.
        let uid: String = unsafe { libc::getuid() }.to_string().bytes().map(|b| format!("{b:02x}")).collect();
        (&stream).write_all(format!("\0AUTH EXTERNAL {uid}\r\n").as_bytes()).map_err(at("authenticating"))?;
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut line = String::new();
        reader.read_line(&mut line).map_err(at("awaiting authentication"))?;
        if !line.starts_with("OK ") {
            return Err(io::Error::other(format!("session bus refused authentication: {}", line.trim())));
        }
        if !reader.buffer().is_empty() {
            return Err(io::Error::other("session bus sent data before BEGIN"));
        }
        (&stream).write_all(b"BEGIN\r\n")?;
        let mut portal = Self { stream, input: Vec::new(), output: Vec::new(), serial: 0, contexts: BTreeMap::new() };
        let hello = portal.bus_call("Hello", vec![]);
        let request = portal.bus_call("RequestName", vec![Value::Str(NAME.into()), Value::U32(DO_NOT_QUEUE)]);
        portal.bus_call(
            "AddMatch",
            vec![Value::Str(format!("type='signal',sender='{BUS}',interface='{BUS}',member='NameOwnerChanged'"))],
        );
        let requests = std::mem::take(&mut portal.output);
        (&portal.stream).write_all(&requests).map_err(at("asking for the name"))?;
        let (mut said_hello, mut owner) = (false, None);
        while !said_hello || owner.is_none() {
            let message = portal.next_blocking().map_err(at("awaiting the bus's replies"))?;
            match message.reply_serial {
                Some(s) if s == hello => said_hello = true,
                Some(s) if s == request => owner = Some(message.body.first().and_then(Value::as_u32) == Some(PRIMARY_OWNER)),
                _ => {}
            }
        }
        if owner != Some(true) {
            return Ok(None);
        }
        portal.stream.set_read_timeout(None)?;
        portal.stream.set_nonblocking(true)?;
        Ok(Some(portal))
    }

    pub fn stream(&self) -> io::Result<UnixStream> {
        self.stream.try_clone()
    }

    fn bus_call(&mut self, member: &str, body: Vec<Value>) -> u32 {
        self.send(Message {
            kind: dbus::METHOD_CALL,
            path: Some("/org/freedesktop/DBus".into()),
            interface: Some(BUS.into()),
            member: Some(member.into()),
            destination: Some(BUS.into()),
            body,
            ..Default::default()
        })
    }

    fn send(&mut self, mut message: Message) -> u32 {
        self.serial = self.serial.wrapping_add(1).max(1);
        message.serial = self.serial;
        self.output.extend_from_slice(&message.encode());
        self.serial
    }

    fn next_blocking(&mut self) -> io::Result<Message> {
        loop {
            if let Some(message) = self.take_message().map_err(io::Error::other)? {
                return Ok(message);
            }
            let mut buf = [0u8; 4096];
            let n = self.stream.read(&mut buf)?;
            if n == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            self.input.extend_from_slice(&buf[..n]);
        }
    }

    fn take_message(&mut self) -> Result<Option<Message>, String> {
        match Message::length(&self.input)? {
            Some(n) if n <= self.input.len() => {
                let raw: Vec<u8> = self.input.drain(..n).collect();
                Message::decode(&raw).map(Some)
            }
            _ => Ok(None),
        }
    }

    /// Writes what is queued; the bus reads promptly.
    pub fn flush(&mut self) -> io::Result<()> {
        if self.output.is_empty() {
            return Ok(());
        }
        let output = std::mem::take(&mut self.output);
        let _ = self.stream.set_nonblocking(false);
        let written = self.stream.write_all(&output);
        let _ = self.stream.set_nonblocking(true);
        written
    }

    /// Reads and answers what the bus delivered; false once the bus is gone.
    pub fn readable(&mut self, next_context: &mut u32, focus_clock: &mut u64) -> bool {
        let mut buf = [0u8; 16 * 1024];
        loop {
            match self.stream.read(&mut buf) {
                Ok(0) => return false,
                Ok(n) => self.input.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return false,
            }
        }
        loop {
            match self.take_message() {
                Ok(Some(message)) => self.handle(&message, next_context, focus_clock),
                Ok(None) => break,
                Err(_) => return false,
            }
            if self.output.len() > MAX_QUEUED {
                return false;
            }
        }
        self.flush().is_ok()
    }

    fn handle(&mut self, m: &Message, next_context: &mut u32, focus_clock: &mut u64) {
        let member = m.member.as_deref().unwrap_or_default();
        if m.kind == dbus::SIGNAL && member == "NameOwnerChanged" {
            // A client left the bus: its contexts go with it.
            if let (Some(Value::Str(name)), Some(Value::Str(new))) = (m.body.first(), m.body.get(2)) {
                if new.is_empty() && name.starts_with(':') {
                    self.contexts.retain(|_, c| c.sender != *name);
                }
            }
            return;
        }
        if m.kind != dbus::METHOD_CALL {
            return;
        }
        let Some(sender) = m.sender.clone() else { return };
        let interface = m.interface.as_deref().unwrap_or_default();
        let path = m.path.as_deref().unwrap_or_default();
        match (interface, member) {
            (INTERFACE, "CreateInputContext") if path == "/org/freedesktop/IBus" => {
                if self.contexts.values().filter(|c| c.sender == sender).count() >= MAX_CONTEXTS {
                    return self.error(m, "org.freedesktop.DBus.Error.LimitsExceeded", "too many input contexts");
                }
                *next_context = next_context.wrapping_add(1).max(1);
                self.contexts.insert(*next_context, Owned { sender, context: Context::default(), surface: None, bound: 0 });
                self.reply(m, vec![Value::Path(format!("{CONTEXT_PATH}{next_context}"))]);
            }
            ("org.freedesktop.DBus.Peer", "Ping") => self.reply(m, vec![]),
            _ => {
                let id = path.strip_prefix(CONTEXT_PATH).and_then(|n| n.parse::<u32>().ok());
                let Some((id, owned)) = id.and_then(|id| self.contexts.get_mut(&id).map(|o| (id, o))) else {
                    return self.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
                };
                if owned.sender != sender {
                    return self.error(m, "org.freedesktop.DBus.Error.AccessDenied", "not this client's input context");
                }
                match context_method(&mut owned.context, m, focus_clock) {
                    Outcome::Reply(body) => self.reply(m, body),
                    Outcome::Destroyed => {
                        self.contexts.remove(&id);
                        self.reply(m, vec![]);
                    }
                    Outcome::Unknown => self.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method"),
                }
            }
        }
    }

    fn reply(&mut self, call: &Message, body: Vec<Value>) {
        if call.flags & dbus::NO_REPLY_EXPECTED != 0 {
            return;
        }
        self.send(Message {
            kind: dbus::METHOD_RETURN,
            reply_serial: Some(call.serial),
            destination: call.sender.clone(),
            body,
            ..Default::default()
        });
    }

    fn error(&mut self, call: &Message, name: &str, text: &str) {
        if call.flags & dbus::NO_REPLY_EXPECTED != 0 {
            return;
        }
        self.send(Message {
            kind: dbus::ERROR,
            reply_serial: Some(call.serial),
            error_name: Some(name.into()),
            destination: call.sender.clone(),
            body: vec![Value::Str(text.into())],
            ..Default::default()
        });
    }

    /// Gives contexts that gained focus since they were last placed the window that has
    /// keyboard focus now.
    pub fn bind(&mut self, focus: Option<&WlSurface>) {
        for owned in self.contexts.values_mut() {
            if owned.context.focused && owned.context.focus_order > owned.bound {
                owned.surface = focus.cloned();
                owned.bound = owned.context.focus_order;
            }
        }
    }

    fn focused_context(&self, surface: &WlSurface) -> Option<(u64, u32, Field)> {
        self.contexts
            .iter()
            .filter(|(_, o)| o.context.focused && o.surface.as_ref() == Some(surface))
            .max_by_key(|(_, o)| o.context.focus_order)
            .and_then(|(id, o)| o.context.field().map(|f| (o.context.focus_order, *id, f)))
    }

    /// When `surface`'s field gained focus, and the field.
    pub fn focused(&self, surface: &WlSurface) -> Option<(u64, Field)> {
        self.focused_context(surface).map(|(order, _, f)| (order, f))
    }

    /// Sends the phone keyboard's change to `surface`'s field.
    pub fn send_input(&mut self, surface: &WlSurface, commit: Option<&str>, preedit: Option<(&str, i32)>) -> bool {
        let Some((_, id, _)) = self.focused_context(surface) else { return false };
        let owned = self.contexts.get_mut(&id).unwrap();
        let sender = owned.sender.clone();
        for (member, body) in input_signals(&mut owned.context, commit, preedit) {
            self.send(Message {
                kind: dbus::SIGNAL,
                path: Some(format!("{CONTEXT_PATH}{id}")),
                interface: Some(CONTEXT_INTERFACE.into()),
                member: Some(member.into()),
                destination: Some(sender.clone()),
                body,
                ..Default::default()
            });
        }
        let _ = self.flush();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_bus_addresses_name_their_socket() {
        assert_eq!(socket_path("unix:path=/run/user/1000/bus"), Some("/run/user/1000/bus".into()));
        assert_eq!(socket_path("unix:abstract=x;unix:guid=1,path=/tmp/a%20b"), Some("/tmp/a b".into()));
        assert_eq!(socket_path("tcp:host=localhost,port=1"), None);
        assert_eq!(socket_path("unix:path=/tmp/%2"), None);
    }

    fn portal_pair() -> (Portal, UnixStream) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        ours.set_nonblocking(true).unwrap();
        (Portal { stream: ours, input: Vec::new(), output: Vec::new(), serial: 0, contexts: BTreeMap::new() }, theirs)
    }

    fn call(serial: u32, sender: &str, path: &str, interface: &str, member: &str, body: Vec<Value>) -> Message {
        Message {
            kind: dbus::METHOD_CALL,
            serial,
            path: Some(path.into()),
            interface: Some(interface.into()),
            member: Some(member.into()),
            sender: Some(sender.into()),
            body,
            ..Default::default()
        }
    }

    #[test]
    fn contexts_belong_to_their_client_and_to_the_window_focused_with_them() {
        let (mut portal, _bus) = portal_pair();
        let (mut next, mut clock) = (0, 0);
        portal.handle(&call(1, ":1.9", "/org/freedesktop/IBus", INTERFACE, "CreateInputContext", vec![Value::Str("gtk".into())]), &mut next, &mut clock);
        let path = format!("{CONTEXT_PATH}{next}");
        let replies = std::mem::take(&mut portal.output);
        let reply = Message::decode(&replies).unwrap();
        assert_eq!(reply.destination.as_deref(), Some(":1.9"));
        assert_eq!(reply.body, [Value::Path(path.clone())]);
        // Another client may not drive it.
        portal.handle(&call(2, ":1.10", &path, CONTEXT_INTERFACE, "FocusIn", vec![]), &mut next, &mut clock);
        assert_eq!(Message::decode(&std::mem::take(&mut portal.output)).unwrap().kind, dbus::ERROR);
        portal.handle(&call(3, ":1.9", &path, CONTEXT_INTERFACE, "FocusIn", vec![]), &mut next, &mut clock);
        portal.output.clear();
        assert!(portal.contexts.values().all(|o| o.surface.is_none()), "placed only by bind");
        // The client leaving the bus takes its contexts.
        let gone = Message {
            kind: dbus::SIGNAL,
            serial: 4,
            member: Some("NameOwnerChanged".into()),
            interface: Some(BUS.into()),
            body: vec![Value::Str(":1.9".into()), Value::Str(":1.9".into()), Value::Str(String::new())],
            ..Default::default()
        };
        portal.handle(&gone, &mut next, &mut clock);
        assert!(portal.contexts.is_empty());
    }
}
