//! An input-method service speaking IBus's D-Bus protocol, for the applications that have
//! no text-input-v3: X11 clients through Xwayland (Chromium and Electron on X11, GTK on
//! X11 through the `ibus` module the window manager's XSETTINGS select, Qt through
//! `QT_IM_MODULE`, SDL).
//! Their toolkit tells an IBus input context when an editable field gains and loses focus
//! and what it holds (its purpose, the text around the caret); Caboose's input method is
//! the phone's keyboard, so focus shows it and the keyboard's commits and pre-edit text go
//! back as IBus `CommitText` and `UpdatePreeditText`.
//!
//! The listening socket is the instance's own (`$IBUS_ADDRESS` in the launch environment),
//! peers must be the compositor's user, and the service answers as the message bus and as
//! `org.freedesktop.IBus` on each connection, so no IBus daemon is involved. Contexts belong
//! to the connection's process, which is how a field's focus is matched to the window that
//! has keyboard focus.
use crate::dbus::{self, Auth, AuthStep, Message, Value};
use crate::state::State;
use crate::text_input::Surrounding;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::calloop::{generic::Generic, Interest, LoopHandle, Mode, PostAction};
use std::collections::{BTreeMap, HashMap};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// The unique name the service answers as, the owner of `org.freedesktop.IBus`.
const OWNER: &str = ":1.0";
const IBUS: &str = "org.freedesktop.IBus";
const BUS: &str = "org.freedesktop.DBus";
const CONTEXT_INTERFACE: &str = "org.freedesktop.IBus.InputContext";
const CONTEXT_PATH: &str = "/org/freedesktop/IBus/InputContext_";
/// Contexts per connection; a toolkit makes one or two per window.
const MAX_CONTEXTS: usize = 256;
/// Bytes queued for a client that does not read; beyond it the connection ends.
const MAX_QUEUED: usize = 1 << 20;

/// IBus content hints (the same values as GTK's input hints) the service acts on.
const HINT_INHIBIT_OSK: u32 = 1 << 7;
const HINT_PRIVATE: u32 = 1 << 11;

/// IBus content purposes (GTK's `GtkInputPurpose`) by the names the display protocol uses.
fn purpose_name(purpose: u32) -> &'static str {
    match purpose {
        1 => "alpha",
        2 => "digits",
        3 => "number",
        4 => "phone",
        5 => "url",
        6 => "email",
        7 => "name",
        8 => "password",
        9 => "pin",
        10 => "terminal",
        _ => "normal",
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Context {
    focused: bool,
    purpose: u32,
    hints: u32,
    /// The text around the caret, with the caret and anchor as character offsets.
    surrounding: Option<(String, u32, u32)>,
    /// When it last gained focus: the most recent focused context of a process wins.
    focus_order: u64,
    /// Pre-edit text is showing in the field.
    preedit: bool,
}

/// An editable field with focus, as the phone's keyboard needs it.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub purpose: &'static str,
    /// Its text, unless the field is sensitive (a password, a PIN, or marked private).
    pub surrounding: Option<Surrounding>,
}

impl Context {
    fn field(&self) -> Option<Field> {
        if !self.focused || self.hints & HINT_INHIBIT_OSK != 0 {
            return None;
        }
        let sensitive = matches!(self.purpose, 8 | 9) || self.hints & HINT_PRIVATE != 0;
        let surrounding = self
            .surrounding
            .as_ref()
            .filter(|_| !sensitive)
            .and_then(|(text, cursor, anchor)| {
                let byte = |chars: u32| text.char_indices().map(|(i, _)| i).chain([text.len()]).nth(chars as usize);
                Surrounding::new(text.clone(), byte(*cursor)? as i32, byte(*anchor)? as i32)
            });
        Some(Field { purpose: purpose_name(self.purpose), surrounding })
    }
}

/// One client connection: the D-Bus handshake, then messages.
pub struct Connection {
    pid: u32,
    uid: u32,
    auth: Auth,
    input: Vec<u8>,
    output: Vec<u8>,
    serial: u32,
    unique: String,
    contexts: BTreeMap<u32, Context>,
}

impl Connection {
    pub fn new(pid: u32, uid: u32, guid: String, unique: String) -> Self {
        Self {
            pid,
            uid,
            auth: Auth::new(guid),
            input: Vec::new(),
            output: Vec::new(),
            serial: 0,
            unique,
            contexts: BTreeMap::new(),
        }
    }

    /// Takes bytes from the client; replies and signals go to `output`. False when the
    /// connection must end. `next_context` numbers contexts across connections, and
    /// `focus_clock` orders their focus.
    pub fn receive(&mut self, bytes: &[u8], next_context: &mut u32, focus_clock: &mut u64) -> bool {
        let mut bytes = bytes;
        if !self.auth.done {
            match self.auth.feed(bytes, self.uid) {
                AuthStep::Continue(reply) => {
                    self.output.extend_from_slice(&reply);
                    return true;
                }
                AuthStep::Begin(reply, used) => {
                    self.output.extend_from_slice(&reply);
                    bytes = &bytes[used..];
                }
                AuthStep::Fail => return false,
            }
        }
        self.input.extend_from_slice(bytes);
        loop {
            let length = match Message::length(&self.input) {
                Ok(Some(n)) if n <= self.input.len() => n,
                Ok(_) => return true,
                Err(_) => return false,
            };
            let raw: Vec<u8> = self.input.drain(..length).collect();
            let Ok(message) = Message::decode(&raw) else { return false };
            if message.kind == dbus::METHOD_CALL {
                self.call(&message, next_context, focus_clock);
            }
            if self.output.len() > MAX_QUEUED {
                return false;
            }
        }
    }

    fn send(&mut self, mut message: Message) {
        self.serial = self.serial.wrapping_add(1).max(1);
        message.serial = self.serial;
        message.destination = Some(self.unique.clone());
        self.output.extend_from_slice(&message.encode());
    }

    fn reply(&mut self, call: &Message, sender: &str, body: Vec<Value>) {
        if call.flags & dbus::NO_REPLY_EXPECTED != 0 {
            return;
        }
        self.send(Message {
            kind: dbus::METHOD_RETURN,
            reply_serial: Some(call.serial),
            sender: Some(sender.into()),
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
            sender: Some(OWNER.into()),
            body: vec![Value::Str(text.into())],
            ..Default::default()
        });
    }

    fn call(&mut self, m: &Message, next_context: &mut u32, focus_clock: &mut u64) {
        let interface = m.interface.as_deref().unwrap_or_default();
        let member = m.member.as_deref().unwrap_or_default();
        let path = m.path.as_deref().unwrap_or_default();
        tracing::trace!("input method: pid {} {path} {interface}.{member}", self.pid);
        let arg = |i: usize| m.body.get(i);
        match (interface, member) {
            (BUS, "Hello") => {
                let unique = self.unique.clone();
                self.reply(m, BUS, vec![Value::Str(unique)])
            }
            (BUS, "AddMatch" | "RemoveMatch") => self.reply(m, BUS, vec![]),
            (BUS, "GetNameOwner") => match arg(0).and_then(Value::as_str) {
                Some(IBUS) => self.reply(m, BUS, vec![Value::Str(OWNER.into())]),
                Some(BUS) => self.reply(m, BUS, vec![Value::Str(BUS.into())]),
                Some(name) if name == self.unique => {
                    let unique = self.unique.clone();
                    self.reply(m, BUS, vec![Value::Str(unique)])
                }
                _ => self.error(m, "org.freedesktop.DBus.Error.NameHasNoOwner", "no such name"),
            },
            (BUS, "NameHasOwner") => {
                let has = matches!(arg(0).and_then(Value::as_str), Some(IBUS | BUS));
                self.reply(m, BUS, vec![Value::Bool(has)])
            }
            (BUS, "GetConnectionUnixProcessID") => {
                let pid = self.pid;
                self.reply(m, BUS, vec![Value::U32(pid)])
            }
            ("org.freedesktop.DBus.Peer", "Ping") => self.reply(m, OWNER, vec![]),
            (IBUS, "CreateInputContext") if path == "/org/freedesktop/IBus" => {
                if self.contexts.len() >= MAX_CONTEXTS {
                    return self.error(m, "org.freedesktop.DBus.Error.LimitsExceeded", "too many input contexts");
                }
                *next_context = next_context.wrapping_add(1).max(1);
                self.contexts.insert(*next_context, Context::default());
                self.reply(m, OWNER, vec![Value::Path(format!("{CONTEXT_PATH}{next_context}"))])
            }
            _ => match path.strip_prefix(CONTEXT_PATH).and_then(|n| n.parse::<u32>().ok()) {
                Some(id) if self.contexts.contains_key(&id) => self.context_call(id, m, focus_clock),
                _ => self.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method"),
            },
        }
    }

    fn context_call(&mut self, id: u32, m: &Message, focus_clock: &mut u64) {
        let interface = m.interface.as_deref().unwrap_or_default();
        let member = m.member.as_deref().unwrap_or_default();
        let ctx = self.contexts.get_mut(&id).unwrap();
        match (interface, member) {
            (CONTEXT_INTERFACE, "FocusIn") => {
                *focus_clock += 1;
                ctx.focused = true;
                ctx.focus_order = *focus_clock;
            }
            (CONTEXT_INTERFACE, "FocusOut") => ctx.focused = false,
            (CONTEXT_INTERFACE, "SetContentType") => {
                if let (Some(purpose), Some(hints)) =
                    (m.body.first().and_then(Value::as_u32), m.body.get(1).and_then(Value::as_u32))
                {
                    (ctx.purpose, ctx.hints) = (purpose, hints);
                }
            }
            (CONTEXT_INTERFACE, "SetSurroundingText") => {
                ctx.surrounding = match (m.body.first().and_then(ibus_text), m.body.get(1), m.body.get(2)) {
                    (Some(text), Some(Value::U32(cursor)), Some(Value::U32(anchor))) => Some((text, *cursor, *anchor)),
                    _ => None,
                };
            }
            (CONTEXT_INTERFACE, "ProcessKeyEvent") => {
                // Keys are the application's: the phone's keyboard composes before it sends.
                return self.reply(m, OWNER, vec![Value::Bool(false)]);
            }
            (CONTEXT_INTERFACE, "Destroy") => {
                self.contexts.remove(&id);
            }
            (CONTEXT_INTERFACE, "Reset" | "SetCapabilities" | "SetCursorLocation" | "SetCursorLocationRelative")
            | (CONTEXT_INTERFACE, "PropertyActivate" | "SetEngine" | "ProcessHandWritingEvent" | "CancelHandWriting") => {}
            ("org.freedesktop.DBus.Properties", "Set") => {
                let name = m.body.get(1).and_then(Value::as_str);
                let value = match m.body.get(2) {
                    Some(Value::Variant(v)) => Some(&**v),
                    _ => None,
                };
                if let (Some("ContentType"), Some(Value::Struct(fields))) = (name, value) {
                    if let (Some(purpose), Some(hints)) =
                        (fields.first().and_then(Value::as_u32), fields.get(1).and_then(Value::as_u32))
                    {
                        (ctx.purpose, ctx.hints) = (purpose, hints);
                    }
                }
            }
            ("org.freedesktop.DBus.Properties", "GetAll") => {
                return self.reply(m, OWNER, vec![Value::Array("{sv}".into(), vec![])]);
            }
            _ => return self.error(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method"),
        }
        self.reply(m, OWNER, vec![]);
    }

    /// The process's most recently focused context with focus, as a field.
    fn focused(&self) -> Option<(u64, u32, Field)> {
        self.contexts
            .iter()
            .filter(|(_, c)| c.focused)
            .max_by_key(|(_, c)| c.focus_order)
            .and_then(|(id, c)| c.field().map(|f| (c.focus_order, *id, f)))
    }

    fn signal(&mut self, context: u32, member: &str, body: Vec<Value>) {
        self.send(Message {
            kind: dbus::SIGNAL,
            path: Some(format!("{CONTEXT_PATH}{context}")),
            interface: Some(CONTEXT_INTERFACE.into()),
            member: Some(member.into()),
            sender: Some(OWNER.into()),
            body,
            ..Default::default()
        });
    }

    /// One change from the phone's keyboard to context `ctx`: its pre-edit text replaced
    /// (hidden when absent or empty; the caret a byte offset into it), then a commit.
    fn input(&mut self, ctx: u32, commit: Option<&str>, preedit: Option<(&str, i32)>) {
        let Some(context) = self.contexts.get_mut(&ctx) else { return };
        let showing = context.preedit;
        context.preedit = preedit.is_some_and(|(text, _)| !text.is_empty());
        match preedit.filter(|(text, _)| !text.is_empty()) {
            Some((text, caret)) => {
                let caret = text.get(..caret.max(0) as usize).map_or(text.chars().count(), |s| s.chars().count());
                self.signal(ctx, "UpdatePreeditText", vec![text_value(text), Value::U32(caret as u32), Value::Bool(true)]);
            }
            None if showing => self.signal(ctx, "HidePreeditText", vec![]),
            None => {}
        }
        if let Some(text) = commit {
            self.signal(ctx, "CommitText", vec![text_value(text)]);
        }
    }

    pub fn take_output(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.output)
    }
}

/// IBus's serialized text: `("IBusText", {}, text, <("IBusAttrList", {}, [])>)`.
fn text_value(text: &str) -> Value {
    let attributes =
        Value::Struct(vec![Value::Str("IBusAttrList".into()), Value::Array("{sv}".into(), vec![]), Value::Array("v".into(), vec![])]);
    Value::Variant(Box::new(Value::Struct(vec![
        Value::Str("IBusText".into()),
        Value::Array("{sv}".into(), vec![]),
        Value::Str(text.into()),
        Value::Variant(Box::new(attributes)),
    ])))
}

fn ibus_text(value: &Value) -> Option<String> {
    let Value::Variant(inner) = value else { return None };
    let Value::Struct(fields) = &**inner else { return None };
    match (fields.first(), fields.get(2)) {
        (Some(Value::Str(kind)), Some(Value::Str(text))) if kind == "IBusText" => Some(text.clone()),
        _ => None,
    }
}

/// The service: the listening socket and its connections.
pub struct Ibus {
    path: PathBuf,
    guid: String,
    connections: HashMap<u64, (UnixStream, Connection)>,
    next_connection: u64,
    next_context: u32,
    focus_clock: u64,
}

fn peer(stream: &UnixStream) -> Option<(u32, u32)> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `cred`.
    let r = unsafe {
        libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&mut cred as *mut libc::ucred).cast(), &mut len)
    };
    (r == 0).then_some((cred.pid as u32, cred.uid))
}

impl Ibus {
    pub fn listen(path: &Path, handle: &LoopHandle<'static, State>) -> io::Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        handle
            .insert_source(Generic::new(listener, Interest::READ, Mode::Level), |_, listener, state: &mut State| {
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => state.accept_ibus(stream),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("input method socket accept: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        let mut guid = [0u8; 16];
        // SAFETY: getrandom writes at most 16 bytes into `guid`.
        let filled = unsafe { libc::getrandom(guid.as_mut_ptr().cast(), guid.len(), 0) };
        if filled != 16 {
            return Err(io::Error::last_os_error());
        }
        let service = Self {
            path: path.to_owned(),
            guid: guid.iter().map(|b| format!("{b:02x}")).collect(),
            connections: HashMap::new(),
            next_connection: 0,
            next_context: 0,
            focus_clock: 0,
        };
        service.write_address_file()?;
        Ok(service)
    }

    /// The D-Bus address applications connect to, `IBUS_ADDRESS`.
    pub fn address(&self) -> String {
        format!("unix:path={}", self.path.display())
    }

    /// The address file IBus clients read when they do not take `IBUS_ADDRESS` (Qt among
    /// them), `IBUS_ADDRESS_FILE`.
    pub fn address_file(&self) -> PathBuf {
        self.path.with_file_name("ibus-address")
    }

    /// Writes the address file, naming this process as the daemon so clients know it is
    /// alive.
    fn write_address_file(&self) -> io::Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let path = self.address_file();
        let _ = std::fs::remove_file(&path);
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
        write!(file, "IBUS_ADDRESS={}\nIBUS_DAEMON_PID={}\n", self.address(), std::process::id())
    }

    /// The field with focus in `pid`'s input contexts, if any.
    pub fn focused(&self, pid: u32) -> Option<Field> {
        self.focused_context(pid).map(|(_, _, f)| f)
    }

    fn focused_context(&self, pid: u32) -> Option<(u64, u32, Field)> {
        self.connections
            .iter()
            .filter(|(_, (_, c))| c.pid == pid)
            .filter_map(|(id, (_, c))| c.focused().map(|(order, ctx, f)| (order, *id, ctx, f)))
            .max_by_key(|(order, ..)| *order)
            .map(|(_, conn, ctx, f)| (conn, ctx, f))
    }

    /// Sends the phone keyboard's change to `pid`'s focused field: pre-edit text (with its
    /// caret as a byte offset) and a commit. False when no field of `pid` has focus.
    pub fn send(&mut self, pid: u32, commit: Option<&str>, preedit: Option<(&str, i32)>) -> bool {
        let Some((conn_id, ctx, _)) = self.focused_context(pid) else { return false };
        let Some((stream, conn)) = self.connections.get_mut(&conn_id) else { return false };
        conn.input(ctx, commit, preedit);
        let output = conn.take_output();
        let _ = stream.write_all(&output);
        true
    }
}

impl State {
    fn accept_ibus(&mut self, stream: UnixStream) {
        // SAFETY: getuid cannot fail.
        let uid = unsafe { libc::getuid() };
        let Some((pid, peer_uid)) = peer(&stream).filter(|(_, u)| *u == uid) else {
            tracing::warn!("input method socket: refused a peer of another user");
            return;
        };
        let Some(ibus) = self.ibus.as_mut() else { return };
        if stream.set_nonblocking(true).is_err() {
            return;
        }
        ibus.next_connection += 1;
        let id = ibus.next_connection;
        tracing::debug!("input method: connection {id} from pid {pid}");
        let conn = Connection::new(pid, peer_uid, ibus.guid.clone(), format!(":1.{id}"));
        let Ok(watched) = stream.try_clone() else { return };
        ibus.connections.insert(id, (stream, conn));
        let inserted = self.handle.insert_source(Generic::new(watched, Interest::READ, Mode::Level), move |_, _, state: &mut State| {
            Ok(if state.ibus_readable(id) { PostAction::Continue } else { PostAction::Remove })
        });
        if inserted.is_err() {
            if let Some(ibus) = self.ibus.as_mut() {
                ibus.connections.remove(&id);
            }
        }
    }

    /// Reads what connection `id` sent and answers it; false once it has ended.
    fn ibus_readable(&mut self, id: u64) -> bool {
        let Some(ibus) = self.ibus.as_mut() else { return false };
        let (mut next_context, mut focus_clock) = (ibus.next_context, ibus.focus_clock);
        let Some((stream, conn)) = ibus.connections.get_mut(&id) else { return false };
        let mut buf = [0u8; 16 * 1024];
        let mut alive = true;
        loop {
            match stream.read(&mut buf) {
                Ok(0) => {
                    alive = false;
                    break;
                }
                Ok(n) => {
                    if !conn.receive(&buf[..n], &mut next_context, &mut focus_clock) {
                        alive = false;
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    alive = false;
                    break;
                }
            }
        }
        let output = conn.take_output();
        if alive && !output.is_empty() {
            // Replies are small and the client waits for them.
            let _ = stream.set_nonblocking(false);
            alive = stream.write_all(&output).is_ok();
            let _ = stream.set_nonblocking(true);
        }
        ibus.next_context = next_context;
        ibus.focus_clock = focus_clock;
        if !alive {
            ibus.connections.remove(&id);
        }
        self.sync_ibus_focus();
        alive
    }

    /// The field of `surface`'s window, from its process's input contexts.
    fn ibus_field(&self, surface: Option<WlSurface>) -> Option<(WlSurface, Field)> {
        let ibus = self.ibus.as_ref()?;
        let surface = surface?;
        let id = self.window_of_surface(&surface)?;
        let pid = self.window_pid(&self.windows.get(id)?.surface)?;
        Some((surface, ibus.focused(pid)?))
    }

    /// Shows or hides the phone's keyboard as the focused window's field changes.
    pub fn sync_ibus_focus(&mut self) {
        self.sync_ibus_focus_to(self.keyboard_focus_surface());
    }

    /// The same, for keyboard focus now on `surface`; the seat's focus callback passes it,
    /// as the keyboard cannot be asked for its focus while it reports a change.
    pub fn sync_ibus_focus_to(&mut self, surface: Option<WlSurface>) {
        let now = self.ibus_field(surface);
        if now == self.ibus_shown {
            return;
        }
        tracing::debug!("input method: field {:?}", now.as_ref().map(|(_, f)| f.purpose));
        let before = std::mem::replace(&mut self.ibus_shown, now.clone());
        if let Some((surface, _)) = before.filter(|(s, _)| now.as_ref().is_none_or(|(n, _)| n != s)) {
            self.on_text_input_toggle(crate::text_input::Toggle { surface, enabled: false, purpose: None, surrounding: None });
        }
        if let Some((surface, field)) = now {
            self.on_text_input_toggle(crate::text_input::Toggle {
                surface,
                enabled: true,
                purpose: Some(field.purpose),
                surrounding: field.surrounding,
            });
        }
    }

    /// Sends the phone keyboard's text to the focused window's IBus field; false when it
    /// has none.
    pub fn ibus_send(&mut self, commit: Option<&str>, preedit: Option<(&str, i32)>) -> bool {
        let Some(pid) = self
            .keyboard_focus_surface()
            .and_then(|s| self.window_of_surface(&s))
            .and_then(|id| self.windows.get(id))
            .and_then(|w| self.window_pid(&w.surface))
        else {
            return false;
        };
        self.ibus.as_mut().is_some_and(|ibus| ibus.send(pid, commit, preedit))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(serial: u32, path: &str, interface: &str, member: &str, body: Vec<Value>) -> Vec<u8> {
        Message {
            kind: dbus::METHOD_CALL,
            serial,
            path: Some(path.into()),
            interface: Some(interface.into()),
            member: Some(member.into()),
            destination: Some(IBUS.into()),
            body,
            ..Default::default()
        }
        .encode()
    }

    fn replies(output: &[u8]) -> Vec<Message> {
        let mut out = Vec::new();
        let mut at = 0;
        while at < output.len() {
            let n = Message::length(&output[at..]).unwrap().unwrap();
            out.push(Message::decode(&output[at..at + n]).unwrap());
            at += n;
        }
        out
    }

    struct Client {
        conn: Connection,
        next: u32,
        clock: u64,
    }

    impl Client {
        fn new() -> Self {
            let mut conn = Connection::new(42, 1000, "guid".into(), ":1.7".into());
            assert!(conn.receive(b"\0AUTH EXTERNAL 31303030\r\nBEGIN\r\n", &mut 0, &mut 0));
            assert_eq!(conn.take_output(), b"OK guid\r\n");
            Self { conn, next: 0, clock: 0 }
        }

        fn send(&mut self, bytes: &[u8]) -> Vec<Message> {
            assert!(self.conn.receive(bytes, &mut self.next, &mut self.clock));
            replies(&self.conn.take_output())
        }
    }

    // The calls GTK's ibus module makes, in order, as recorded from Chromium on X11.
    #[test]
    fn a_toolkit_creates_a_context_and_focuses_a_url_field() {
        let mut c = Client::new();
        let hello = c.send(&call(1, "/org/freedesktop/DBus", BUS, "Hello", vec![]));
        assert_eq!(hello[0].body, [Value::Str(":1.7".into())]);
        assert_eq!(hello[0].reply_serial, Some(1));
        let owner = c.send(&call(2, "/org/freedesktop/DBus", BUS, "GetNameOwner", vec![Value::Str(IBUS.into())]));
        assert_eq!(owner[0].body, [Value::Str(OWNER.into())]);
        let made = c.send(&call(3, "/org/freedesktop/IBus", IBUS, "CreateInputContext", vec![Value::Str("gtk3-im:chromium".into())]));
        let path = made[0].body[0].as_str().unwrap().to_owned();
        assert!(path.starts_with(CONTEXT_PATH));
        assert!(c.conn.focused().is_none());
        c.send(&call(4, &path, "org.freedesktop.DBus.Properties", "Set", vec![
            Value::Str(CONTEXT_INTERFACE.into()),
            Value::Str("ContentType".into()),
            Value::Variant(Box::new(Value::Struct(vec![Value::U32(5), Value::U32(0)]))),
        ]));
        let focused = c.send(&call(5, &path, CONTEXT_INTERFACE, "FocusIn", vec![]));
        assert_eq!(focused[0].kind, dbus::METHOD_RETURN);
        assert_eq!(c.conn.focused().unwrap().2, Field { purpose: "url", surrounding: None });
        let key = c.send(&call(6, &path, CONTEXT_INTERFACE, "ProcessKeyEvent", vec![Value::U32(0x61), Value::U32(30), Value::U32(0)]));
        assert_eq!(key[0].body, [Value::Bool(false)]);
        c.send(&call(7, &path, CONTEXT_INTERFACE, "FocusOut", vec![]));
        assert!(c.conn.focused().is_none());
    }

    #[test]
    fn surrounding_text_is_shared_except_from_sensitive_fields() {
        let mut c = Client::new();
        let path = c.send(&call(1, "/org/freedesktop/IBus", IBUS, "CreateInputContext", vec![Value::Str("qt".into())]))[0].body[0]
            .as_str()
            .unwrap()
            .to_owned();
        c.send(&call(2, &path, CONTEXT_INTERFACE, "FocusIn", vec![]));
        c.send(&call(3, &path, CONTEXT_INTERFACE, "SetSurroundingText", vec![text_value("héllo"), Value::U32(2), Value::U32(1)]));
        let field = c.conn.focused().unwrap().2;
        assert_eq!(field.purpose, "normal");
        let s = field.surrounding.unwrap();
        assert_eq!((s.text.as_str(), s.cursor, s.anchor), ("héllo", 3, 1), "character offsets become byte offsets");
        c.send(&call(4, &path, CONTEXT_INTERFACE, "SetContentType", vec![Value::U32(8), Value::U32(0)]));
        assert_eq!(c.conn.focused().unwrap().2, Field { purpose: "password", surrounding: None });
        c.send(&call(5, &path, CONTEXT_INTERFACE, "SetContentType", vec![Value::U32(0), Value::U32(HINT_PRIVATE)]));
        assert_eq!(c.conn.focused().unwrap().2.surrounding, None);
        c.send(&call(6, &path, CONTEXT_INTERFACE, "SetContentType", vec![Value::U32(0), Value::U32(HINT_INHIBIT_OSK)]));
        assert!(c.conn.focused().is_none(), "the field asks for no on-screen keyboard");
    }

    #[test]
    fn the_latest_focus_wins_and_destroyed_contexts_lose_it() {
        let mut c = Client::new();
        let make = |c: &mut Client, serial| {
            c.send(&call(serial, "/org/freedesktop/IBus", IBUS, "CreateInputContext", vec![Value::Str("gtk".into())]))[0].body[0]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let (a, b) = (make(&mut c, 1), make(&mut c, 2));
        c.send(&call(3, &b, CONTEXT_INTERFACE, "SetContentType", vec![Value::U32(6), Value::U32(0)]));
        c.send(&call(4, &a, CONTEXT_INTERFACE, "FocusIn", vec![]));
        c.send(&call(5, &b, CONTEXT_INTERFACE, "FocusIn", vec![]));
        assert_eq!(c.conn.focused().unwrap().2.purpose, "email");
        c.send(&call(6, &b, CONTEXT_INTERFACE, "Destroy", vec![]));
        assert_eq!(c.conn.focused().unwrap().2.purpose, "normal");
        let unknown = c.send(&call(7, &b, CONTEXT_INTERFACE, "FocusIn", vec![]));
        assert_eq!(unknown[0].kind, dbus::ERROR);
    }

    #[test]
    fn commits_and_preedit_reach_the_focused_context_as_signals() {
        let mut c = Client::new();
        let path = c.send(&call(1, "/org/freedesktop/IBus", IBUS, "CreateInputContext", vec![Value::Str("gtk".into())]))[0].body[0]
            .as_str()
            .unwrap()
            .to_owned();
        c.send(&call(2, &path, CONTEXT_INTERFACE, "FocusIn", vec![]));
        let ctx: u32 = path.strip_prefix(CONTEXT_PATH).unwrap().parse().unwrap();
        c.conn.input(ctx, None, Some(("にほ", 6)));
        c.conn.input(ctx, Some("日本😀"), None);
        let signals = replies(&c.conn.take_output());
        let members: Vec<_> = signals.iter().map(|s| s.member.as_deref().unwrap()).collect();
        assert_eq!(members, ["UpdatePreeditText", "HidePreeditText", "CommitText"]);
        assert_eq!(signals[0].body[1], Value::U32(2), "the caret counts characters");
        assert_eq!(signals[2].sender.as_deref(), Some(OWNER));
        assert_eq!(signals[2].path.as_deref(), Some(path.as_str()));
        assert_eq!(ibus_text(&signals[2].body[0]).as_deref(), Some("日本😀"));
        c.conn.input(ctx, Some("a"), None);
        let plain = replies(&c.conn.take_output());
        assert_eq!(plain.len(), 1, "no pre-edit to hide");
    }

    #[test]
    fn calls_that_want_no_reply_get_none_and_garbage_ends_the_connection() {
        let mut c = Client::new();
        let mut quiet = Message::decode(&call(1, "/org/freedesktop/DBus", BUS, "AddMatch", vec![Value::Str("type='signal'".into())])).unwrap();
        quiet.flags = dbus::NO_REPLY_EXPECTED;
        assert!(c.send(&quiet.encode()).is_empty());
        assert!(!c.conn.receive(b"B\x01\x00\x01\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00", &mut 0, &mut 0));
    }

    #[test]
    fn purposes_have_protocol_names() {
        assert_eq!(purpose_name(5), "url");
        assert_eq!(purpose_name(10), "terminal");
        assert_eq!(purpose_name(99), "normal");
    }
}
