//! Caboose Display Protocol v0: the wire format between `caboose-display` in the guest
//! and its clients (CabooseKit on iOS, `caboose-display-probe`). The contract is
//! docs/display.md; the golden vectors in guest/display/vectors/ pin it byte for byte.
//!
//! Framing: each message is `type: u8, length: u32 LE, payload[length]`, where the
//! payload is one canonical CBOR map. The stream is parsed as bytes; WebSocket message
//! boundaries carry no meaning.

pub mod cbor;
mod fields;
mod messages;
pub mod vectors;

pub use messages::*;

use std::fmt;

pub const VERSION: u32 = 0;

/// The largest payload either side sends or accepts: the host relay's WebSocket
/// `maxPayload` is 16 MiB, and the server writes one message per WebSocket message.
pub const MAX_PAYLOAD: usize = 16 * 1024 * 1024 - HEADER_LEN;

pub const HEADER_LEN: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtocolError {
    Cbor(cbor::CborError),
    NotAMap(&'static str),
    Field { message: &'static str, field: &'static str, problem: &'static str },
    TooLarge(usize),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProtocolError::Cbor(e) => write!(f, "{e}"),
            ProtocolError::NotAMap(m) => write!(f, "{m}: payload is not a CBOR map"),
            ProtocolError::Field { message, field, problem } => write!(f, "{message}.{field}: {problem}"),
            ProtocolError::TooLarge(n) => write!(f, "message of {n} bytes exceeds {MAX_PAYLOAD}"),
        }
    }
}

impl std::error::Error for ProtocolError {}

impl From<cbor::CborError> for ProtocolError {
    fn from(e: cbor::CborError) -> Self {
        ProtocolError::Cbor(e)
    }
}

/// Encodes one message with its header.
pub fn encode(message: &Message) -> Vec<u8> {
    let mut out = Vec::new();
    encode_into(message, &mut out);
    out
}

pub fn encode_into(message: &Message, out: &mut Vec<u8>) {
    let start = out.len();
    out.push(message.type_id());
    out.extend_from_slice(&[0; 4]);
    cbor::encode_into(&message.to_value(), out);
    let len = (out.len() - start - HEADER_LEN) as u32;
    out[start + 1..start + HEADER_LEN].copy_from_slice(&len.to_le_bytes());
}

/// What the stream decoder yields.
#[derive(Debug, Clone, PartialEq)]
pub enum Decoded {
    Message(Message),
    /// A type id this build does not know; skipped by length, as the contract says.
    Unknown {
        type_id: u8,
        len: usize,
    },
    /// A known type whose payload did not decode. The stream is still in sync (the
    /// length framed it), so a receiver may log and continue.
    Invalid {
        type_id: u8,
        error: ProtocolError,
    },
}

/// Incremental decoder for a byte stream of messages.
#[derive(Default)]
pub struct StreamDecoder {
    buffer: Vec<u8>,
    start: usize,
}

impl StreamDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        if self.start > 0 && self.start == self.buffer.len() {
            self.buffer.clear();
            self.start = 0;
        }
        self.buffer.extend_from_slice(bytes);
    }

    /// Bytes received but not yet consumed.
    pub fn pending(&self) -> usize {
        self.buffer.len() - self.start
    }

    /// The next complete message, `Ok(None)` if more bytes are needed, or an error if
    /// the stream announced a payload over [`MAX_PAYLOAD`] (the connection must close:
    /// the stream cannot be trusted past it).
    pub fn next_message(&mut self) -> Result<Option<Decoded>, ProtocolError> {
        let available = &self.buffer[self.start..];
        if available.len() < HEADER_LEN {
            return Ok(None);
        }
        let type_id = available[0];
        let len = u32::from_le_bytes(available[1..HEADER_LEN].try_into().unwrap()) as usize;
        if len > MAX_PAYLOAD {
            return Err(ProtocolError::TooLarge(len));
        }
        if available.len() < HEADER_LEN + len {
            return Ok(None);
        }
        let payload = &available[HEADER_LEN..HEADER_LEN + len];
        let decoded = if type_name(type_id).is_none() {
            Decoded::Unknown { type_id, len }
        } else {
            match decode_payload(type_id, payload) {
                Ok(Some(m)) => Decoded::Message(m),
                Ok(None) => Decoded::Unknown { type_id, len },
                Err(error) => Decoded::Invalid { type_id, error },
            }
        };
        self.start += HEADER_LEN + len;
        if self.start > 1 << 20 && self.start * 2 > self.buffer.len() {
            self.buffer.drain(..self.start);
            self.start = 0;
        }
        Ok(Some(decoded))
    }
}

/// Decodes one payload of a known type.
pub fn decode_payload(type_id: u8, payload: &[u8]) -> Result<Option<Message>, ProtocolError> {
    let value = cbor::decode(payload)?;
    Message::from_value(type_id, &value)
}

/// Decodes a buffer holding whole messages. Errors on a partial trailing message.
pub fn decode_all(bytes: &[u8]) -> Result<Vec<Decoded>, ProtocolError> {
    let mut decoder = StreamDecoder::new();
    decoder.push(bytes);
    let mut out = Vec::new();
    while let Some(d) = decoder.next_message()? {
        out.push(d);
    }
    if decoder.pending() != 0 {
        return Err(ProtocolError::Cbor(cbor::CborError::Truncated));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<Message> {
        vec![
            Message::Ping { t_us: 1 },
            Message::Frame(Frame {
                id: 3,
                codec: Codec::H264,
                keyframe: false,
                pts_us: 99,
                rect: Rect::new(0, 0, 10, 10),
                crop: Rect::new(0, 0, 10, 10),
                data: vec![0, 0, 0, 1, 0x41, 0x9a],
            }),
            Message::Vsync { display: 1, t_us: 2 },
        ]
    }

    #[test]
    fn stream_decoder_reassembles_byte_by_byte() {
        let mut bytes = Vec::new();
        for m in sample() {
            encode_into(&m, &mut bytes);
        }
        let mut decoder = StreamDecoder::new();
        let mut got = Vec::new();
        for b in &bytes {
            decoder.push(std::slice::from_ref(b));
            while let Some(d) = decoder.next_message().unwrap() {
                got.push(d);
            }
        }
        assert_eq!(got, sample().into_iter().map(Decoded::Message).collect::<Vec<_>>());
        assert_eq!(decoder.pending(), 0);
    }

    #[test]
    fn header_is_type_then_little_endian_length() {
        let bytes = encode(&Message::Close { id: 7 });
        // a1 62 "id" 07
        assert_eq!(bytes, [0x85, 5, 0, 0, 0, 0xa1, 0x62, b'i', b'd', 7]);
    }

    #[test]
    fn oversized_lengths_fail_the_stream() {
        let mut decoder = StreamDecoder::new();
        decoder.push(&[0x10, 0xff, 0xff, 0xff, 0x7f]);
        assert!(matches!(decoder.next_message(), Err(ProtocolError::TooLarge(_))));
    }

    #[test]
    fn a_bad_payload_keeps_the_stream_in_sync() {
        let mut bytes = vec![type_id::VSYNC, 1, 0, 0, 0, 0xa0]; // {}: fields missing
        encode_into(&Message::Ping { t_us: 5 }, &mut bytes);
        let decoded = decode_all(&bytes).unwrap();
        assert!(matches!(
            &decoded[0],
            Decoded::Invalid { type_id: type_id::VSYNC, error: ProtocolError::Field { field: "display", .. } }
        ));
        assert_eq!(decoded[1], Decoded::Message(Message::Ping { t_us: 5 }));
    }

    #[test]
    fn unknown_enum_values_are_invalid_but_unknown_codecs_are_filtered() {
        let hello = cbor::Value::Map(vec![
            ("version".into(), cbor::Value::Int(0)),
            ("token".into(), cbor::Value::Text("t".into())),
            (
                "decoders".into(),
                cbor::Value::Array(vec![cbor::Value::Text("vvc".into()), cbor::Value::Text("h264".into())]),
            ),
            ("displays".into(), cbor::Value::Array(vec![])),
        ]);
        let m = Message::from_value(type_id::CLIENT_HELLO, &hello).unwrap().unwrap();
        assert!(matches!(m, Message::ClientHello(ClientHello { ref decoders, .. }) if decoders == &[Codec::H264]));
        let bye = cbor::Value::Map(vec![("reason".into(), cbor::Value::Text("later".into()))]);
        assert!(Message::from_value(type_id::BYE, &bye).is_err());
    }

    #[test]
    fn integer_scale_is_accepted_for_floats() {
        let d = cbor::Value::Map(vec![
            ("id".into(), cbor::Value::Int(1)),
            ("width".into(), cbor::Value::Int(100)),
            ("height".into(), cbor::Value::Int(100)),
            ("scale".into(), cbor::Value::Int(2)),
            ("refresh_hz".into(), cbor::Value::Int(60)),
            ("hdr".into(), cbor::Value::Bool(false)),
        ]);
        let v = cbor::Value::Map(vec![("displays".into(), cbor::Value::Array(vec![d]))]);
        let Some(Message::Displays { displays }) = Message::from_value(type_id::DISPLAYS, &v).unwrap() else {
            panic!()
        };
        assert_eq!(displays[0].scale, 2.0);
    }
}
