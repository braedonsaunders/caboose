//! Apple Pencil as a tablet pen (tablet-unstable-v2): one tablet and one pen tool on the
//! seat, with pressure, tilt and hover. Xwayland turns the same events into XInput 2
//! tablet devices for X11 applications.

use crate::state::State;
use caboose_display_protocol::{self as proto, PencilPhase};
use smithay::backend::input::{TabletToolCapabilities, TabletToolDescriptor, TabletToolType};
use smithay::wayland::tablet_manager::{TabletDescriptor, TabletHandle, TabletSeatTrait, TabletToolHandle};

/// The one pen the phone reports; a fixed serial, so applications remember its settings.
fn pen() -> TabletToolDescriptor {
    TabletToolDescriptor {
        tool_type: TabletToolType::Pen,
        hardware_serial: 0xCAB0_05E1,
        hardware_id_wacom: 0,
        capabilities: TabletToolCapabilities::PRESSURE | TabletToolCapabilities::TILT,
    }
}

pub fn tablet() -> TabletDescriptor {
    TabletDescriptor { name: "Apple Pencil".into(), usb_id: None, syspath: None }
}

#[derive(Default)]
pub struct PencilState {
    pub tablet: TabletHandle,
    tool: Option<TabletToolHandle>,
    /// The window the tip went down on: motion and lift go to it.
    window: Option<u64>,
    down: bool,
    near: bool,
}

impl PencilState {
    pub fn forget_window(&mut self, id: u64) {
        if self.window == Some(id) {
            self.window = None;
            self.down = false;
        }
    }
}

/// Pressure as the protocol defines it, 0 to 1.
fn pressure(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

/// Tilt in degrees, within the protocol's −90…90.
fn tilt(value: [f64; 2]) -> (f64, f64) {
    let clamp = |v: f64| if v.is_finite() { v.clamp(-90.0, 90.0) } else { 0.0 };
    (clamp(value[0]), clamp(value[1]))
}

impl State {
    fn pen_tool(&mut self) -> TabletToolHandle {
        if let Some(tool) = &self.input.pencil.tool {
            return tool.clone();
        }
        let dh = self.dh.clone();
        let tool = self.seat.tablet_seat().add_tool::<State>(self, &dh, &pen());
        self.input.pencil.tool = Some(tool.clone());
        tool
    }

    pub fn pencil(&mut self, m: &proto::Pencil) {
        let tool = self.pen_tool();
        let tablet = self.input.pencil.tablet.clone();
        let time = self.now_ms();
        let window = if self.input.pencil.down { self.input.pencil.window.unwrap_or(m.id) } else { m.id };
        match m.phase {
            PencilPhase::Hover | PencilPhase::Down | PencilPhase::Motion => {
                let Some((location, under)) = self.locate(window, m.x, m.y) else { return };
                if m.phase == PencilPhase::Down && !self.input.pencil.down {
                    self.press_focus(m.id);
                }
                tool.pressure(if m.phase == PencilPhase::Hover { 0.0 } else { pressure(m.pressure) });
                tool.tilt(tilt(m.tilt));
                let serial = self.next_serial();
                // Motion also brings the pen into proximity of the surface under it.
                tool.motion(location, under, &tablet, serial, time);
                self.input.pencil.near = true;
                if m.phase == PencilPhase::Down && !self.input.pencil.down {
                    self.input.pencil.down = true;
                    self.input.pencil.window = Some(m.id);
                    tool.tip_down(self.next_serial(), time);
                }
            }
            PencilPhase::Up => {
                if self.input.pencil.down {
                    if let Some((location, under)) = self.locate(window, m.x, m.y) {
                        tool.pressure(0.0);
                        tool.motion(location, under, &tablet, self.next_serial(), time);
                    }
                    tool.tip_up(time);
                }
                self.input.pencil.down = false;
                self.input.pencil.window = None;
            }
            PencilPhase::Cancel | PencilPhase::Leave => {
                if self.input.pencil.down {
                    tool.tip_up(time);
                }
                if self.input.pencil.near {
                    tool.proximity_out(time);
                }
                self.input.pencil = PencilState { tablet, tool: Some(tool), ..PencilState::default() };
            }
        }
    }
}

/// The tablet manager global and the seat's tablet, made once at startup.
pub fn advertise(state_dh: &smithay::reexports::wayland_server::DisplayHandle, seat: &smithay::input::Seat<State>) -> TabletHandle {
    smithay::wayland::tablet_manager::TabletManagerState::new::<State>(state_dh);
    seat.tablet_seat().add_tablet::<State>(state_dh, &tablet())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pressure_and_tilt_stay_in_range() {
        assert_eq!(pressure(1.4), 1.0);
        assert_eq!(pressure(-0.2), 0.0);
        assert_eq!(pressure(f64::NAN), 0.0);
        assert_eq!(pressure(0.25), 0.25);
        assert_eq!(tilt([120.0, -100.0]), (90.0, -90.0));
        assert_eq!(tilt([f64::INFINITY, 12.5]), (0.0, 12.5));
    }

    #[test]
    fn the_pen_reports_pressure_and_tilt() {
        let pen = pen();
        assert_eq!(pen.tool_type, TabletToolType::Pen);
        assert!(pen.capabilities.contains(TabletToolCapabilities::PRESSURE));
        assert!(pen.capabilities.contains(TabletToolCapabilities::TILT));
    }
}
