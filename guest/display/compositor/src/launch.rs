//! Which desktop entry a window's process was launched from, for `window.create`'s
//! `desktop_id` (docs/display.md, "Windows and launches").
//!
//! A launch marks the process it starts through its environment, which every process it
//! starts inherits: GLib sets `GIO_LAUNCHED_DESKTOP_FILE` and `GIO_LAUNCHED_DESKTOP_FILE_PID`
//! (the pid it launched) for any desktop entry it launches, and Caboose's own launcher adds
//! `CABOOSE_DESKTOP_ID`, the entry's id. So a window opened through a wrapper script, by a
//! game's launcher or by a process that renamed its window class still names the entry it
//! was launched from. A process that cleared its environment is found through its ancestors.
//!
//! The same inheritance would claim a program started from a launched terminal's shell for
//! the terminal. A window therefore belongs to the launch only when no process between it
//! and the launched process has a window of its own.

use std::collections::HashSet;

/// How far up a window's process lineage the launch marks are looked for.
const DEPTH: usize = 16;

/// A desktop id as entries are named: `<reverse-DNS or name>.desktop`, no path.
fn valid(id: &str) -> bool {
    id.len() <= 255
        && id.len() > ".desktop".len()
        && id.ends_with(".desktop")
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-+@".contains(&b))
}

/// One variable's value from a NUL-separated environment block.
fn variable<'a>(environ: &'a [u8], name: &str) -> Option<&'a str> {
    environ.split(|&b| b == 0).find_map(|entry| {
        let rest = entry.strip_prefix(name.as_bytes())?.strip_prefix(b"=")?;
        std::str::from_utf8(rest).ok()
    })
}

/// The desktop id a launch marked `environ` with, and the pid it launched.
fn marks(environ: &[u8]) -> Option<(String, Option<u32>)> {
    let id = variable(environ, "CABOOSE_DESKTOP_ID")
        .filter(|id| valid(id))
        .map(str::to_owned)
        .or_else(|| {
            let file = variable(environ, "GIO_LAUNCHED_DESKTOP_FILE")?;
            let name = file.rsplit('/').next()?;
            valid(name).then(|| name.to_owned())
        })?;
    let launched = variable(environ, "GIO_LAUNCHED_DESKTOP_FILE_PID").and_then(|p| p.parse().ok());
    Some((id, launched))
}

/// The desktop entry the window of the process `lineage[0]` (its ancestors after it) was
/// launched from. `windowed` are the processes that own other windows; `environ` reads a
/// process's environment.
pub fn desktop_id(lineage: &[u32], windowed: &HashSet<u32>, environ: impl Fn(u32) -> Option<Vec<u8>>) -> Option<String> {
    let (marked, (id, launched)) =
        lineage.iter().take(DEPTH).enumerate().find_map(|(i, &pid)| Some((i, marks(&environ(pid)?)?)))?;
    // Up to the launched process when it is an ancestor; else the one that carries the marks.
    let end = launched.and_then(|l| lineage.iter().position(|&p| p == l)).unwrap_or(marked);
    let between = lineage.get(1..=end).unwrap_or_default();
    (!between.iter().any(|pid| windowed.contains(pid))).then_some(id)
}

/// A process's environment, when it is readable (a process of the compositor's own user).
pub fn read_environ(pid: u32) -> Option<Vec<u8>> {
    std::fs::read(format!("/proc/{pid}/environ")).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(vars: &[(&str, &str)]) -> Vec<u8> {
        vars.iter().flat_map(|(k, v)| format!("{k}={v}\0").into_bytes()).collect()
    }

    fn with(table: &HashMap<u32, Vec<u8>>) -> impl Fn(u32) -> Option<Vec<u8>> + '_ {
        move |pid| table.get(&pid).cloned()
    }

    #[test]
    fn a_game_behind_wrapper_scripts_names_its_launch() {
        // launch.py (100) exec'd stdbuf and launch.sh, which started vkquake (101).
        let marked = env(&[
            ("PATH", "/usr/bin"),
            ("GIO_LAUNCHED_DESKTOP_FILE", "/usr/share/applications/org.example.Game.desktop"),
            ("GIO_LAUNCHED_DESKTOP_FILE_PID", "100"),
            ("CABOOSE_DESKTOP_ID", "org.example.Game.desktop"),
        ]);
        let table = HashMap::from([(101, marked.clone()), (100, marked)]);
        assert_eq!(desktop_id(&[101, 100, 1], &HashSet::new(), with(&table)), Some("org.example.Game.desktop".into()));
    }

    #[test]
    fn glib_alone_names_the_entry_file() {
        let table = HashMap::from([(7, env(&[("GIO_LAUNCHED_DESKTOP_FILE", "/x/apps/org.gnome.TextEditor.desktop")]))]);
        assert_eq!(desktop_id(&[7, 1], &HashSet::new(), with(&table)), Some("org.gnome.TextEditor.desktop".into()));
    }

    #[test]
    fn a_process_that_cleared_its_environment_is_found_through_its_parent() {
        let table = HashMap::from([
            (201, env(&[("HOME", "/home/caboose")])),
            (200, env(&[("CABOOSE_DESKTOP_ID", "org.example.Game.desktop"), ("GIO_LAUNCHED_DESKTOP_FILE_PID", "200")])),
        ]);
        assert_eq!(desktop_id(&[201, 200, 1], &HashSet::new(), with(&table)), Some("org.example.Game.desktop".into()));
    }

    #[test]
    fn a_program_started_from_a_launched_terminal_is_not_the_terminal() {
        // The terminal (300) has a window; its shell (301) started an editor (302).
        let terminal = env(&[("CABOOSE_DESKTOP_ID", "xfce4-terminal.desktop"), ("GIO_LAUNCHED_DESKTOP_FILE_PID", "300")]);
        let table = HashMap::from([(302, terminal.clone()), (301, terminal.clone()), (300, terminal)]);
        let windowed = HashSet::from([300]);
        assert_eq!(desktop_id(&[302, 301, 300, 1], &windowed, with(&table)), None);
        // The terminal's own window is the terminal's.
        assert_eq!(desktop_id(&[300, 1], &windowed, with(&table)), Some("xfce4-terminal.desktop".into()));
    }

    #[test]
    fn unmarked_or_malformed_ids_name_nothing() {
        let table = HashMap::from([
            (1, env(&[("PATH", "/bin")])),
            (2, env(&[("CABOOSE_DESKTOP_ID", "../../etc/passwd")])),
            (3, env(&[("GIO_LAUNCHED_DESKTOP_FILE", "/tmp/notes.txt")])),
        ]);
        for pid in [1, 2, 3] {
            assert_eq!(desktop_id(&[pid], &HashSet::new(), with(&table)), None);
        }
        assert_eq!(desktop_id(&[9], &HashSet::new(), with(&table)), None);
    }
}
