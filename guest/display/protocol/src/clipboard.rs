//! What a `clipboard` may carry (docs/display.md, Clipboard): its types, its limits, and
//! the checks both peers apply before they trust a representation.

use crate::Clipboard;

/// UTF-8 text, the type every client takes.
pub const TEXT: &str = "text/plain;charset=utf-8";
pub const PNG: &str = "image/png";
pub const JPEG: &str = "image/jpeg";
/// Files, as `file://` URIs (RFC 2483), one per line.
pub const URI_LIST: &str = "text/uri-list";
/// Every type a `clipboard` carries, in the order a sender lists them.
pub const TYPES: &[&str] = &[TEXT, PNG, JPEG, URI_LIST];

/// The most one `clipboard` carries, every representation together.
pub const MAX_BYTES: usize = 12 * 1024 * 1024;
/// The most text in one copy.
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
/// The most a list of files may take.
pub const MAX_URI_LIST_BYTES: usize = 256 * 1024;
/// The most files one copy names.
pub const MAX_FILES: usize = 64;

/// Why a `clipboard` was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// A type outside [`TYPES`].
    UnknownType,
    /// The same type twice.
    Duplicate,
    /// More than [`MAX_BYTES`] together, or one representation over its own limit.
    TooLarge,
    /// The bytes are not what the type says (an image without its signature, text that
    /// is not UTF-8, a list of files that is not `file://` URIs of absolute paths).
    Malformed,
}

/// Whether `data` is what `mime` says it is.
pub fn matches(mime: &str, data: &[u8]) -> Result<(), Refusal> {
    match mime {
        TEXT => {
            if data.len() > MAX_TEXT_BYTES {
                return Err(Refusal::TooLarge);
            }
            std::str::from_utf8(data).map(|_| ()).map_err(|_| Refusal::Malformed)
        }
        PNG => data.starts_with(b"\x89PNG\r\n\x1a\n").then_some(()).ok_or(Refusal::Malformed),
        JPEG => data.starts_with(&[0xff, 0xd8, 0xff]).then_some(()).ok_or(Refusal::Malformed),
        URI_LIST => {
            if data.len() > MAX_URI_LIST_BYTES {
                return Err(Refusal::TooLarge);
            }
            file_paths(data).map(|_| ())
        }
        _ => Err(Refusal::UnknownType),
    }
}

/// Checks a whole `clipboard`: known types, each once, each what it says, within
/// [`MAX_BYTES`] together.
pub fn validate(c: &Clipboard) -> Result<(), Refusal> {
    if c.total_len() > MAX_BYTES {
        return Err(Refusal::TooLarge);
    }
    let mut seen: Vec<&str> = Vec::new();
    for (mime, data) in c.entries() {
        if seen.contains(&mime) {
            return Err(Refusal::Duplicate);
        }
        seen.push(mime);
        matches(mime, data)?;
    }
    Ok(())
}

/// The absolute paths of a `text/uri-list`: every line that is not a comment must be a
/// `file://` URI with an empty or `localhost` host, whose percent-decoded path is
/// absolute UTF-8 without NUL. At least one and at most [`MAX_FILES`].
pub fn file_paths(data: &[u8]) -> Result<Vec<String>, Refusal> {
    let text = std::str::from_utf8(data).map_err(|_| Refusal::Malformed)?;
    let mut paths = Vec::new();
    for line in text.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let rest = line.strip_prefix("file://").ok_or(Refusal::Malformed)?;
        let path = rest.strip_prefix("localhost").unwrap_or(rest);
        if !path.starts_with('/') {
            return Err(Refusal::Malformed);
        }
        let decoded = percent_decode(path).ok_or(Refusal::Malformed)?;
        if decoded.contains('\0') {
            return Err(Refusal::Malformed);
        }
        paths.push(decoded);
        if paths.len() > MAX_FILES {
            return Err(Refusal::TooLarge);
        }
    }
    if paths.is_empty() {
        return Err(Refusal::Malformed);
    }
    Ok(paths)
}

/// A `text/uri-list` naming `paths`, each line ending in CRLF as RFC 2483 says.
pub fn uri_list(paths: &[&str]) -> Vec<u8> {
    let mut out = String::new();
    for path in paths {
        out.push_str("file://");
        out.push_str(&percent_encode(path));
        out.push_str("\r\n");
    }
    out.into_bytes()
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Percent-encodes everything but RFC 3986's unreserved characters and `/`.
fn percent_encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for &b in path.as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ClipboardEntry;

    fn clip(entries: &[(&str, &[u8])]) -> Clipboard {
        let (first, rest) = entries.split_first().unwrap();
        Clipboard {
            mime: first.0.into(),
            data: first.1.to_vec(),
            alternatives: rest.iter().map(|(m, d)| ClipboardEntry { mime: (*m).into(), data: d.to_vec() }).collect(),
        }
    }

    const PNG_BYTES: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    #[test]
    fn text_and_an_image_together_are_accepted() {
        assert_eq!(validate(&clip(&[(TEXT, "héllo".as_bytes()), (PNG, PNG_BYTES)])), Ok(()));
        assert_eq!(validate(&clip(&[(JPEG, &[0xff, 0xd8, 0xff, 0xe0])])), Ok(()));
    }

    #[test]
    fn an_image_must_carry_its_signature() {
        assert_eq!(validate(&clip(&[(PNG, b"GIF89a")])), Err(Refusal::Malformed));
        assert_eq!(validate(&clip(&[(JPEG, PNG_BYTES)])), Err(Refusal::Malformed));
    }

    #[test]
    fn unknown_and_repeated_types_are_refused() {
        assert_eq!(validate(&clip(&[("text/html", b"<b>x</b>")])), Err(Refusal::UnknownType));
        assert_eq!(validate(&clip(&[(TEXT, b"a"), (TEXT, b"b")])), Err(Refusal::Duplicate));
    }

    #[test]
    fn text_must_be_utf8_and_bounded() {
        assert_eq!(validate(&clip(&[(TEXT, &[0xff, 0xfe])])), Err(Refusal::Malformed));
        assert_eq!(validate(&clip(&[(TEXT, &vec![b'a'; MAX_TEXT_BYTES + 1])])), Err(Refusal::TooLarge));
    }

    #[test]
    fn the_limit_is_for_every_representation_together() {
        let mut half = PNG_BYTES.to_vec();
        half.resize(MAX_BYTES / 2 + 1, 0);
        let mut jpeg = vec![0xff, 0xd8, 0xff];
        jpeg.resize(MAX_BYTES / 2 + 1, 0);
        assert_eq!(validate(&clip(&[(PNG, &half), (JPEG, &jpeg)])), Err(Refusal::TooLarge));
    }

    #[test]
    fn uri_lists_name_absolute_files() {
        let list = b"# copied\r\nfile:///home/caboose/a%20b.txt\r\nfile://localhost/tmp/%C3%A9\r\n";
        assert_eq!(file_paths(list).unwrap(), vec!["/home/caboose/a b.txt".to_string(), "/tmp/é".to_string()]);
        assert_eq!(file_paths(b"https://example.com/\r\n"), Err(Refusal::Malformed));
        assert_eq!(file_paths(b"file://server/share/x\r\n"), Err(Refusal::Malformed));
        assert_eq!(file_paths(b"file:///a%00b\r\n"), Err(Refusal::Malformed));
        assert_eq!(file_paths(b"file:///a%zz\r\n"), Err(Refusal::Malformed));
        assert_eq!(file_paths(b"# nothing\r\n"), Err(Refusal::Malformed));
        let many: String = (0..=MAX_FILES).map(|i| format!("file:///f{i}\r\n")).collect();
        assert_eq!(file_paths(many.as_bytes()), Err(Refusal::TooLarge));
    }

    #[test]
    fn uri_lists_round_trip() {
        let paths = ["/home/caboose/Report #1 (final).pdf", "/home/caboose/naïve.txt"];
        let list = uri_list(&paths);
        assert_eq!(
            std::str::from_utf8(&list).unwrap(),
            "file:///home/caboose/Report%20%231%20%28final%29.pdf\r\nfile:///home/caboose/na%C3%AFve.txt\r\n"
        );
        assert_eq!(file_paths(&list).unwrap(), paths.map(String::from).to_vec());
    }
}
