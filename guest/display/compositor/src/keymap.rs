//! Keysym → keycode for injected keys.
//!
//! The client sends keysyms (what the key means); Wayland and X11 clients receive
//! keycodes interpreted through the seat's keymap. This table maps each keysym the
//! keymap can produce to the keycode and the level it sits on, so a key that needs
//! Shift can be typed with Shift held.

use smithay::input::keyboard::xkb;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyPosition {
    /// xkb keycode (evdev + 8).
    pub keycode: u32,
    /// Shift selects this level.
    pub shift: bool,
}

#[derive(Debug, Default)]
pub struct Keysyms {
    map: HashMap<u32, KeyPosition>,
}

pub mod sym {
    pub const SHIFT_L: u32 = 0xffe1;
    pub const CONTROL_L: u32 = 0xffe3;
    pub const ALT_L: u32 = 0xffe9;
    pub const SUPER_L: u32 = 0xffeb;
    pub const BACKSPACE: u32 = 0xff08;
    pub const DELETE: u32 = 0xffff;
    pub const RETURN: u32 = 0xff0d;
    pub const TAB: u32 = 0xff09;
}

impl Keysyms {
    /// Builds the table from `(keycode, level, keysym)` triples. The first position
    /// found for a keysym wins, and level 0 is preferred over level 1, so `1` maps to
    /// the main row rather than the keypad and `a` needs no Shift.
    pub fn from_entries(entries: impl IntoIterator<Item = (u32, u32, u32)>) -> Self {
        let mut map: HashMap<u32, KeyPosition> = HashMap::new();
        for (keycode, level, keysym) in entries {
            if level > 1 || keysym == 0 {
                continue;
            }
            let pos = KeyPosition { keycode, shift: level == 1 };
            match map.get(&keysym) {
                Some(existing) if !existing.shift || pos.shift => {}
                _ => {
                    map.insert(keysym, pos);
                }
            }
        }
        Self { map }
    }

    pub fn from_keymap(keymap: &xkb::Keymap) -> Self {
        let mut entries = Vec::new();
        let min = keymap.min_keycode().raw();
        let max = keymap.max_keycode().raw();
        for code in min..=max {
            let keycode = xkb::Keycode::new(code);
            let levels = keymap.num_levels_for_key(keycode, 0);
            for level in 0..levels.min(2) {
                for sym in keymap.key_get_syms_by_level(keycode, 0, level) {
                    entries.push((code, level, sym.raw()));
                }
            }
        }
        Self::from_entries(entries)
    }

    pub fn lookup(&self, keysym: u32) -> Option<KeyPosition> {
        self.map.get(&keysym).copied()
    }
}

/// The keysym for a character, for typing text into clients without text-input-v3.
pub fn char_to_keysym(c: char) -> u32 {
    match c {
        '\n' | '\r' => sym::RETURN,
        '\t' => sym::TAB,
        '\u{8}' => sym::BACKSPACE,
        c => xkb::utf32_to_keysym(c as u32).raw(),
    }
}

/// The keysym for a protocol modifier name.
pub fn modifier_keysym(name: &str) -> Option<u32> {
    Some(match name {
        "shift" => sym::SHIFT_L,
        "control" => sym::CONTROL_L,
        "mod1" => sym::ALT_L,
        "mod4" => sym::SUPER_L,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn us() -> Keysyms {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_names(&context, "evdev", "pc105", "us", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS)
            .expect("the us keymap compiles");
        Keysyms::from_keymap(&keymap)
    }

    #[test]
    fn letters_and_shifted_symbols_on_the_us_layout() {
        let k = us();
        // KEY_A is evdev 30, xkb 38.
        assert_eq!(k.lookup('a' as u32), Some(KeyPosition { keycode: 38, shift: false }));
        assert_eq!(k.lookup('A' as u32), Some(KeyPosition { keycode: 38, shift: true }));
        assert_eq!(k.lookup('!' as u32), Some(KeyPosition { keycode: 10, shift: true }));
        assert_eq!(k.lookup(sym::RETURN).map(|p| p.keycode), Some(36));
        assert!(k.lookup(0x00e9).is_none(), "é is not on the us layout");
    }

    #[test]
    fn the_main_row_wins_over_the_keypad() {
        // '1' is on the main row (level 0) and on KP_1 only through NumLock.
        let k = us();
        assert_eq!(k.lookup('1' as u32).map(|p| p.keycode), Some(10));
    }

    #[test]
    fn unshifted_positions_are_preferred() {
        let k = Keysyms::from_entries([(50, 1, 0x41), (60, 0, 0x41)]);
        assert_eq!(k.lookup(0x41), Some(KeyPosition { keycode: 60, shift: false }));
    }

    #[test]
    fn characters_map_to_keysyms() {
        assert_eq!(char_to_keysym('a'), 0x61);
        assert_eq!(char_to_keysym('\n'), sym::RETURN);
        assert_eq!(char_to_keysym('é'), 0x00e9);
        assert_eq!(modifier_keysym("mod4"), Some(sym::SUPER_L));
    }
}
