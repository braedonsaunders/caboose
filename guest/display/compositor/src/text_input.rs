//! text-input-v3, implemented here rather than with Smithay's, which routes everything
//! through an input-method-v2 client. Caboose's input method is the phone's keyboard:
//! the compositor needs to know when a focused surface enables text input (to show the
//! keyboard) and to send commits, pre-edit text and deletions straight to it.

use crate::state::State;
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::{
    zwp_text_input_manager_v3::{self, ZwpTextInputManagerV3},
    zwp_text_input_v3::{self, ContentPurpose, ZwpTextInputV3},
};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, WEnum,
};
use std::sync::Mutex;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Default, PartialEq)]
struct Pending {
    enabled: bool,
    surrounding: Option<(String, u32, u32)>,
    purpose: Option<ContentPurpose>,
}

#[derive(Debug, Default)]
pub struct InputData {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    pending: Pending,
    current: Pending,
    /// Number of commit requests, echoed in `done`.
    serial: u32,
    entered: Option<WlSurface>,
}

#[derive(Default)]
pub struct TextInputs {
    inputs: Vec<ZwpTextInputV3>,
}

/// A text-input object enabled or disabled on a surface.
pub struct Toggle {
    pub surface: WlSurface,
    pub enabled: bool,
    pub purpose: Option<&'static str>,
}

pub fn purpose_name(p: ContentPurpose) -> &'static str {
    match p {
        ContentPurpose::Normal => "normal",
        ContentPurpose::Alpha => "alpha",
        ContentPurpose::Digits => "digits",
        ContentPurpose::Number => "number",
        ContentPurpose::Phone => "phone",
        ContentPurpose::Url => "url",
        ContentPurpose::Email => "email",
        ContentPurpose::Name => "name",
        ContentPurpose::Password => "password",
        ContentPurpose::Pin => "pin",
        ContentPurpose::Date => "date",
        ContentPurpose::Time => "time",
        ContentPurpose::Datetime => "datetime",
        ContentPurpose::Terminal => "terminal",
        _ => "normal",
    }
}

/// UTF-8 byte lengths of `before` grapheme clusters before the cursor and `after`
/// after it, as `delete_surrounding_text` wants them.
pub fn grapheme_bytes(text: &str, cursor: usize, before: u32, after: u32) -> (u32, u32) {
    let cursor = cursor.min(text.len());
    let cursor = (0..=cursor).rev().find(|i| text.is_char_boundary(*i)).unwrap_or(0);
    let (head, tail) = text.split_at(cursor);
    let b: usize = head.graphemes(true).rev().take(before as usize).map(str::len).sum();
    let a: usize = tail.graphemes(true).take(after as usize).map(str::len).sum();
    (b as u32, a as u32)
}

impl TextInputs {
    pub fn new(dh: &DisplayHandle) -> Self {
        dh.create_global::<State, ZwpTextInputManagerV3, _>(1, ());
        Self::default()
    }

    fn live(&mut self) -> impl Iterator<Item = &ZwpTextInputV3> {
        self.inputs.retain(|i| i.is_alive());
        self.inputs.iter()
    }

    /// Moves text-input focus with keyboard focus: `leave` for the old surface,
    /// `enter` on every object of the new surface's client.
    pub fn set_focus(&mut self, surface: Option<&WlSurface>) -> Vec<Toggle> {
        let mut toggles = Vec::new();
        for input in self.live().cloned().collect::<Vec<_>>() {
            let data = input.data::<InputData>().unwrap();
            let mut inner = data.inner.lock().unwrap();
            if let Some(old) = inner.entered.take() {
                if Some(&old) != surface {
                    if old.is_alive() {
                        input.leave(&old);
                    }
                    if inner.current.enabled {
                        toggles.push(Toggle { surface: old, enabled: false, purpose: None });
                    }
                    inner.current = Pending::default();
                } else {
                    inner.entered = Some(old);
                    continue;
                }
            }
            if let Some(s) = surface {
                if s.client().map(|c| c.id()) == input.client().map(|c| c.id()) {
                    input.enter(s);
                    inner.entered = Some(s.clone());
                }
            }
        }
        toggles
    }

    fn enabled_on(&mut self, surface: &WlSurface) -> Vec<ZwpTextInputV3> {
        self.live()
            .filter(|i| {
                let inner = i.data::<InputData>().unwrap().inner.lock().unwrap();
                inner.current.enabled && inner.entered.as_ref() == Some(surface)
            })
            .cloned()
            .collect()
    }

    /// Sends one atomic text change to the surface's enabled text inputs. Returns false
    /// if there were none (the caller falls back to key presses).
    pub fn send(
        &mut self,
        surface: &WlSurface,
        commit: Option<&str>,
        preedit: Option<(&str, i32, i32)>,
        delete: (u32, u32),
    ) -> bool {
        let inputs = self.enabled_on(surface);
        for input in &inputs {
            let mut inner = input.data::<InputData>().unwrap().inner.lock().unwrap();
            if delete != (0, 0) {
                let (before, after) = match &inner.current.surrounding {
                    Some((text, cursor, _)) => grapheme_bytes(text, *cursor as usize, delete.0, delete.1),
                    // Without surrounding text there is nothing to convert from; the
                    // count is the best estimate of the byte length for ASCII text.
                    None => delete,
                };
                input.delete_surrounding_text(before, after);
            }
            if let Some((text, begin, end)) = preedit {
                input.preedit_string(Some(text.to_owned()), begin, end);
            }
            if let Some(text) = commit {
                input.commit_string(Some(text.to_owned()));
            }
            input.done(inner.serial);
            // Applied text changes the surrounding text the client will report next.
            inner.current.surrounding = None;
        }
        !inputs.is_empty()
    }

    /// Whether the surface reported surrounding text (so deletions are exact).
    pub fn has_surrounding(&mut self, surface: &WlSurface) -> bool {
        self.enabled_on(surface)
            .iter()
            .any(|i| i.data::<InputData>().unwrap().inner.lock().unwrap().current.surrounding.is_some())
    }
}

impl GlobalDispatch<ZwpTextInputManagerV3, ()> for State {
    fn bind(
        _: &mut State,
        _: &DisplayHandle,
        _: &Client,
        resource: New<ZwpTextInputManagerV3>,
        _: &(),
        data_init: &mut DataInit<'_, State>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwpTextInputManagerV3, ()> for State {
    fn request(
        state: &mut State,
        _: &Client,
        _: &ZwpTextInputManagerV3,
        request: zwp_text_input_manager_v3::Request,
        _: &(),
        _: &DisplayHandle,
        data_init: &mut DataInit<'_, State>,
    ) {
        if let zwp_text_input_manager_v3::Request::GetTextInput { id, .. } = request {
            let input = data_init.init(id, InputData::default());
            // A text input created while its client has keyboard focus enters at once.
            if let Some(focus) = state.keyboard_focus_surface() {
                if focus.client().map(|c| c.id()) == input.client().map(|c| c.id()) {
                    input.enter(&focus);
                    input.data::<InputData>().unwrap().inner.lock().unwrap().entered = Some(focus);
                }
            }
            state.text_inputs.inputs.push(input);
        }
    }
}

impl Dispatch<ZwpTextInputV3, InputData> for State {
    fn request(
        state: &mut State,
        _: &Client,
        resource: &ZwpTextInputV3,
        request: zwp_text_input_v3::Request,
        data: &InputData,
        _: &DisplayHandle,
        _: &mut DataInit<'_, State>,
    ) {
        use zwp_text_input_v3::Request;
        let toggle = {
            let mut inner = data.inner.lock().unwrap();
            match request {
                Request::Enable => {
                    // enable resets the state to defaults before the new values arrive.
                    inner.pending = Pending { enabled: true, ..Pending::default() };
                    None
                }
                Request::Disable => {
                    inner.pending = Pending::default();
                    None
                }
                Request::SetSurroundingText { text, cursor, anchor } => {
                    inner.pending.surrounding = Some((text, cursor.max(0) as u32, anchor.max(0) as u32));
                    None
                }
                Request::SetContentType { purpose, .. } => {
                    if let WEnum::Value(p) = purpose {
                        inner.pending.purpose = Some(p);
                    }
                    None
                }
                Request::Commit => {
                    inner.serial = inner.serial.wrapping_add(1);
                    let was = inner.current.enabled;
                    let old_purpose = inner.current.purpose;
                    inner.current = inner.pending.clone();
                    let now = inner.current.enabled;
                    let changed = was != now || (now && old_purpose != inner.current.purpose);
                    match (&inner.entered, changed) {
                        (Some(surface), true) => Some(Toggle {
                            surface: surface.clone(),
                            enabled: now,
                            purpose: inner.current.purpose.map(purpose_name),
                        }),
                        _ => None,
                    }
                }
                Request::SetTextChangeCause { .. } | Request::SetCursorRectangle { .. } | Request::Destroy => None,
                _ => None,
            }
        };
        let _ = resource;
        if let Some(t) = toggle {
            state.on_text_input_toggle(t);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grapheme_counts_become_byte_lengths() {
        // "e" + combining acute is one grapheme of 3 bytes; the flag is one of 8.
        let text = "cafe\u{301} 🇨🇦|end";
        let cursor = text.find('|').unwrap();
        assert_eq!(grapheme_bytes(text, cursor, 1, 0), (8, 0));
        assert_eq!(grapheme_bytes(text, cursor, 3, 0), (8 + 1 + 3, 0));
        assert_eq!(grapheme_bytes(text, cursor, 0, 2), (0, 2));
    }

    #[test]
    fn deleting_past_the_ends_stops_there() {
        assert_eq!(grapheme_bytes("ab", 1, 5, 5), (1, 1));
        assert_eq!(grapheme_bytes("ab", 99, 1, 1), (1, 0));
    }

    #[test]
    fn a_cursor_inside_a_character_moves_to_its_start() {
        let text = "é!";
        assert_eq!(grapheme_bytes(text, 1, 1, 0), (0, 0));
    }

    #[test]
    fn purposes_have_protocol_names() {
        assert_eq!(purpose_name(ContentPurpose::Terminal), "terminal");
        assert_eq!(purpose_name(ContentPurpose::Password), "password");
    }
}
