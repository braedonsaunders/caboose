//! X11 at the display's density. X11 has no per-window scale, so Xwayland gets the
//! primary display's scale as its client scale: its windows, root and pointer are in
//! display pixels, which smithay converts to and from the compositor's logical space,
//! and X11 pictures and GPU swapchains have the display's own pixels. XSETTINGS
//! `Xft/DPI` tells toolkits that read it (GTK, Qt, Chromium and Electron) to lay out at
//! that density, so an X11 application is the size a Wayland one is.
use crate::state::State;
use crate::windows::Surface;
use smithay::xwayland::XWaylandClientData;

/// `Xft/DPI` for `scale`: dots per inch times 1024, as XSETTINGS carries it.
pub fn xft_dpi(scale: f64) -> i32 {
    (96.0 * scale * 1024.0).round() as i32
}

/// A usable scale, or 1.
pub fn sane(scale: f64) -> f64 {
    if scale.is_finite() && (0.5..=8.0).contains(&scale) { scale } else { 1.0 }
}

impl State {
    /// Gives Xwayland the primary display's scale, once it runs and whenever that changes.
    pub fn apply_x11_scale(&mut self) {
        let Some(client) = self.xwayland_client.clone() else { return };
        let scale = sane(self.displays.primary().info.scale);
        if (scale - self.x11_scale).abs() < 1e-9 {
            return;
        }
        let Some(data) = client.get_data::<XWaylandClientData>() else { return };
        data.compositor_state.set_client_scale(scale);
        self.x11_scale = scale;
        tracing::info!("X11 at scale {scale}");
        if let Some(wm) = self.xwm.as_mut() {
            let settings = [("Xft/DPI".to_owned(), xft_dpi(scale).into())];
            if let Err(error) = wm.set_xsettings(settings.into_iter()) {
                tracing::warn!("XSETTINGS for X11 clients: {error}");
            }
        }
        // Outputs and windows are told again, now in the new display pixels.
        self.displays.refresh_outputs();
        let ids = self.windows.ids();
        for id in ids {
            let Some(window) = self.windows.get(id) else { continue };
            if let Surface::X11(x11) = &window.surface {
                if !x11.is_override_redirect() {
                    let _ = x11.configure(x11.geometry());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpi_follows_the_scale() {
        assert_eq!(xft_dpi(1.0), 98304);
        assert_eq!(xft_dpi(1.22), 119931);
        assert_eq!(xft_dpi(2.0), 196608);
        assert_eq!(sane(f64::NAN), 1.0);
        assert_eq!(sane(0.0), 1.0);
        assert_eq!(sane(3.0), 3.0);
    }
}
