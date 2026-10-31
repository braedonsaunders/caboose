//! text-input-v3, implemented here rather than with Smithay's, which routes everything
//! through an input-method-v2 client. Caboose's input method is the phone's keyboard:
//! the compositor needs to know when a focused surface enables text input (to show the
//! keyboard) and to send commits and pre-edit text straight to it, and the phone's
//! keyboard reads the application's surrounding text so it edits with real context.

use crate::state::State;
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::{
    zwp_text_input_manager_v3::{self, ZwpTextInputManagerV3},
    zwp_text_input_v3::{self, ContentHint, ContentPurpose, ZwpTextInputV3},
};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, WEnum,
};
use std::sync::Mutex;

#[derive(Debug, Clone, Default, PartialEq)]
struct Pending {
    enabled: bool,
    purpose: Option<ContentPurpose>,
    /// A password, PIN or other sensitive field: its text never leaves the computer.
    sensitive: bool,
    surrounding: Option<Surrounding>,
}

impl Pending {
    fn shared_surrounding(&self) -> Option<Surrounding> {
        if self.sensitive || matches!(self.purpose, Some(ContentPurpose::Password | ContentPurpose::Pin)) {
            return None;
        }
        self.surrounding.clone()
    }
}

/// set_surrounding_text: the text around the caret, and the caret and selection anchor as
/// byte offsets into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Surrounding {
    pub text: String,
    pub cursor: u32,
    pub anchor: u32,
}

/// text-input-v3 bounds surrounding text to 4000 bytes.
const MAX_SURROUNDING: usize = 4000;

impl Surrounding {
    /// What an application sent, if it is usable: within the protocol's size, offsets on
    /// character boundaries of the text.
    pub(crate) fn new(text: String, cursor: i32, anchor: i32) -> Option<Self> {
        let valid = |offset: i32| offset >= 0 && text.is_char_boundary(offset as usize);
        (text.len() <= MAX_SURROUNDING && valid(cursor) && valid(anchor))
            .then_some(Surrounding { cursor: cursor as u32, anchor: anchor as u32, text })
    }

    pub fn wire(&self) -> caboose_display_protocol::Surrounding {
        caboose_display_protocol::Surrounding { text: self.text.clone(), cursor: self.cursor.into(), anchor: self.anchor.into() }
    }
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

/// A text-input object enabled or disabled on a surface, or its surrounding text changed.
pub struct Toggle {
    pub surface: WlSurface,
    pub enabled: bool,
    pub purpose: Option<&'static str>,
    pub surrounding: Option<Surrounding>,
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
                        toggles.push(Toggle { surface: old, enabled: false, purpose: None, surrounding: None });
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

    /// Sends one atomic text change (a commit and/or pre-edit text) to the surface's
    /// enabled text inputs. Returns false if there were none (the caller types instead).
    pub fn send(&mut self, surface: &WlSurface, commit: Option<&str>, preedit: Option<(&str, i32, i32)>) -> bool {
        let inputs = self.enabled_on(surface);
        for input in &inputs {
            let serial = input.data::<InputData>().unwrap().inner.lock().unwrap().serial;
            if let Some((text, begin, end)) = preedit {
                input.preedit_string(Some(text.to_owned()), begin, end);
            }
            if let Some(text) = commit {
                input.commit_string(Some(text.to_owned()));
            }
            input.done(serial);
        }
        !inputs.is_empty()
    }

    /// The surrounding text `surface`'s enabled text input last reported.
    pub fn surrounding(&mut self, surface: &WlSurface) -> Option<caboose_display_protocol::Surrounding> {
        self.live().find_map(|i| {
            let inner = i.data::<InputData>().unwrap().inner.lock().unwrap();
            (inner.current.enabled && inner.entered.as_ref() == Some(surface))
                .then(|| inner.current.shared_surrounding().as_ref().map(Surrounding::wire))
                .flatten()
        })
    }

    /// The text-input state of `surface` now: `Some(purpose)` when it is enabled.
    pub fn enabled_purpose(&mut self, surface: &WlSurface) -> Option<Option<&'static str>> {
        self.live().find_map(|i| {
            let inner = i.data::<InputData>().unwrap().inner.lock().unwrap();
            (inner.current.enabled && inner.entered.as_ref() == Some(surface))
                .then(|| inner.current.purpose.map(purpose_name))
        })
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
                // The phone's keyboard reads it; deletions still arrive as key presses
                // (see State::text), which every application takes.
                Request::SetSurroundingText { text, cursor, anchor } => {
                    inner.pending.surrounding = Surrounding::new(text, cursor, anchor);
                    None
                }
                Request::SetContentType { hint, purpose } => {
                    if let WEnum::Value(p) = purpose {
                        inner.pending.purpose = Some(p);
                    }
                    inner.pending.sensitive = match hint {
                        WEnum::Value(h) => h.intersects(ContentHint::SensitiveData | ContentHint::HiddenText),
                        WEnum::Unknown(_) => true,
                    };
                    None
                }
                Request::Commit => {
                    inner.serial = inner.serial.wrapping_add(1);
                    let was = inner.current.enabled;
                    let old_purpose = inner.current.purpose;
                    let old_surrounding = inner.current.shared_surrounding();
                    // Pending state stays as set until the next enable, so a commit without
                    // new surrounding text keeps the last.
                    inner.current = inner.pending.clone();
                    let now = inner.current.enabled;
                    let changed = was != now
                        || (now && old_purpose != inner.current.purpose)
                        || (now && old_surrounding != inner.current.shared_surrounding());
                    match (&inner.entered, changed) {
                        (Some(surface), true) => Some(Toggle {
                            surface: surface.clone(),
                            enabled: now,
                            purpose: inner.current.purpose.map(purpose_name),
                            surrounding: if now { inner.current.shared_surrounding() } else { None },
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
    fn surrounding_text_must_fit_and_land_on_characters() {
        let s = Surrounding::new("Héllo".into(), 3, 1).unwrap();
        assert_eq!((s.cursor, s.anchor), (3, 1));
        assert!(Surrounding::new("Héllo".into(), 2, 2).is_none(), "inside é");
        assert!(Surrounding::new("abc".into(), 4, 0).is_none());
        assert!(Surrounding::new("abc".into(), -1, 0).is_none());
        assert!(Surrounding::new("a".repeat(4001), 0, 0).is_none());
        assert_eq!(s.wire().text, "Héllo");
    }

    #[test]
    fn sensitive_fields_share_no_text() {
        let text = Surrounding::new("secret".into(), 6, 6);
        let mut field = Pending { enabled: true, surrounding: text.clone(), ..Pending::default() };
        assert_eq!(field.shared_surrounding(), text);
        field.purpose = Some(ContentPurpose::Password);
        assert_eq!(field.shared_surrounding(), None);
        field.purpose = Some(ContentPurpose::Normal);
        field.sensitive = true;
        assert_eq!(field.shared_surrounding(), None);
    }

    #[test]
    fn purposes_have_protocol_names() {
        assert_eq!(purpose_name(ContentPurpose::Terminal), "terminal");
        assert_eq!(purpose_name(ContentPurpose::Password), "password");
    }
}
