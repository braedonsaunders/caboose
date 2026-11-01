//! Scrolling from the client as wl_pointer axis events (docs/input.md, "Scrolling").
//!
//! A precise scroll is a finger on the phone: its window pixels become logical pixels
//! (divided by the display's scale) with axis_source finger and no discrete steps, and
//! the sequence ends with axis_stop once samples stop coming. A wheel scroll is clicks of
//! a mouse wheel: 15 logical pixels and 120 value120 units each, with axis_source wheel.

use crate::state::State;
use caboose_display_protocol as proto;
use smithay::backend::input::{Axis, AxisSource};
use smithay::input::pointer::AxisFrame;
use std::time::Duration;

/// Logical pixels per wheel click, as libinput reports for a mouse wheel.
const WHEEL_STEP: f64 = 15.0;

/// A finger scroll sequence ends when no sample has come for this long: the phone sends
/// one every display refresh while the content moves.
const STOP_AFTER: Duration = Duration::from_millis(50);

/// One scroll sample as the axis events of one wl_pointer frame.
pub(super) fn axis_frame(scroll: &proto::Scroll, display_scale: f64, time: u32) -> AxisFrame {
    let axes = [(Axis::Horizontal, scroll.dx), (Axis::Vertical, scroll.dy)];
    let moved = axes.into_iter().filter(|(_, v)| *v != 0.0);
    if scroll.precise {
        moved.fold(AxisFrame::new(time).source(AxisSource::Finger), |f, (axis, v)| f.value(axis, v / display_scale))
    } else {
        moved.fold(AxisFrame::new(time).source(AxisSource::Wheel), |f, (axis, v)| {
            f.value(axis, v * WHEEL_STEP).v120(axis, (v * 120.0).round() as i32)
        })
    }
}

/// The frame that ends a finger scroll sequence: axis_stop on both axes.
fn stop_frame(time: u32) -> AxisFrame {
    AxisFrame::new(time).source(AxisSource::Finger).stop(Axis::Vertical).stop(Axis::Horizontal)
}

impl State {
    /// (Re)starts the wait after which a finger scroll sequence gets its axis_stop, the
    /// end clients use to finish a gesture (and start their own fling, if any).
    pub(super) fn arm_scroll_stop(&mut self) {
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        if let Some(token) = self.input.scroll_stop.take() {
            self.handle.remove(token);
        }
        let inserted = self.handle.insert_source(Timer::from_duration(STOP_AFTER), |_, _, state: &mut State| {
            state.input.scroll_stop = None;
            if let Some(pointer) = state.seat.get_pointer() {
                let time = state.now_ms();
                pointer.axis(state, stop_frame(time));
                pointer.frame(state);
                if let Err(e) = state.dh.flush_clients() {
                    tracing::warn!("flushing Wayland clients: {e}");
                }
            }
            TimeoutAction::Drop
        });
        self.input.scroll_stop = inserted.ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn precise(dx: f64, dy: f64) -> proto::Scroll {
        proto::Scroll { dx, dy, precise: true, seq: None }
    }

    #[test]
    fn a_finger_pan_is_its_window_pixels_over_the_scale() {
        let f = axis_frame(&precise(0.0, 60.0), 2.0, 7);
        assert_eq!(f.source, Some(AxisSource::Finger));
        assert_eq!(f.axis, (0.0, 30.0));
        assert_eq!(f.v120, None);
        assert_eq!(f.stop, (false, false));
        assert_eq!(f.time, 7);
        let f = axis_frame(&precise(-9.0, 4.5), 3.0, 0);
        assert_eq!(f.axis, (-3.0, 1.5));
    }

    #[test]
    fn a_pan_in_samples_adds_up_to_the_whole_pan() {
        // 400 window pixels at scale 2 in ten frames of a 60 Hz finger: 200 logical pixels.
        let total: f64 = (0..10).map(|_| axis_frame(&precise(0.0, 40.0), 2.0, 0).axis.1).sum();
        assert_eq!(total, 200.0);
        // Fractions of a pixel are kept, not rounded away.
        let total: f64 = (0..3).map(|_| axis_frame(&precise(0.0, 1.0), 2.0, 0).axis.1).sum();
        assert_eq!(total, 1.5);
    }

    #[test]
    fn wheel_clicks_are_discrete_steps() {
        let f = axis_frame(&proto::Scroll { dx: -1.0, dy: 2.0, precise: false, seq: None }, 2.0, 0);
        assert_eq!(f.source, Some(AxisSource::Wheel));
        assert_eq!(f.axis, (-15.0, 30.0));
        assert_eq!(f.v120, Some((-120, 240)));
    }

    #[test]
    fn the_sequence_ends_with_a_finger_stop_on_both_axes() {
        let f = stop_frame(9);
        assert_eq!(f.source, Some(AxisSource::Finger));
        assert_eq!(f.stop, (true, true));
        assert_eq!(f.axis, (0.0, 0.0));
    }
}
