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
    /// Builds the table from `(keycode, level, keysym)` triples. Among the positions
    /// of a keysym the best is a keycode X11 can carry (≤ 255; Xwayland drops the
    /// rest, such as KEY_DOLLAR's 442), then the unshifted level, then the lowest
    /// keycode, so `$` is Shift+4, `1` is on the main row and `a` needs no Shift.
    pub fn from_entries(entries: impl IntoIterator<Item = (u32, u32, u32)>) -> Self {
        let rank = |p: &KeyPosition| (p.keycode > 255, p.shift, p.keycode);
        let mut map: HashMap<u32, KeyPosition> = HashMap::new();
        for (keycode, level, keysym) in entries {
            if level > 1 || keysym == 0 {
                continue;
            }
            let pos = KeyPosition { keycode, shift: level == 1 };
            if map.get(&keysym).is_none_or(|existing| rank(&pos) < rank(existing)) {
                map.insert(keysym, pos);
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

/// USB HID keyboard-page usage to xkb keycode (Linux evdev code plus 8).
/// Unsupported usages fall back to the keysym. Zero entries are reserved.
pub fn physical_keycode(usage: u32) -> Option<u32> {
    // USB HID usage table, keyboard page; values are Linux input-event codes.
    const KEYS: [u16; 164] = [
        0,0,0,0,30,48,46,32,18,33,34,35,23,36,37,38,
        50,49,24,25,16,19,31,20,22,47,17,45,21,44,2,3,
        4,5,6,7,8,9,10,11,28,1,14,15,57,12,13,26,
        27,43,43,39,40,41,51,52,53,58,59,60,61,62,63,64,
        65,66,67,68,87,88,99,70,119,110,102,104,111,107,109,106,
        105,108,103,69,98,55,74,78,96,79,80,81,75,76,77,71,
        72,73,82,83,86,127,116,117,183,184,185,186,187,188,189,190,
        191,192,193,194,134,138,130,132,128,129,131,137,133,135,136,113,
        115,114,0,0,0,121,0,89,93,124,92,94,95,0,0,0,
        122,123,90,91,85,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,
    ];
    let evdev = match usage {
        0xe0..=0xe7 => [29,42,56,125,97,54,100,126][(usage - 0xe0) as usize],
        _ => *KEYS.get(usage as usize)? as u32,
    };
    (evdev != 0).then_some(evdev + 8)
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
        let keymap =
            xkb::Keymap::new_from_names(&context, "evdev", "pc105", "us", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS)
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
    fn x11_keycodes_beat_unshifted_ones_above_255() {
        let k = us();
        assert_eq!(k.lookup('$' as u32), Some(KeyPosition { keycode: 13, shift: true }));
        let k = Keysyms::from_entries([(442, 0, 0x24), (13, 1, 0x24)]);
        assert_eq!(k.lookup(0x24), Some(KeyPosition { keycode: 13, shift: true }));
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

#[cfg(test)]
mod physical_tests {
    use super::physical_keycode;
    #[test]
    fn maps_hid_positions_and_rejects_reserved() {
        assert_eq!(physical_keycode(4), Some(38)); // A position
        assert_eq!(physical_keycode(26), Some(25)); // W position
        assert_eq!(physical_keycode(0xe4), Some(105)); // right control
        assert_eq!(physical_keycode(0), None);
        assert_eq!(physical_keycode(u32::MAX), None);
    }
}
