//! The subset of CBOR (RFC 8949) the protocol uses, with the canonical encoding the
//! contract requires: definite lengths, shortest integers, every float as float64, and
//! map keys sorted bytewise on their encoded form (RFC 8949 §4.2.1). The decoder is
//! liberal: it accepts any key order and any integer or float width.

use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// Any integer. CBOR major types 0 and 1 cover −2⁶⁴..2⁶⁴−1; the protocol needs
    /// no more than the `i128` subset that fits u64 or i64.
    Int(i128),
    Float(f64),
    Bool(bool),
    Null,
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<Value>),
    /// Text-keyed map. Order here is irrelevant: the encoder sorts.
    Map(Vec<(String, Value)>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CborError {
    Truncated,
    Unsupported(&'static str),
    InvalidUtf8,
    TooDeep,
    TrailingBytes,
    IntegerOverflow,
}

impl fmt::Display for CborError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CborError::Truncated => write!(f, "truncated CBOR"),
            CborError::Unsupported(what) => write!(f, "unsupported CBOR: {what}"),
            CborError::InvalidUtf8 => write!(f, "CBOR text is not UTF-8"),
            CborError::TooDeep => write!(f, "CBOR nested too deeply"),
            CborError::TrailingBytes => write!(f, "bytes after the CBOR item"),
            CborError::IntegerOverflow => write!(f, "CBOR integer out of range"),
        }
    }
}

impl std::error::Error for CborError {}

const MAX_DEPTH: usize = 32;

fn write_head(out: &mut Vec<u8>, major: u8, n: u64) {
    let m = major << 5;
    if n < 24 {
        out.push(m | n as u8);
    } else if n <= u8::MAX as u64 {
        out.push(m | 24);
        out.push(n as u8);
    } else if n <= u16::MAX as u64 {
        out.push(m | 25);
        out.extend_from_slice(&(n as u16).to_be_bytes());
    } else if n <= u32::MAX as u64 {
        out.push(m | 26);
        out.extend_from_slice(&(n as u32).to_be_bytes());
    } else {
        out.push(m | 27);
        out.extend_from_slice(&n.to_be_bytes());
    }
}

/// Encodes `value` canonically.
pub fn encode(value: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    encode_into(value, &mut out);
    out
}

pub fn encode_into(value: &Value, out: &mut Vec<u8>) {
    match value {
        Value::Int(i) => {
            if *i >= 0 {
                write_head(out, 0, *i as u64);
            } else {
                write_head(out, 1, (-1 - *i) as u64);
            }
        }
        Value::Float(f) => {
            out.push(0xfb);
            out.extend_from_slice(&f.to_bits().to_be_bytes());
        }
        Value::Bool(false) => out.push(0xf4),
        Value::Bool(true) => out.push(0xf5),
        Value::Null => out.push(0xf6),
        Value::Bytes(b) => {
            write_head(out, 2, b.len() as u64);
            out.extend_from_slice(b);
        }
        Value::Text(s) => {
            write_head(out, 3, s.len() as u64);
            out.extend_from_slice(s.as_bytes());
        }
        Value::Array(items) => {
            write_head(out, 4, items.len() as u64);
            for item in items {
                encode_into(item, out);
            }
        }
        Value::Map(entries) => {
            let mut keyed: Vec<(Vec<u8>, &Value)> =
                entries.iter().map(|(k, v)| (encode(&Value::Text(k.clone())), v)).collect();
            keyed.sort_by(|a, b| a.0.cmp(&b.0));
            write_head(out, 5, keyed.len() as u64);
            for (k, v) in keyed {
                out.extend_from_slice(&k);
                encode_into(v, out);
            }
        }
    }
}

/// Decodes exactly one item that spans all of `bytes`.
pub fn decode(bytes: &[u8]) -> Result<Value, CborError> {
    let mut reader = Reader { bytes, pos: 0 };
    let value = reader.item(0)?;
    if reader.pos != bytes.len() {
        return Err(CborError::TrailingBytes);
    }
    Ok(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], CborError> {
        let end = self.pos.checked_add(n).ok_or(CborError::Truncated)?;
        if end > self.bytes.len() {
            return Err(CborError::Truncated);
        }
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn byte(&mut self) -> Result<u8, CborError> {
        Ok(self.take(1)?[0])
    }

    fn argument(&mut self, info: u8) -> Result<u64, CborError> {
        Ok(match info {
            0..=23 => info as u64,
            24 => self.byte()? as u64,
            25 => u16::from_be_bytes(self.take(2)?.try_into().unwrap()) as u64,
            26 => u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as u64,
            27 => u64::from_be_bytes(self.take(8)?.try_into().unwrap()),
            31 => return Err(CborError::Unsupported("indefinite length")),
            _ => return Err(CborError::Unsupported("reserved additional info")),
        })
    }

    fn length(&mut self, info: u8) -> Result<usize, CborError> {
        let n = self.argument(info)?;
        let n = usize::try_from(n).map_err(|_| CborError::Truncated)?;
        // Every element takes at least one byte, so a length beyond the input is
        // malformed; checking now avoids huge allocations from hostile input.
        if n > self.bytes.len() - self.pos {
            return Err(CborError::Truncated);
        }
        Ok(n)
    }

    fn item(&mut self, depth: usize) -> Result<Value, CborError> {
        if depth > MAX_DEPTH {
            return Err(CborError::TooDeep);
        }
        let initial = self.byte()?;
        let major = initial >> 5;
        let info = initial & 0x1f;
        match major {
            0 => Ok(Value::Int(self.argument(info)? as i128)),
            1 => Ok(Value::Int(-1 - self.argument(info)? as i128)),
            2 => {
                let n = self.length(info)?;
                Ok(Value::Bytes(self.take(n)?.to_vec()))
            }
            3 => {
                let n = self.length(info)?;
                let s = std::str::from_utf8(self.take(n)?).map_err(|_| CborError::InvalidUtf8)?;
                Ok(Value::Text(s.to_owned()))
            }
            4 => {
                let n = self.length(info)?;
                let mut items = Vec::with_capacity(n);
                for _ in 0..n {
                    items.push(self.item(depth + 1)?);
                }
                Ok(Value::Array(items))
            }
            5 => {
                let n = self.length(info)?;
                let mut entries = Vec::with_capacity(n);
                for _ in 0..n {
                    let key = match self.item(depth + 1)? {
                        Value::Text(k) => k,
                        _ => return Err(CborError::Unsupported("non-text map key")),
                    };
                    entries.push((key, self.item(depth + 1)?));
                }
                Ok(Value::Map(entries))
            }
            6 => {
                // Tags carry no meaning in this protocol: read through them.
                self.argument(info)?;
                self.item(depth + 1)
            }
            7 => match info {
                20 => Ok(Value::Bool(false)),
                21 => Ok(Value::Bool(true)),
                22 | 23 => Ok(Value::Null),
                25 => {
                    let bits = u16::from_be_bytes(self.take(2)?.try_into().unwrap());
                    Ok(Value::Float(f16_to_f64(bits)))
                }
                26 => {
                    let bits = u32::from_be_bytes(self.take(4)?.try_into().unwrap());
                    Ok(Value::Float(f32::from_bits(bits) as f64))
                }
                27 => {
                    let bits = u64::from_be_bytes(self.take(8)?.try_into().unwrap());
                    Ok(Value::Float(f64::from_bits(bits)))
                }
                _ => Err(CborError::Unsupported("simple value")),
            },
            _ => unreachable!(),
        }
    }
}

fn f16_to_f64(bits: u16) -> f64 {
    let sign = if bits & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exp = ((bits >> 10) & 0x1f) as i32;
    let frac = (bits & 0x3ff) as f64;
    let magnitude = match exp {
        0 => frac * 2f64.powi(-24),
        31 if frac == 0.0 => f64::INFINITY,
        31 => f64::NAN,
        _ => (1.0 + frac / 1024.0) * 2f64.powi(exp - 15),
    };
    sign * magnitude
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn integers_use_the_shortest_head() {
        assert_eq!(hex(&encode(&Value::Int(0))), "00");
        assert_eq!(hex(&encode(&Value::Int(23))), "17");
        assert_eq!(hex(&encode(&Value::Int(24))), "1818");
        assert_eq!(hex(&encode(&Value::Int(1000))), "1903e8");
        assert_eq!(hex(&encode(&Value::Int(1_000_000))), "1a000f4240");
        assert_eq!(hex(&encode(&Value::Int(1_000_000_000_000))), "1b000000e8d4a51000");
        assert_eq!(hex(&encode(&Value::Int(-1))), "20");
        assert_eq!(hex(&encode(&Value::Int(-1000))), "3903e7");
    }

    #[test]
    fn floats_are_always_float64() {
        assert_eq!(hex(&encode(&Value::Float(1.5))), "fb3ff8000000000000");
        assert_eq!(hex(&encode(&Value::Float(0.0))), "fb0000000000000000");
    }

    #[test]
    fn map_keys_sort_shorter_first_then_bytewise() {
        let value = Value::Map(vec![
            ("pts_us".into(), Value::Int(1)),
            ("id".into(), Value::Int(2)),
            ("rect".into(), Value::Int(3)),
            ("crop".into(), Value::Int(4)),
        ]);
        let bytes = encode(&value);
        // a4, then "id", "crop", "rect", "pts_us".
        assert_eq!(hex(&bytes), "a4626964026463726f7004647265637403667074735f757301");
    }

    #[test]
    fn decoding_accepts_other_widths_and_orders() {
        // {"b": 1 as u32, "a": 1.5 as float16}
        let bytes = [0xa2, 0x61, b'b', 0x1a, 0, 0, 0, 1, 0x61, b'a', 0xf9, 0x3e, 0x00];
        let value = decode(&bytes).unwrap();
        assert_eq!(value, Value::Map(vec![("b".into(), Value::Int(1)), ("a".into(), Value::Float(1.5))]));
    }

    #[test]
    fn hostile_lengths_are_rejected_without_allocating() {
        assert_eq!(decode(&[0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), Err(CborError::Truncated));
        assert_eq!(decode(&[0x9f]), Err(CborError::Unsupported("indefinite length")));
        let deep = vec![0x81; 100];
        assert_eq!(decode(&deep), Err(CborError::TooDeep));
    }

    #[test]
    fn round_trips() {
        let value = Value::Map(vec![
            ("data".into(), Value::Bytes(vec![0, 0, 0, 1, 0x67])),
            ("title".into(), Value::Text("Terminal — ~".into())),
            ("rect".into(), Value::Array(vec![Value::Int(-4), Value::Int(70000)])),
            ("ok".into(), Value::Bool(true)),
        ]);
        let decoded = decode(&encode(&value)).unwrap();
        assert_eq!(encode(&decoded), encode(&value));
    }
}
