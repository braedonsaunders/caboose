//! Typed access to the text-keyed CBOR maps every message carries.

use crate::cbor::Value;
use crate::ProtocolError;

/// Builds a message map, skipping absent optional fields (the contract encodes an
/// absent field by leaving it out, never as null).
#[derive(Default)]
pub(crate) struct MapBuilder(Vec<(String, Value)>);

impl MapBuilder {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn put(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.0.push((key.to_owned(), value.into()));
        self
    }
    pub fn opt(self, key: &str, value: Option<impl Into<Value>>) -> Self {
        match value {
            Some(v) => self.put(key, v),
            None => self,
        }
    }
    pub fn build(self) -> Value {
        Value::Map(self.0)
    }
}

impl From<u64> for Value {
    fn from(v: u64) -> Self {
        Value::Int(v as i128)
    }
}
impl From<u32> for Value {
    fn from(v: u32) -> Self {
        Value::Int(v as i128)
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v as i128)
    }
}
impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::Int(v as i128)
    }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::Float(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Text(v)
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Text(v.to_owned())
    }
}
impl From<Vec<u8>> for Value {
    fn from(v: Vec<u8>) -> Self {
        Value::Bytes(v)
    }
}
impl From<Vec<Value>> for Value {
    fn from(v: Vec<Value>) -> Self {
        Value::Array(v)
    }
}
impl From<Vec<String>> for Value {
    fn from(v: Vec<String>) -> Self {
        Value::Array(v.into_iter().map(Value::Text).collect())
    }
}

/// Reads fields from a decoded message map. Unknown keys are ignored.
pub(crate) struct Fields<'a> {
    message: &'static str,
    entries: &'a [(String, Value)],
}

fn missing(message: &'static str, field: &'static str) -> ProtocolError {
    ProtocolError::Field { message, field, problem: "missing" }
}

fn wrong(message: &'static str, field: &'static str) -> ProtocolError {
    ProtocolError::Field { message, field, problem: "wrong type or out of range" }
}

impl<'a> Fields<'a> {
    pub fn new(message: &'static str, value: &'a Value) -> Result<Self, ProtocolError> {
        match value {
            Value::Map(entries) => Ok(Self { message, entries }),
            _ => Err(ProtocolError::NotAMap(message)),
        }
    }

    fn raw(&self, key: &str) -> Option<&'a Value> {
        // Last one wins if a hostile peer repeats a key; canonical encoders never do.
        self.entries.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn opt<T>(&self, key: &'static str, f: impl Fn(&'a Value) -> Option<T>) -> Result<Option<T>, ProtocolError> {
        match self.raw(key) {
            None | Some(Value::Null) => Ok(None),
            Some(v) => f(v).map(Some).ok_or_else(|| wrong(self.message, key)),
        }
    }

    pub fn req<T>(&self, key: &'static str, f: impl Fn(&'a Value) -> Option<T>) -> Result<T, ProtocolError> {
        self.opt(key, f)?.ok_or_else(|| missing(self.message, key))
    }

    pub fn u64(&self, key: &'static str) -> Result<u64, ProtocolError> {
        self.req(key, as_u64)
    }
    pub fn opt_u64(&self, key: &'static str) -> Result<Option<u64>, ProtocolError> {
        self.opt(key, as_u64)
    }
    pub fn u32(&self, key: &'static str) -> Result<u32, ProtocolError> {
        self.req(key, as_u32)
    }
    pub fn opt_u32(&self, key: &'static str) -> Result<Option<u32>, ProtocolError> {
        self.opt(key, as_u32)
    }
    pub fn i64(&self, key: &'static str) -> Result<i64, ProtocolError> {
        self.req(key, as_i64)
    }
    pub fn f64(&self, key: &'static str) -> Result<f64, ProtocolError> {
        self.req(key, as_f64)
    }
    pub fn opt_f64(&self, key: &'static str) -> Result<Option<f64>, ProtocolError> {
        self.opt(key, as_f64)
    }
    pub fn bool(&self, key: &'static str) -> Result<bool, ProtocolError> {
        self.req(key, as_bool)
    }
    pub fn opt_bool(&self, key: &'static str) -> Result<Option<bool>, ProtocolError> {
        self.opt(key, as_bool)
    }
    pub fn string(&self, key: &'static str) -> Result<String, ProtocolError> {
        self.req(key, as_string)
    }
    pub fn opt_string(&self, key: &'static str) -> Result<Option<String>, ProtocolError> {
        self.opt(key, as_string)
    }
    pub fn bytes(&self, key: &'static str) -> Result<Vec<u8>, ProtocolError> {
        self.req(key, as_bytes)
    }
    pub fn opt_bytes(&self, key: &'static str) -> Result<Option<Vec<u8>>, ProtocolError> {
        self.opt(key, as_bytes)
    }
    pub fn strings(&self, key: &'static str) -> Result<Vec<String>, ProtocolError> {
        self.req(key, |v| as_array(v)?.iter().map(as_string).collect())
    }
    pub fn array(&self, key: &'static str) -> Result<&'a [Value], ProtocolError> {
        self.req(key, as_array)
    }
    pub fn rect(&self, key: &'static str) -> Result<crate::Rect, ProtocolError> {
        self.req(key, as_rect)
    }
    pub fn opt_rect(&self, key: &'static str) -> Result<Option<crate::Rect>, ProtocolError> {
        self.opt(key, as_rect)
    }
    pub fn opt_size(&self, key: &'static str) -> Result<Option<crate::Size>, ProtocolError> {
        self.opt(key, as_size)
    }
}

pub(crate) fn as_u64(v: &Value) -> Option<u64> {
    match v {
        Value::Int(i) => u64::try_from(*i).ok(),
        _ => None,
    }
}
pub(crate) fn as_u32(v: &Value) -> Option<u32> {
    match v {
        Value::Int(i) => u32::try_from(*i).ok(),
        _ => None,
    }
}
pub(crate) fn as_i64(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => i64::try_from(*i).ok(),
        _ => None,
    }
}
pub(crate) fn as_i32(v: &Value) -> Option<i32> {
    match v {
        Value::Int(i) => i32::try_from(*i).ok(),
        _ => None,
    }
}
/// Floats also accept integers, so a peer that writes `3` for a scale of 3.0 is
/// still understood (encoders must still write float64).
pub(crate) fn as_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Float(f) => Some(*f),
        Value::Int(i) => Some(*i as f64),
        _ => None,
    }
}
pub(crate) fn as_bool(v: &Value) -> Option<bool> {
    match v {
        Value::Bool(b) => Some(*b),
        _ => None,
    }
}
pub(crate) fn as_string(v: &Value) -> Option<String> {
    match v {
        Value::Text(s) => Some(s.clone()),
        _ => None,
    }
}
pub(crate) fn as_bytes(v: &Value) -> Option<Vec<u8>> {
    match v {
        Value::Bytes(b) => Some(b.clone()),
        _ => None,
    }
}
pub(crate) fn as_array(v: &Value) -> Option<&[Value]> {
    match v {
        Value::Array(a) => Some(a),
        _ => None,
    }
}
pub(crate) fn as_rect(v: &Value) -> Option<crate::Rect> {
    match as_array(v)? {
        [x, y, w, h] => Some(crate::Rect { x: as_i32(x)?, y: as_i32(y)?, w: as_i32(w)?, h: as_i32(h)? }),
        _ => None,
    }
}
pub(crate) fn as_size(v: &Value) -> Option<crate::Size> {
    match as_array(v)? {
        [w, h] => Some(crate::Size { w: as_i32(w)?, h: as_i32(h)? }),
        _ => None,
    }
}
pub(crate) fn as_f64_pair(v: &Value) -> Option<[f64; 2]> {
    match as_array(v)? {
        [a, b] => Some([as_f64(a)?, as_f64(b)?]),
        _ => None,
    }
}
pub(crate) fn as_i32_pair(v: &Value) -> Option<[i32; 2]> {
    match as_array(v)? {
        [a, b] => Some([as_i32(a)?, as_i32(b)?]),
        _ => None,
    }
}
pub(crate) fn as_u32_pair(v: &Value) -> Option<[u32; 2]> {
    match as_array(v)? {
        [a, b] => Some([as_u32(a)?, as_u32(b)?]),
        _ => None,
    }
}
