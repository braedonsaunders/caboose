//! Finger scrolling through Xwayland (docs/input.md, "X11"). Caboose's Xwayland
//! (guest/xwayland/touchpad-scroll.patch) delivers finger scrolling from a touchpad device
//! whose smooth scroll valuators count X pixels, one scroll increment being the device's
//! `Xwayland Scroll Pixel Distance`. X11 is at the display's scale (x11_scale.rs) and
//! Chromium scrolls 120 of its own pixels per increment, so the distance is 120 times
//! the scale: a pan of N logical pixels then scrolls Chromium N CSS pixels.

use crate::x11sel::{self, Access};
use x11rb::connection::Connection;
use x11rb::protocol::xinput::{ConnectionExt as _, XIChangePropertyAux};
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _, PropMode};

const PROPERTY: &str = "Xwayland Scroll Pixel Distance";
/// The name of the touchpad device, before its `:SEAT` suffix.
const DEVICE: &[u8] = b"xwayland-touchpad:";

/// X pixels of finger scrolling per scroll increment at an X11 `scale`.
pub fn pixel_distance(scale: f64) -> u32 {
    (120.0 * scale).round().max(1.0) as u32
}

/// Sets the distance on Xwayland's touchpad devices, on a thread of its own: the
/// compositor's loop never waits on a client. An Xwayland without the patch has no such
/// property and is left as it is.
pub fn set_pixel_distance(access: Access, scale: f64) {
    let distance = pixel_distance(scale);
    std::thread::spawn(move || match set(&access, distance) {
        Ok(0) => tracing::debug!("Xwayland has no touchpad device for finger scrolling"),
        Ok(_) => tracing::info!("X11 finger scrolling at {distance} X pixels per increment"),
        Err(error) => tracing::warn!("X11 finger scrolling distance: {error}"),
    });
}

fn set(access: &Access, distance: u32) -> Result<usize, Box<dyn std::error::Error>> {
    let conn = x11sel::connect(access)?;
    let property = conn.intern_atom(true, PROPERTY.as_bytes())?.reply()?.atom;
    if property == u32::from(AtomEnum::NONE) {
        return Ok(0);
    }
    conn.xinput_xi_query_version(2, 2)?.reply()?;
    let devices = conn.xinput_xi_query_device(0u16)?.reply()?;
    let mut set = 0;
    for device in devices.infos.iter().filter(|d| d.name.starts_with(DEVICE)) {
        let value = XIChangePropertyAux::Data32(vec![distance]);
        conn.xinput_xi_change_property(device.deviceid, PropMode::REPLACE, property, AtomEnum::CARDINAL.into(), 1, &value)?
            .check()?;
        set += 1;
    }
    conn.flush()?;
    Ok(set)
}

#[cfg(test)]
mod tests {
    use super::pixel_distance;

    #[test]
    fn the_distance_is_a_chromium_increment_at_the_scale() {
        assert_eq!(pixel_distance(1.0), 120);
        assert_eq!(pixel_distance(2.0), 240);
        assert_eq!(pixel_distance(3.0), 360);
        assert_eq!(pixel_distance(1.25), 150);
        assert_eq!(pixel_distance(1.333), 160);
    }
}
