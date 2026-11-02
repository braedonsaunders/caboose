//! The phone's last displays, kept across restarts of the compositor.
//!
//! The output is always the phone's viewport. Between a start and the phone's next hello the
//! compositor keeps the last one it announced, so an application that reads the screen size
//! at its start (a game choosing its resolution) gets the phone's, not `--display`'s.

use caboose_display_protocol::Display;
use std::path::{Path, PathBuf};

/// Where the displays of the instance serving Wayland socket `socket` are kept.
pub fn path(socket: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(Path::new(&home).join(".local/state/caboose").join(format!("{socket}.displays")))
}

/// One line per display: `id width height scale refresh hdr`.
pub fn encode(displays: &[Display]) -> String {
    displays
        .iter()
        .map(|d| format!("{} {} {} {} {} {}\n", d.id, d.width, d.height, d.scale, d.refresh_hz, u8::from(d.hdr)))
        .collect()
}

/// The displays in `text`, or none if any line is not a valid display.
pub fn decode(text: &str) -> Option<Vec<Display>> {
    let displays: Option<Vec<Display>> = text
        .lines()
        .map(|line| {
            let mut f = line.split(' ');
            let display = Display {
                id: f.next()?.parse().ok()?,
                width: f.next()?.parse().ok()?,
                height: f.next()?.parse().ok()?,
                scale: f.next()?.parse().ok()?,
                refresh_hz: f.next()?.parse().ok()?,
                hdr: f.next()? == "1",
            };
            let valid = f.next().is_none() && display.width > 0 && display.height > 0 &&
                display.scale.is_finite() && display.scale > 0.0 && display.refresh_hz.is_finite() && display.refresh_hz > 0.0;
            valid.then_some(display)
        })
        .collect();
    displays.filter(|d| !d.is_empty())
}

pub fn load(socket: &str) -> Option<Vec<Display>> {
    decode(&std::fs::read_to_string(path(socket)?).ok()?)
}

/// Keeps `displays` for the next start; failures only cost that.
pub fn save(socket: &str, displays: &[Display]) {
    let Some(path) = path(socket) else { return };
    let text = encode(displays);
    if decode(&text).is_none() || std::fs::read_to_string(&path).is_ok_and(|old| old == text) {
        return;
    }
    let Some(dir) = path.parent() else { return };
    let temporary = path.with_extension("displays.new");
    let written = std::fs::create_dir_all(dir)
        .and_then(|()| std::fs::write(&temporary, &text))
        .and_then(|()| std::fs::rename(&temporary, &path));
    if let Err(error) = written {
        tracing::warn!("could not keep the phone's displays in {}: {error}", path.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(id: u32, width: i32, height: i32) -> Display {
        Display { id, width, height, scale: 2.0, refresh_hz: 120.0, hdr: false }
    }

    #[test]
    fn displays_round_trip() {
        let displays = vec![display(1, 1902, 1338), Display { hdr: true, scale: 1.4375, ..display(2, 1338, 911) }];
        assert_eq!(decode(&encode(&displays)), Some(displays));
    }

    #[test]
    fn a_damaged_or_empty_file_gives_nothing() {
        assert_eq!(decode(""), None);
        assert_eq!(decode("1 1902 1338 2 120\n"), None);
        assert_eq!(decode("1 0 1338 2 120 0\n"), None);
        assert_eq!(decode("1 1902 1338 2 120 0 extra\n"), None);
        assert_eq!(decode("1 1902 1338 NaN 120 0\n"), None);
    }
}
