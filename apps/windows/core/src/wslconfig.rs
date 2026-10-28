//! `%UserProfile%\.wslconfig`, WSL's settings for every distribution of a user. Caboose
//! changes one key, `[wsl2] networkingMode`, and keeps every other line exactly as written:
//! other keys, comments, blank lines, key spelling and line endings.

/// The section and key Caboose manages.
pub const SECTION: &str = "wsl2";
pub const NETWORKING_MODE: &str = "networkingMode";
pub const MIRRORED: &str = "mirrored";

/// The file's text from its bytes: UTF-8 (with or without a byte order mark) or UTF-16 with a
/// byte order mark, as editors on Windows write it.
pub fn decode(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        let units: Vec<u16> = rest.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
        return String::from_utf16_lossy(&units);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let units: Vec<u16> = rest.chunks_exact(2).map(|pair| u16::from_be_bytes([pair[0], pair[1]])).collect();
        return String::from_utf16_lossy(&units);
    }
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    String::from_utf8_lossy(bytes).into_owned()
}

enum Line<'a> {
    Section(String),
    Entry { key: &'a str },
    Other,
}

fn classify(line: &str) -> Line<'_> {
    let trimmed = line.trim();
    if trimmed.starts_with('[') {
        if let Some(end) = trimmed.find(']') {
            return Line::Section(trimmed[1..end].trim().to_ascii_lowercase());
        }
    }
    if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
        return Line::Other;
    }
    match line.split_once('=') {
        Some((key, _)) if !key.trim().is_empty() => Line::Entry { key: key.trim() },
        _ => Line::Other,
    }
}

/// The value part of a `key = value  # comment` line, without the comment.
fn value_of(line: &str) -> &str {
    let value = line.split_once('=').map(|(_, value)| value).unwrap_or("");
    strip_comment(value).0.trim()
}

/// Splits a value from a trailing ` # comment` or ` ; comment`, keeping the comment's spacing.
fn strip_comment(value: &str) -> (&str, &str) {
    let bytes = value.as_bytes();
    for (index, &byte) in bytes.iter().enumerate() {
        if (byte == b'#' || byte == b';') && index > 0 && bytes[index - 1].is_ascii_whitespace() {
            let start = value[..index].trim_end().len();
            return (&value[..start], &value[start..]);
        }
    }
    (value, "")
}

/// The value of `key` in `[section]`, matched without regard to case as WSL does; the last
/// one wins when a key is repeated.
pub fn get(text: &str, section: &str, key: &str) -> Option<String> {
    let section = section.to_ascii_lowercase();
    let mut current: Option<String> = None;
    let mut found = None;
    for line in text.lines() {
        match classify(line) {
            Line::Section(name) => current = Some(name),
            Line::Entry { key: name }
                if current.as_deref() == Some(section.as_str()) && name.eq_ignore_ascii_case(key) =>
            {
                found = Some(value_of(line).to_string());
            }
            _ => {}
        }
    }
    found
}

/// The text with `key` in `[section]` set to `value`, or removed when `value` is `None`.
/// An existing key keeps its spelling, indentation, spacing and trailing comment; a new key
/// goes after the last key of the section, and a new section at the end of the file.
pub fn set(text: &str, section: &str, key: &str, value: Option<&str>) -> String {
    let newline = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let section_lower = section.to_ascii_lowercase();
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let mut current: Option<String> = None;
    let mut replaced = false;
    // Where a new key would go: after the section's last key, else after its header.
    let mut insert_at: Option<usize> = None;
    let mut index = 0;
    while index < lines.len() {
        match classify(&lines[index]) {
            Line::Section(name) => {
                let entering = name == section_lower;
                current = Some(name);
                if entering && insert_at.is_none() {
                    insert_at = Some(index + 1);
                }
            }
            Line::Entry { key: name } if current.as_deref() == Some(section_lower.as_str()) => {
                if name.eq_ignore_ascii_case(key) {
                    match value {
                        Some(value) => {
                            lines[index] = replace_value(&lines[index], value);
                            replaced = true;
                        }
                        None => {
                            lines.remove(index);
                            continue;
                        }
                    }
                }
                if insert_at.is_some_and(|at| index >= at.saturating_sub(1)) {
                    insert_at = Some(index + 1);
                }
            }
            _ => {}
        }
        index += 1;
    }
    if let (Some(value), false) = (value, replaced) {
        let entry = format!("{key}={value}");
        match insert_at {
            Some(at) => lines.insert(at, entry),
            None => {
                if lines.last().is_some_and(|line| !line.trim().is_empty()) {
                    lines.push(String::new());
                }
                lines.push(format!("[{section}]"));
                lines.push(entry);
            }
        }
    }
    let mut out = lines.join(newline);
    if !out.is_empty() && (text.ends_with('\n') || text.is_empty() || (value.is_some() && !replaced)) {
        out.push_str(newline);
    }
    out
}

fn replace_value(line: &str, value: &str) -> String {
    let (head, rest) = line.split_once('=').unwrap_or((line, ""));
    let leading = &rest[..rest.len() - rest.trim_start().len()];
    let (_, comment) = strip_comment(rest.trim_start());
    format!("{head}={leading}{value}{comment}")
}

/// Whether the file turns on mirrored networking.
pub fn is_mirrored(text: &str) -> bool {
    get(text, SECTION, NETWORKING_MODE).is_some_and(|mode| mode.eq_ignore_ascii_case(MIRRORED))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_the_section_to_an_empty_file() {
        assert_eq!(set("", "wsl2", "networkingMode", Some("mirrored")), "[wsl2]\nnetworkingMode=mirrored\n");
    }

    #[test]
    fn keeps_every_other_key_and_comment() {
        let before = "# My WSL settings\n[wsl2]\nmemory=16GB  # half the machine\nprocessors=8\n\n[experimental]\nautoMemoryReclaim=gradual\n";
        let after = set(before, "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(
            after,
            "# My WSL settings\n[wsl2]\nmemory=16GB  # half the machine\nprocessors=8\nnetworkingMode=mirrored\n\n[experimental]\nautoMemoryReclaim=gradual\n"
        );
        assert!(is_mirrored(&after));
        assert_eq!(get(&after, "wsl2", "memory").as_deref(), Some("16GB"));
    }

    #[test]
    fn replaces_an_existing_value_in_place_keeping_its_spelling_and_comment() {
        let before = "[WSL2]\n  NetworkingMode = nat ; set by me\nswap=0\n";
        let after = set(before, "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(after, "[WSL2]\n  NetworkingMode = mirrored ; set by me\nswap=0\n");
        assert_eq!(get(before, "wsl2", "networkingmode").as_deref(), Some("nat"));
    }

    #[test]
    fn appends_the_section_when_only_others_exist() {
        let before = "[experimental]\nsparseVhd=true";
        assert_eq!(
            set(before, "wsl2", "networkingMode", Some("mirrored")),
            "[experimental]\nsparseVhd=true\n\n[wsl2]\nnetworkingMode=mirrored\n"
        );
    }

    #[test]
    fn keeps_windows_line_endings() {
        let before = "[wsl2]\r\nmemory=8GB\r\n";
        assert_eq!(
            set(before, "wsl2", "networkingMode", Some("mirrored")),
            "[wsl2]\r\nmemory=8GB\r\nnetworkingMode=mirrored\r\n"
        );
    }

    #[test]
    fn only_touches_the_named_section() {
        let before = "[experimental]\nnetworkingMode=nat\n[wsl2]\n";
        let after = set(before, "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(after, "[experimental]\nnetworkingMode=nat\n[wsl2]\nnetworkingMode=mirrored\n");
    }

    #[test]
    fn inserts_after_the_last_key_not_after_trailing_comments() {
        let before = "[wsl2]\nmemory=8GB\n\n# Other things\n[user]\n";
        assert_eq!(
            set(before, "wsl2", "networkingMode", Some("mirrored")),
            "[wsl2]\nmemory=8GB\nnetworkingMode=mirrored\n\n# Other things\n[user]\n"
        );
    }

    #[test]
    fn removes_the_key_to_restore_a_file_that_had_none() {
        let original = "[wsl2]\nmemory=8GB\n";
        let changed = set(original, "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(set(&changed, "wsl2", "networkingMode", None), original);
    }

    #[test]
    fn restores_a_previous_value() {
        let original = "[wsl2]\nnetworkingMode=nat\n";
        let changed = set(original, "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(set(&changed, "wsl2", "networkingMode", Some("nat")), original);
    }

    #[test]
    fn sets_every_repeat_of_a_key() {
        let after = set("[wsl2]\nnetworkingMode=nat\nnetworkingMode=nat\n", "wsl2", "networkingMode", Some("mirrored"));
        assert_eq!(after, "[wsl2]\nnetworkingMode=mirrored\nnetworkingMode=mirrored\n");
    }

    #[test]
    fn keeps_a_file_without_a_final_newline_that_way() {
        assert_eq!(
            set("[wsl2]\nnetworkingMode=nat", "wsl2", "networkingMode", Some("mirrored")),
            "[wsl2]\nnetworkingMode=mirrored"
        );
    }

    #[test]
    fn decodes_utf8_and_utf16_files() {
        assert_eq!(decode(b"\xEF\xBB\xBF[wsl2]\n"), "[wsl2]\n");
        assert_eq!(decode(b"[wsl2]\n"), "[wsl2]\n");
        let utf16: Vec<u8> =
            [0xFF, 0xFE].into_iter().chain("[wsl2]".encode_utf16().flat_map(u16::to_le_bytes)).collect();
        assert_eq!(decode(&utf16), "[wsl2]");
    }

    #[test]
    fn reads_mirrored_mode() {
        assert!(is_mirrored("[wsl2]\nnetworkingMode=Mirrored\n"));
        assert!(!is_mirrored("[wsl2]\nnetworkingMode=nat\n"));
        assert!(!is_mirrored("[experimental]\nnetworkingMode=mirrored\n"));
        assert!(!is_mirrored(""));
    }
}
