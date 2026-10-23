//! Minimal JSON: just what the engine needs to read Hyprland replies and
//! its own state files, and to print the state the QML renders. No
//! dependencies, a nesting limit and an input cap.

use std::collections::BTreeMap;
use std::fmt;

pub type Map = BTreeMap<String, Value>;

/// Deepest nesting accepted (Hyprland replies use 3-4 levels).
const MAX_DEPTH: usize = 64;
/// Largest document accepted by the parser.
pub const MAX_INPUT: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
pub enum Number {
    I(i64),
    U(u64),
    F(f64),
}

#[derive(Clone, Debug, PartialEq, Default)]
pub enum Value {
    #[default]
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<Value>),
    Object(Map),
}

static NULL: Value = Value::Null;

#[derive(Debug)]
pub struct Error;

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(m) => m.get(key),
            _ => None,
        }
    }
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Value::Number(Number::I(v)) => Some(*v),
            Value::Number(Number::U(v)) => i64::try_from(*v).ok(),
            _ => None,
        }
    }
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Value::Number(Number::U(v)) => Some(*v),
            Value::Number(Number::I(v)) => u64::try_from(*v).ok(),
            _ => None,
        }
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Number(Number::I(v)) => Some(*v as f64),
            Value::Number(Number::U(v)) => Some(*v as f64),
            Value::Number(Number::F(v)) => Some(*v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_array(&self) -> Option<&Vec<Value>> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }
    pub fn as_object(&self) -> Option<&Map> {
        match self {
            Value::Object(m) => Some(m),
            _ => None,
        }
    }
    pub fn is_object(&self) -> bool {
        matches!(self, Value::Object(_))
    }
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }
}

impl std::ops::Index<&str> for Value {
    type Output = Value;
    fn index(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&NULL)
    }
}

impl std::ops::IndexMut<&str> for Value {
    fn index_mut(&mut self, key: &str) -> &mut Value {
        if !self.is_object() {
            *self = Value::Object(Map::new());
        }
        match self {
            Value::Object(m) => m.entry(key.to_string()).or_insert(Value::Null),
            _ => unreachable!(),
        }
    }
}

impl std::ops::Index<usize> for Value {
    type Output = Value;
    fn index(&self, i: usize) -> &Value {
        match self {
            Value::Array(a) => a.get(i).unwrap_or(&NULL),
            _ => &NULL,
        }
    }
}

macro_rules! from_int {
    ($($t:ty => $v:ident),*) => {$(
        impl From<$t> for Value {
            fn from(n: $t) -> Value { Value::Number(Number::$v(n as _)) }
        }
        impl From<&$t> for Value {
            fn from(n: &$t) -> Value { Value::Number(Number::$v(*n as _)) }
        }
    )*};
}
from_int!(i32 => I, i64 => I, u32 => U, u64 => U, usize => U);

impl From<f64> for Value {
    fn from(n: f64) -> Value {
        Value::Number(Number::F(n))
    }
}
impl From<f32> for Value {
    fn from(n: f32) -> Value {
        Value::Number(Number::F(n as f64))
    }
}
impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Value::Bool(b)
    }
}
impl From<&str> for Value {
    fn from(s: &str) -> Value {
        Value::String(s.to_string())
    }
}
impl From<String> for Value {
    fn from(s: String) -> Value {
        Value::String(s)
    }
}
impl From<&String> for Value {
    fn from(s: &String) -> Value {
        Value::String(s.clone())
    }
}
impl From<Vec<Value>> for Value {
    fn from(v: Vec<Value>) -> Value {
        Value::Array(v)
    }
}
impl From<Map> for Value {
    fn from(m: Map) -> Value {
        Value::Object(m)
    }
}
impl<T: Into<Value>> From<Option<T>> for Value {
    fn from(o: Option<T>) -> Value {
        o.map(Into::into).unwrap_or(Value::Null)
    }
}

/// `json!({"k": expr, ...})`, `json!({})`, `json!(expr)`.
#[macro_export]
macro_rules! json {
    ({}) => { $crate::json::Value::Object($crate::json::Map::new()) };
    ({ $($k:literal : $v:expr),+ $(,)? }) => {{
        let mut m = $crate::json::Map::new();
        $( m.insert($k.to_string(), $crate::json::Value::from($v)); )+
        $crate::json::Value::Object(m)
    }};
    ($v:expr) => { $crate::json::Value::from($v) };
}

// ---------- output ----------

pub fn write_escaped(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            // Other controls, plus the JS line separators QML's parser
            // would otherwise see raw.
            c if (c as u32) < 0x20 || c == '\u{7f}' || c == '\u{2028}' || c == '\u{2029}' => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A JSON string literal (quotes included) for hand-built output.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    write_escaped(&mut out, s);
    out
}

fn write_value(out: &mut String, v: &Value) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(Number::I(n)) => out.push_str(&n.to_string()),
        Value::Number(Number::U(n)) => out.push_str(&n.to_string()),
        Value::Number(Number::F(f)) => {
            if f.is_finite() {
                out.push_str(&f.to_string());
            } else {
                out.push_str("null");
            }
        }
        Value::String(s) => write_escaped(out, s),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(out, x);
            }
            out.push(']');
        }
        Value::Object(m) => {
            out.push('{');
            for (i, (k, x)) in m.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_escaped(out, k);
                out.push(':');
                write_value(out, x);
            }
            out.push('}');
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut s = String::new();
        write_value(&mut s, self);
        f.write_str(&s)
    }
}

// ---------- parser ----------

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn lit(&mut self, s: &[u8], v: Value) -> Result<Value, Error> {
        if self.b[self.i..].starts_with(s) {
            self.i += s.len();
            Ok(v)
        } else {
            Err(Error)
        }
    }
    fn value(&mut self, depth: usize) -> Result<Value, Error> {
        if depth > MAX_DEPTH {
            return Err(Error);
        }
        self.ws();
        match self.peek().ok_or(Error)? {
            b'n' => self.lit(b"null", Value::Null),
            b't' => self.lit(b"true", Value::Bool(true)),
            b'f' => self.lit(b"false", Value::Bool(false)),
            b'"' => self.string().map(Value::String),
            b'[' => {
                self.i += 1;
                let mut a = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                    return Ok(Value::Array(a));
                }
                loop {
                    a.push(self.value(depth + 1)?);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b']') => {
                            self.i += 1;
                            return Ok(Value::Array(a));
                        }
                        _ => return Err(Error),
                    }
                }
            }
            b'{' => {
                self.i += 1;
                let mut m = Map::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.i += 1;
                    return Ok(Value::Object(m));
                }
                loop {
                    self.ws();
                    if self.peek() != Some(b'"') {
                        return Err(Error);
                    }
                    let k = self.string()?;
                    self.ws();
                    if self.peek() != Some(b':') {
                        return Err(Error);
                    }
                    self.i += 1;
                    let v = self.value(depth + 1)?;
                    m.insert(k, v);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b'}') => {
                            self.i += 1;
                            return Ok(Value::Object(m));
                        }
                        _ => return Err(Error),
                    }
                }
            }
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(Error),
        }
    }
    fn hex4(&mut self) -> Result<u32, Error> {
        let h = self.b.get(self.i..self.i + 4).ok_or(Error)?;
        let s = std::str::from_utf8(h).map_err(|_| Error)?;
        let v = u32::from_str_radix(s, 16).map_err(|_| Error)?;
        self.i += 4;
        Ok(v)
    }
    fn string(&mut self) -> Result<String, Error> {
        self.i += 1; // opening quote
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.peek().ok_or(Error)?;
            self.i += 1;
            match c {
                b'"' => return String::from_utf8(out).map_err(|_| Error),
                b'\\' => {
                    let e = self.peek().ok_or(Error)?;
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(8),
                        b'f' => out.push(12),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'u' => {
                            let mut cp = self.hex4()?;
                            if (0xD800..0xDC00).contains(&cp) {
                                // Surrogate pair; a lone half becomes U+FFFD.
                                if self.b[self.i..].starts_with(b"\\u") {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    cp = if (0xDC00..0xE000).contains(&lo) {
                                        0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                                    } else {
                                        0xFFFD
                                    };
                                } else {
                                    cp = 0xFFFD;
                                }
                            } else if (0xDC00..0xE000).contains(&cp) {
                                cp = 0xFFFD;
                            }
                            let ch = char::from_u32(cp).unwrap_or('\u{FFFD}');
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err(Error),
                    }
                }
                c if c < 0x20 => return Err(Error),
                c => out.push(c),
            }
        }
    }
    fn number(&mut self) -> Result<Value, Error> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let mut float = false;
        while let Some(c) = self.peek() {
            match c {
                b'0'..=b'9' => {}
                b'.' | b'e' | b'E' | b'+' | b'-' => float = true,
                _ => break,
            }
            self.i += 1;
        }
        let s = std::str::from_utf8(&self.b[start..self.i]).map_err(|_| Error)?;
        if s == "-" || s.is_empty() {
            return Err(Error);
        }
        if !float {
            if let Ok(u) = s.parse::<u64>() {
                return Ok(Value::Number(Number::U(u)));
            }
            if let Ok(i) = s.parse::<i64>() {
                return Ok(Value::Number(Number::I(i)));
            }
        }
        s.parse::<f64>()
            .map(|f| Value::Number(Number::F(f)))
            .map_err(|_| Error)
    }
}

pub fn from_slice(b: &[u8]) -> Result<Value, Error> {
    if b.len() > MAX_INPUT {
        return Err(Error);
    }
    let mut p = Parser { b, i: 0 };
    let v = p.value(0)?;
    p.ws();
    if p.i != b.len() {
        return Err(Error);
    }
    Ok(v)
}

pub fn from_str(s: &str) -> Result<Value, Error> {
    from_slice(s.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_escaping() {
        let v = from_str(r#"{"a":[1,-2,3.5,true,null],"s":"q\"\\\né😀"}"#).unwrap();
        assert_eq!(v["a"][0].as_u64(), Some(1));
        assert_eq!(v["a"][1].as_i64(), Some(-2));
        assert_eq!(v["a"][2].as_f64(), Some(3.5));
        assert_eq!(v["s"].as_str(), Some("q\"\\\né😀"));
        let out = v.to_string();
        assert_eq!(from_str(&out).unwrap(), v);
        assert_eq!(quote("a\u{1}b\u{2028}"), "\"a\\u0001b\\u2028\"");
        assert_eq!(quote("tab\there"), "\"tab\\there\"");
    }

    #[test]
    fn rejects_garbage_and_deep_nesting() {
        assert!(from_str("{\"a\":1,}").is_err());
        assert!(from_str("[1 2]").is_err());
        assert!(from_str("\"raw\ncontrol\"").is_err());
        assert!(from_str("1 x").is_err());
        let deep = "[".repeat(MAX_DEPTH + 2) + &"]".repeat(MAX_DEPTH + 2);
        assert!(from_str(&deep).is_err());
        let ok = "[".repeat(10) + &"]".repeat(10);
        assert!(from_str(&ok).is_ok());
    }

    #[test]
    fn macro_and_index() {
        let n = 5u64;
        let mut v = json!({"a": n, "b": "x", "c": json!({})});
        v["d"] = json!(true);
        assert_eq!(v.to_string(), r#"{"a":5,"b":"x","c":{},"d":true}"#);
        assert!(v["missing"].is_null());
    }
}
