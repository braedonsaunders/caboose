//! The D-Bus wire format, as much of it as the input-method service (ibus.rs) speaks: the
//! SASL EXTERNAL handshake and little-endian messages whose bodies hold any of the basic,
//! container and variant types, except Unix file descriptors.
//! <https://dbus.freedesktop.org/doc/dbus-specification.html>

/// A message larger than this ends the connection. Input-method traffic is a few hundred
/// bytes per message.
pub const MAX_MESSAGE: usize = 1 << 20;
/// Containers nest at most this deep (the specification allows 64; no input method needs
/// more than four).
const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Byte(u8),
    Bool(bool),
    I16(i16),
    U16(u16),
    I32(i32),
    U32(u32),
    I64(i64),
    U64(u64),
    Double(f64),
    Str(String),
    Path(String),
    Sig(String),
    Variant(Box<Value>),
    /// The element signature and the elements.
    Array(String, Vec<Value>),
    Struct(Vec<Value>),
    DictEntry(Box<Value>, Box<Value>),
}

impl Value {
    pub fn signature(&self) -> String {
        match self {
            Value::Byte(_) => "y".into(),
            Value::Bool(_) => "b".into(),
            Value::I16(_) => "n".into(),
            Value::U16(_) => "q".into(),
            Value::I32(_) => "i".into(),
            Value::U32(_) => "u".into(),
            Value::I64(_) => "x".into(),
            Value::U64(_) => "t".into(),
            Value::Double(_) => "d".into(),
            Value::Str(_) => "s".into(),
            Value::Path(_) => "o".into(),
            Value::Sig(_) => "g".into(),
            Value::Variant(_) => "v".into(),
            Value::Array(element, _) => format!("a{element}"),
            Value::Struct(fields) => format!("({})", fields.iter().map(Value::signature).collect::<String>()),
            Value::DictEntry(k, v) => format!("{{{}{}}}", k.signature(), v.signature()),
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) | Value::Path(s) | Value::Sig(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_u32(&self) -> Option<u32> {
        match self {
            Value::U32(v) => Some(*v),
            _ => None,
        }
    }
}

/// The complete types of a signature, in order: `"sa{sv}(ii)"` → `["s", "a{sv}", "(ii)"]`.
pub fn split_signature(signature: &str) -> Result<Vec<&str>, String> {
    let mut types = Vec::new();
    let mut rest = signature;
    while !rest.is_empty() {
        let len = complete_type_len(rest, 0)?;
        types.push(&rest[..len]);
        rest = &rest[len..];
    }
    Ok(types)
}

fn complete_type_len(sig: &str, depth: usize) -> Result<usize, String> {
    if depth > MAX_DEPTH {
        return Err("signature nests too deeply".into());
    }
    let bytes = sig.as_bytes();
    match bytes.first() {
        Some(b'y' | b'b' | b'n' | b'q' | b'i' | b'u' | b'x' | b't' | b'd' | b's' | b'o' | b'g' | b'v') => Ok(1),
        Some(b'a') => Ok(1 + complete_type_len(&sig[1..], depth + 1)?),
        Some(b'(') => {
            let mut at = 1;
            while bytes.get(at) != Some(&b')') {
                if at >= bytes.len() {
                    return Err("unterminated struct".into());
                }
                at += complete_type_len(&sig[at..], depth + 1)?;
            }
            if at == 1 {
                return Err("empty struct".into());
            }
            Ok(at + 1)
        }
        Some(b'{') => {
            let key = complete_type_len(&sig[1..], depth + 1)?;
            if key != 1 || matches!(bytes[1], b'v' | b'a' | b'(' | b'{') {
                return Err("dict entry key is not basic".into());
            }
            let value = complete_type_len(&sig[2..], depth + 1)?;
            if bytes.get(2 + value) != Some(&b'}') {
                return Err("dict entry is not a pair".into());
            }
            Ok(3 + value)
        }
        Some(c) => Err(format!("unsupported type {:?}", *c as char)),
        None => Err("missing type".into()),
    }
}

fn alignment(sig: &str) -> usize {
    match sig.as_bytes().first() {
        Some(b'y' | b'g' | b'v') => 1,
        Some(b'n' | b'q') => 2,
        Some(b'b' | b'i' | b'u' | b's' | b'o' | b'a') => 4,
        _ => 8,
    }
}

/// Little-endian marshalling. Offsets align relative to the start of the buffer, which
/// is where the message (or its 8-aligned body) starts.
#[derive(Default)]
pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    fn pad(&mut self, align: usize) {
        while self.buf.len() % align != 0 {
            self.buf.push(0);
        }
    }

    fn u32(&mut self, v: u32) {
        self.pad(4);
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn put(&mut self, value: &Value) {
        match value {
            Value::Byte(v) => self.buf.push(*v),
            Value::Bool(v) => self.u32(*v as u32),
            Value::I16(v) => {
                self.pad(2);
                self.buf.extend_from_slice(&v.to_le_bytes())
            }
            Value::U16(v) => {
                self.pad(2);
                self.buf.extend_from_slice(&v.to_le_bytes())
            }
            Value::I32(v) => self.u32(*v as u32),
            Value::U32(v) => self.u32(*v),
            Value::I64(v) => {
                self.pad(8);
                self.buf.extend_from_slice(&v.to_le_bytes())
            }
            Value::U64(v) => {
                self.pad(8);
                self.buf.extend_from_slice(&v.to_le_bytes())
            }
            Value::Double(v) => {
                self.pad(8);
                self.buf.extend_from_slice(&v.to_le_bytes())
            }
            Value::Str(s) | Value::Path(s) => {
                self.u32(s.len() as u32);
                self.buf.extend_from_slice(s.as_bytes());
                self.buf.push(0);
            }
            Value::Sig(s) => {
                self.buf.push(s.len() as u8);
                self.buf.extend_from_slice(s.as_bytes());
                self.buf.push(0);
            }
            Value::Variant(inner) => {
                self.put(&Value::Sig(inner.signature()));
                self.put(inner);
            }
            Value::Array(element, items) => {
                self.u32(0);
                let length_at = self.buf.len() - 4;
                self.pad(alignment(element));
                let start = self.buf.len();
                for item in items {
                    self.put(item);
                }
                let length = (self.buf.len() - start) as u32;
                self.buf[length_at..length_at + 4].copy_from_slice(&length.to_le_bytes());
            }
            Value::Struct(fields) => {
                self.pad(8);
                for field in fields {
                    self.put(field);
                }
            }
            Value::DictEntry(k, v) => {
                self.pad(8);
                self.put(k);
                self.put(v);
            }
        }
    }
}

pub struct Reader<'a> {
    buf: &'a [u8],
    pub at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8], at: usize) -> Self {
        Self { buf, at }
    }

    fn pad(&mut self, align: usize) -> Result<(), String> {
        while self.at % align != 0 {
            if self.take(1)?[0] != 0 {
                return Err("nonzero padding".into());
            }
        }
        Ok(())
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(n).filter(|end| *end <= self.buf.len()).ok_or("truncated")?;
        let slice = &self.buf[self.at..end];
        self.at = end;
        Ok(slice)
    }

    fn u32(&mut self) -> Result<u32, String> {
        self.pad(4)?;
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn text(&mut self, len: usize) -> Result<String, String> {
        let bytes = self.take(len + 1)?;
        if bytes[len] != 0 || bytes[..len].contains(&0) {
            return Err("string not NUL-terminated".into());
        }
        String::from_utf8(bytes[..len].to_vec()).map_err(|_| "string is not UTF-8".into())
    }

    /// One value of the complete type `sig`.
    pub fn get(&mut self, sig: &str) -> Result<Value, String> {
        self.get_at(sig, 0)
    }

    fn get_at(&mut self, sig: &str, depth: usize) -> Result<Value, String> {
        if depth > MAX_DEPTH {
            return Err("value nests too deeply".into());
        }
        Ok(match sig.as_bytes()[0] {
            b'y' => Value::Byte(self.take(1)?[0]),
            b'b' => match self.u32()? {
                0 => Value::Bool(false),
                1 => Value::Bool(true),
                _ => return Err("boolean is not 0 or 1".into()),
            },
            b'n' => {
                self.pad(2)?;
                Value::I16(i16::from_le_bytes(self.take(2)?.try_into().unwrap()))
            }
            b'q' => {
                self.pad(2)?;
                Value::U16(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
            }
            b'i' => Value::I32(self.u32()? as i32),
            b'u' => Value::U32(self.u32()?),
            b'x' => {
                self.pad(8)?;
                Value::I64(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
            }
            b't' => {
                self.pad(8)?;
                Value::U64(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
            }
            b'd' => {
                self.pad(8)?;
                Value::Double(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
            }
            b's' => {
                let len = self.u32()? as usize;
                Value::Str(self.text(len)?)
            }
            b'o' => {
                let len = self.u32()? as usize;
                Value::Path(self.text(len)?)
            }
            b'g' => {
                let len = self.take(1)?[0] as usize;
                Value::Sig(self.text(len)?)
            }
            b'v' => {
                let len = self.take(1)?[0] as usize;
                let inner = self.text(len)?;
                if split_signature(&inner)?.len() != 1 {
                    return Err("variant holds other than one type".into());
                }
                Value::Variant(Box::new(self.get_at(&inner, depth + 1)?))
            }
            b'a' => {
                let element = &sig[1..];
                let len = self.u32()? as usize;
                if len > (1 << 26) {
                    return Err("array too long".into());
                }
                self.pad(alignment(element))?;
                let end = self.at.checked_add(len).filter(|e| *e <= self.buf.len()).ok_or("truncated array")?;
                let mut items = Vec::new();
                while self.at < end {
                    items.push(self.get_at(element, depth + 1)?);
                }
                if self.at != end {
                    return Err("array length mismatch".into());
                }
                Value::Array(element.to_owned(), items)
            }
            b'(' => {
                self.pad(8)?;
                let fields = split_signature(&sig[1..sig.len() - 1])?;
                Value::Struct(fields.iter().map(|f| self.get_at(f, depth + 1)).collect::<Result<_, _>>()?)
            }
            b'{' => {
                self.pad(8)?;
                let inner = split_signature(&sig[1..sig.len() - 1])?;
                let k = self.get_at(inner[0], depth + 1)?;
                let v = self.get_at(inner[1], depth + 1)?;
                Value::DictEntry(Box::new(k), Box::new(v))
            }
            c => return Err(format!("unsupported type {:?}", c as char)),
        })
    }
}

pub const METHOD_CALL: u8 = 1;
pub const METHOD_RETURN: u8 = 2;
pub const ERROR: u8 = 3;
pub const SIGNAL: u8 = 4;
/// The caller does not want a reply.
pub const NO_REPLY_EXPECTED: u8 = 1;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Message {
    pub kind: u8,
    pub flags: u8,
    pub serial: u32,
    pub path: Option<String>,
    pub interface: Option<String>,
    pub member: Option<String>,
    pub error_name: Option<String>,
    pub reply_serial: Option<u32>,
    pub destination: Option<String>,
    pub sender: Option<String>,
    pub body: Vec<Value>,
}

impl Message {
    pub fn encode(&self) -> Vec<u8> {
        let mut body = Writer::default();
        for value in &self.body {
            body.put(value);
        }
        let signature: String = self.body.iter().map(Value::signature).collect();
        let mut fields = Vec::new();
        let mut field = |code: u8, value: Value| {
            fields.push(Value::Struct(vec![Value::Byte(code), Value::Variant(Box::new(value))]));
        };
        if let Some(v) = &self.path {
            field(1, Value::Path(v.clone()));
        }
        if let Some(v) = &self.interface {
            field(2, Value::Str(v.clone()));
        }
        if let Some(v) = &self.member {
            field(3, Value::Str(v.clone()));
        }
        if let Some(v) = &self.error_name {
            field(4, Value::Str(v.clone()));
        }
        if let Some(v) = self.reply_serial {
            field(5, Value::U32(v));
        }
        if let Some(v) = &self.destination {
            field(6, Value::Str(v.clone()));
        }
        if let Some(v) = &self.sender {
            field(7, Value::Str(v.clone()));
        }
        if !signature.is_empty() {
            field(8, Value::Sig(signature));
        }
        let mut out = Writer { buf: vec![b'l', self.kind, self.flags, 1] };
        out.buf.extend_from_slice(&(body.buf.len() as u32).to_le_bytes());
        out.buf.extend_from_slice(&self.serial.to_le_bytes());
        out.put(&Value::Array("(yv)".into(), fields));
        out.pad(8);
        out.buf.extend_from_slice(&body.buf);
        out.buf
    }

    /// The length of the complete message at the start of `buf`, once its fixed header
    /// has arrived.
    pub fn length(buf: &[u8]) -> Result<Option<usize>, String> {
        if buf.len() < 16 {
            return Ok(None);
        }
        if buf[0] != b'l' {
            return Err("only little-endian messages are accepted".into());
        }
        if buf[3] != 1 {
            return Err("unknown protocol version".into());
        }
        let body = u32::from_le_bytes(buf[4..8].try_into().unwrap()) as usize;
        let fields = u32::from_le_bytes(buf[12..16].try_into().unwrap()) as usize;
        let header = (16 + fields).div_ceil(8) * 8;
        let total = header.checked_add(body).ok_or("message too long")?;
        if total > MAX_MESSAGE {
            return Err("message too long".into());
        }
        Ok(Some(total))
    }

    pub fn decode(buf: &[u8]) -> Result<Self, String> {
        let total = Self::length(buf)?.ok_or("truncated header")?;
        if buf.len() != total {
            return Err("message length mismatch".into());
        }
        let mut message = Message { kind: buf[1], flags: buf[2], ..Default::default() };
        message.serial = u32::from_le_bytes(buf[8..12].try_into().unwrap());
        if message.serial == 0 || !(METHOD_CALL..=SIGNAL).contains(&message.kind) {
            return Err("invalid message".into());
        }
        let body_len = u32::from_le_bytes(buf[4..8].try_into().unwrap()) as usize;
        let mut reader = Reader::new(buf, 12);
        let Value::Array(_, fields) = reader.get("a(yv)")? else { unreachable!() };
        let mut signature = String::new();
        for field in fields {
            let Value::Struct(parts) = field else { unreachable!() };
            let (Value::Byte(code), Value::Variant(value)) = (&parts[0], &parts[1]) else { unreachable!() };
            let text = || value.as_str().map(str::to_owned);
            match code {
                1 => message.path = text(),
                2 => message.interface = text(),
                3 => message.member = text(),
                4 => message.error_name = text(),
                5 => message.reply_serial = value.as_u32(),
                6 => message.destination = text(),
                7 => message.sender = text(),
                8 => signature = text().unwrap_or_default(),
                9 => return Err("Unix file descriptors are not accepted".into()),
                _ => {}
            }
        }
        let body_start = total - body_len;
        let mut reader = Reader::new(&buf[body_start..], 0);
        for sig in split_signature(&signature)? {
            message.body.push(reader.get(sig)?);
        }
        if reader.at != body_len {
            return Err("body does not match its signature".into());
        }
        Ok(message)
    }
}

/// The server's side of the SASL handshake that precedes messages. Only EXTERNAL is
/// offered: the peer's user is known from the socket itself.
pub struct Auth {
    guid: String,
    started: bool,
    line: Vec<u8>,
    pub done: bool,
}

pub enum AuthStep {
    /// More input is needed; send this reply (possibly empty) meanwhile.
    Continue(Vec<u8>),
    /// The handshake is over: send this reply, then messages follow; `usize` bytes of the
    /// input were consumed.
    Begin(Vec<u8>, usize),
    Fail,
}

impl Auth {
    pub fn new(guid: String) -> Self {
        Self { guid, started: false, line: Vec::new(), done: false }
    }

    /// Feeds bytes from the client. `uid` is the peer's user from the socket.
    pub fn feed(&mut self, input: &[u8], uid: u32) -> AuthStep {
        let mut reply = Vec::new();
        for (i, &byte) in input.iter().enumerate() {
            if !self.started {
                // The credentials byte.
                if byte != 0 {
                    return AuthStep::Fail;
                }
                self.started = true;
                continue;
            }
            self.line.push(byte);
            if self.line.len() > 16384 {
                return AuthStep::Fail;
            }
            if !self.line.ends_with(b"\r\n") {
                continue;
            }
            let line = String::from_utf8_lossy(&self.line[..self.line.len() - 2]).into_owned();
            self.line.clear();
            let mut words = line.split(' ');
            match (words.next(), words.next(), words.next()) {
                (Some("AUTH"), Some("EXTERNAL"), claimed) => {
                    let ours = uid.to_string();
                    let claimed_uid = claimed.map(|hex| decode_hex(hex).unwrap_or_default());
                    if claimed_uid.is_none_or(|c| c == ours.as_bytes()) {
                        reply.extend_from_slice(format!("OK {}\r\n", self.guid).as_bytes());
                    } else {
                        reply.extend_from_slice(b"REJECTED EXTERNAL\r\n");
                    }
                }
                (Some("AUTH"), _, _) | (Some("CANCEL"), _, _) | (Some("ERROR"), _, _) => {
                    reply.extend_from_slice(b"REJECTED EXTERNAL\r\n")
                }
                (Some("NEGOTIATE_UNIX_FD"), _, _) => reply.extend_from_slice(b"ERROR Unix file descriptors are not offered\r\n"),
                (Some("BEGIN"), _, _) => {
                    self.done = true;
                    return AuthStep::Begin(reply, i + 1);
                }
                _ => reply.extend_from_slice(b"ERROR\r\n"),
            }
        }
        AuthStep::Continue(reply)
    }
}

fn decode_hex(hex: &str) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_split_into_complete_types() {
        assert_eq!(split_signature("sa{sv}(ii)v").unwrap(), ["s", "a{sv}", "(ii)", "v"]);
        assert_eq!(split_signature("a(yv)").unwrap(), ["a(yv)"]);
        assert!(split_signature("(").is_err());
        assert!(split_signature("{vs}").is_err());
        assert!(split_signature("h").is_err());
        assert!(split_signature(&"a".repeat(40)).is_err());
    }

    #[test]
    fn values_round_trip_with_alignment() {
        let values = vec![
            Value::Byte(7),
            Value::Struct(vec![
                Value::Str("IBusText".into()),
                Value::Array("{sv}".into(), vec![]),
                Value::Str("héllo".into()),
                Value::Variant(Box::new(Value::Struct(vec![
                    Value::Str("IBusAttrList".into()),
                    Value::Array("{sv}".into(), vec![]),
                    Value::Array("v".into(), vec![]),
                ]))),
            ]),
            Value::U32(3),
            Value::Array("{sv}".into(), vec![Value::DictEntry(
                Box::new(Value::Str("k".into())),
                Box::new(Value::Variant(Box::new(Value::I64(-2)))),
            )]),
            Value::Bool(true),
            Value::Double(1.5),
            Value::I16(-4),
        ];
        let mut writer = Writer::default();
        for v in &values {
            writer.put(v);
        }
        let mut reader = Reader::new(&writer.buf, 0);
        let sig: String = values.iter().map(Value::signature).collect();
        let decoded: Vec<Value> = split_signature(&sig).unwrap().iter().map(|s| reader.get(s).unwrap()).collect();
        assert_eq!(decoded, values);
        assert_eq!(reader.at, writer.buf.len());
    }

    #[test]
    fn messages_round_trip() {
        let message = Message {
            kind: METHOD_CALL,
            serial: 9,
            path: Some("/org/freedesktop/IBus".into()),
            interface: Some("org.freedesktop.IBus".into()),
            member: Some("CreateInputContext".into()),
            destination: Some("org.freedesktop.IBus".into()),
            body: vec![Value::Str("gtk3-im:chromium".into())],
            ..Default::default()
        };
        let bytes = message.encode();
        assert_eq!(Message::length(&bytes).unwrap(), Some(bytes.len()));
        assert_eq!(Message::length(&bytes[..15]).unwrap(), None);
        assert_eq!(Message::decode(&bytes).unwrap(), message);
    }

    // GLib's own bytes for its Hello (recorded from GDBus, which orders the header
    // fields path, interface, destination, member).
    #[test]
    fn decodes_a_gdbus_hello() {
        let hex = "6c01000100000000010000006e00000001016f00150000002f6f72672f667265656465736b746f702f\
                   4442757300000002017300140000006f72672e667265656465736b746f702e44427573000000000601\
                   7300140000006f72672e667265656465736b746f702e4442757300000000030173000500000048656c\
                   6c6f000000";
        let bytes: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect();
        assert_eq!(Message::length(&bytes).unwrap(), Some(bytes.len()));
        let expected = Message {
            kind: METHOD_CALL,
            serial: 1,
            path: Some("/org/freedesktop/DBus".into()),
            interface: Some("org.freedesktop.DBus".into()),
            member: Some("Hello".into()),
            destination: Some("org.freedesktop.DBus".into()),
            ..Default::default()
        };
        assert_eq!(Message::decode(&bytes).unwrap(), expected);
        assert_eq!(expected.encode().len(), bytes.len());
    }

    #[test]
    fn rejects_malformed_messages() {
        let mut bytes = Message { kind: SIGNAL, serial: 1, member: Some("X".into()), ..Default::default() }.encode();
        assert!(Message::decode(&bytes[..bytes.len() - 1]).is_err());
        bytes[0] = b'B';
        assert!(Message::length(&bytes).is_err());
        let mut huge = b"l\x01\x00\x01".to_vec();
        huge.extend_from_slice(&(MAX_MESSAGE as u32).to_le_bytes());
        huge.extend_from_slice(&[1, 0, 0, 0, 0, 0, 0, 0]);
        assert!(Message::length(&huge).is_err());
        let mut reader = Reader::new(b"\x02\x00\x00\x00", 0);
        assert!(reader.get("b").is_err());
    }

    #[test]
    fn authenticates_the_peer_user_only() {
        let mut auth = Auth::new("0123".into());
        // GDBus first asks which mechanisms there are.
        let AuthStep::Continue(reply) = auth.feed(b"\0AUTH\r\n", 1000) else { panic!() };
        assert_eq!(reply, b"REJECTED EXTERNAL\r\n");
        let AuthStep::Continue(reply) = auth.feed(b"AUTH EXTERNAL 31303030\r\n", 1000) else { panic!() };
        assert_eq!(reply, b"OK 0123\r\n");
        let AuthStep::Continue(reply) = auth.feed(b"NEGOTIATE_UNIX_FD\r\n", 1000) else { panic!() };
        assert!(reply.starts_with(b"ERROR"));
        let AuthStep::Begin(reply, used) = auth.feed(b"BEGIN\r\nl\x01", 1000) else { panic!() };
        assert!(reply.is_empty());
        assert_eq!(used, 7);
        let mut other = Auth::new("0123".into());
        let AuthStep::Continue(reply) = other.feed(b"\0AUTH EXTERNAL 30\r\n", 1000) else { panic!() };
        assert_eq!(reply, b"REJECTED EXTERNAL\r\n");
        assert!(matches!(Auth::new("x".into()).feed(b"AUTH\r\n", 1000), AuthStep::Fail));
    }
}
