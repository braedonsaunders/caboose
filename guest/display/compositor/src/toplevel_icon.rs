//! xdg-toplevel-icon-v1: a Wayland toplevel's own icon. Each buffer's pixels are copied
//! when it is added, so the icon never depends on the buffer afterwards: Chromium destroys
//! its icon buffers before the icon object, which the protocol makes an error and which a
//! compositor that kept reading the buffers would answer by disconnecting it.

use crate::state::State;
use crate::windows::Surface;
use smithay::reexports::wayland_protocols::xdg::toplevel_icon::v1::server::xdg_toplevel_icon_manager_v1::{
    self, XdgToplevelIconManagerV1,
};
use smithay::reexports::wayland_protocols::xdg::toplevel_icon::v1::server::xdg_toplevel_icon_v1::{self, XdgToplevelIconV1};
use smithay::reexports::wayland_server::{Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource};
use std::sync::Mutex;

/// The icon size the compositor asks for: what a taskbar draws on a phone (icons.rs).
const ICON_SIZE: i32 = 128;

/// An icon object's images, straight-alpha ARGB, and whether `set_icon` has used it.
#[derive(Default)]
pub struct IconData {
    images: Mutex<Vec<(u32, u32, Vec<u32>)>>,
    assigned: std::sync::atomic::AtomicBool,
}

pub fn init(dh: &DisplayHandle) {
    dh.create_global::<State, XdgToplevelIconManagerV1, ()>(1, ());
}

impl GlobalDispatch<XdgToplevelIconManagerV1, ()> for State {
    fn bind(_: &mut State, _: &DisplayHandle, _: &Client, resource: New<XdgToplevelIconManagerV1>, _: &(), init: &mut DataInit<'_, State>) {
        let manager = init.init(resource, ());
        manager.icon_size(ICON_SIZE);
        manager.done();
    }
}

impl Dispatch<XdgToplevelIconManagerV1, ()> for State {
    fn request(
        state: &mut State,
        _: &Client,
        _: &XdgToplevelIconManagerV1,
        request: xdg_toplevel_icon_manager_v1::Request,
        _: &(),
        _: &DisplayHandle,
        init: &mut DataInit<'_, State>,
    ) {
        match request {
            xdg_toplevel_icon_manager_v1::Request::CreateIcon { id } => {
                init.init(id, IconData::default());
            }
            xdg_toplevel_icon_manager_v1::Request::SetIcon { toplevel, icon } => {
                let png = icon.as_ref().and_then(|icon| {
                    let data = icon.data::<IconData>()?;
                    data.assigned.store(true, std::sync::atomic::Ordering::Relaxed);
                    crate::icons::png_of_images(&data.images.lock().unwrap())
                });
                let id = state.windows.find(|w| matches!(&w.surface, Surface::Toplevel(t) if t.xdg_toplevel() == &toplevel));
                if let Some(w) = id.and_then(|id| state.windows.get_mut(id)) {
                    w.icon = png;
                }
            }
            xdg_toplevel_icon_manager_v1::Request::Destroy => {}
            _ => {}
        }
    }
}

impl Dispatch<XdgToplevelIconV1, IconData> for State {
    fn request(
        _: &mut State,
        _: &Client,
        icon: &XdgToplevelIconV1,
        request: xdg_toplevel_icon_v1::Request,
        data: &IconData,
        _: &DisplayHandle,
        _: &mut DataInit<'_, State>,
    ) {
        let assigned = data.assigned.load(std::sync::atomic::Ordering::Relaxed);
        match request {
            xdg_toplevel_icon_v1::Request::AddBuffer { buffer, scale: _ } => {
                if assigned {
                    icon.post_error(xdg_toplevel_icon_v1::Error::Immutable, "the icon is already assigned to a toplevel");
                    return;
                }
                match crate::icons::read_shm_icon(&buffer) {
                    Ok((w, h, argb)) => {
                        let mut images = data.images.lock().unwrap();
                        images.retain(|(iw, ih, _)| (*iw, *ih) != (w, h));
                        images.push((w, h, argb));
                    }
                    Err(reason) => icon.post_error(xdg_toplevel_icon_v1::Error::InvalidBuffer, reason),
                }
            }
            // An icon given only by name is left to the phone, which knows the computer's
            // applications by `app_id`.
            xdg_toplevel_icon_v1::Request::SetName { .. } => {
                if assigned {
                    icon.post_error(xdg_toplevel_icon_v1::Error::Immutable, "the icon is already assigned to a toplevel");
                }
            }
            xdg_toplevel_icon_v1::Request::Destroy => {}
            _ => {}
        }
    }
}
