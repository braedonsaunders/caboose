//! Scrolling from the client as wl_pointer axis events (docs/input.md, "Scrolling").
//!
//! A precise scroll is a finger on the phone: its window pixels become logical pixels
//! (divided by the display's scale) with axis_source finger and no discrete steps, and
//! the sequence ends with axis_stop once samples stop coming. A wheel scroll is clicks of
//! a mouse wheel: 15 logical pixels and 120 value120 units each, with axis_source wheel.
//!
//! Kinetic scrolling is the input system's, as a touchpad driver's coasting is: when the
//! finger lifts moving (the scroll's `lift`), the sequence goes on as finger axis events
//! at the display's refresh, slowing exponentially, and ends with axis_stop. A finger
//! touching down (`hold`), another scroll or a button stops it.

use crate::state::State;
use caboose_display_protocol as proto;
use smithay::backend::input::{Axis, AxisSource};
use smithay::input::pointer::AxisFrame;
use std::time::{Duration, Instant};

/// Logical pixels per wheel click, as libinput reports for a mouse wheel.
const WHEEL_STEP: f64 = 15.0;

/// A finger scroll sequence ends when no sample has come for this long: the phone sends
/// one every display refresh while the content moves.
const STOP_AFTER: Duration = Duration::from_millis(50);

/// Coasting slows by this factor every millisecond: a UIScrollView's normal deceleration,
/// so content thrown on the computer travels as far as it would in a phone app.
const DECELERATION_PER_MS: f64 = 0.998;
/// A lift slower than this (window pixels per second) does not coast.
const MIN_LIFT_SPEED: f64 = 80.0;
/// Coasting ends when it is this slow (window pixels per second).
const STOP_SPEED: f64 = 20.0;
/// The fastest coast (window pixels per second; 10000 points per second on a phone at
/// scale 3); a faster lift is slowed to it.
const MAX_LIFT_SPEED: f64 = 30_000.0;

/// The motion of content coasting after the finger lifted, in window pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Coast {
    velocity: [f64; 2],
}

impl Coast {
    /// Coasting from a lift at `velocity`, or none for a lift too slow (or not finite).
    pub(super) fn from_lift(velocity: [f64; 2]) -> Option<Self> {
        let speed = velocity[0].hypot(velocity[1]);
        if !speed.is_finite() || speed < MIN_LIFT_SPEED {
            return None;
        }
        let k = MAX_LIFT_SPEED.min(speed) / speed;
        Some(Self { velocity: [velocity[0] * k, velocity[1] * k] })
    }

    fn decay() -> f64 {
        -DECELERATION_PER_MS.ln() * 1000.0
    }

    /// The distance covered in the next `dt` seconds, integrated exactly, and whether
    /// coasting goes on after it: it ends within the step that reaches the stop speed.
    pub(super) fn step(&mut self, dt: f64) -> ([f64; 2], bool) {
        let decay = Self::decay();
        let speed = self.velocity[0].hypot(self.velocity[1]);
        let left = (speed / STOP_SPEED).ln().max(0.0) / decay;
        let dt = dt.clamp(0.0, left);
        let factor = (-decay * dt).exp();
        let moved = self.velocity.map(|v| v * (1.0 - factor) / decay);
        self.velocity = self.velocity.map(|v| v * factor);
        (moved, dt < left)
    }
}

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

/// The finger frames of one coasting step: `moved` window pixels at the display's scale.
fn coast_frame(moved: [f64; 2], display_scale: f64, time: u32) -> AxisFrame {
    let axes = [(Axis::Horizontal, moved[0]), (Axis::Vertical, moved[1])];
    axes.into_iter()
        .filter(|(_, v)| *v != 0.0)
        .fold(AxisFrame::new(time).source(AxisSource::Finger), |f, (axis, v)| f.value(axis, v / display_scale))
}

impl State {
    fn send_scroll_stop(&mut self) {
        if let Some(pointer) = self.seat.get_pointer() {
            let time = self.now_ms();
            pointer.axis(self, stop_frame(time));
            pointer.frame(self);
            if let Err(e) = self.dh.flush_clients() {
                tracing::warn!("flushing Wayland clients: {e}");
            }
        }
    }

    /// Ends the finger scroll sequence now, coasting or not: axis_stop if one is open.
    pub(super) fn end_scroll(&mut self) {
        let open = self.input.scroll_stop.is_some() || self.input.coast.is_some();
        for token in [self.input.scroll_stop.take(), self.input.coast.take()].into_iter().flatten() {
            self.handle.remove(token);
        }
        if open {
            self.send_scroll_stop();
        }
    }

    /// The finger lifted at `velocity` (window pixels per second): the sequence coasts
    /// at `refresh_hz`, or ends now if the lift was too slow.
    pub(super) fn lift_scroll(&mut self, velocity: [f64; 2], display_scale: f64, refresh_hz: f64) {
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        if let Some(token) = self.input.scroll_stop.take() {
            self.handle.remove(token);
        }
        let Some(mut coast) = Coast::from_lift(velocity) else {
            self.send_scroll_stop();
            return;
        };
        let period = Duration::from_secs_f64(1.0 / refresh_hz.clamp(30.0, 240.0));
        let mut last = Instant::now();
        let inserted = self.handle.insert_source(Timer::from_duration(period), move |_, _, state: &mut State| {
            let now = Instant::now();
            let (moved, more) = coast.step(now.duration_since(last).as_secs_f64());
            last = now;
            if let Some(pointer) = state.seat.get_pointer() {
                let time = state.now_ms();
                pointer.axis(state, coast_frame(moved, display_scale, time));
                pointer.frame(state);
            }
            if more {
                if let Err(e) = state.dh.flush_clients() {
                    tracing::warn!("flushing Wayland clients: {e}");
                }
                return TimeoutAction::ToDuration(period);
            }
            state.input.coast = None;
            state.send_scroll_stop();
            TimeoutAction::Drop
        });
        match inserted {
            Ok(token) => self.input.coast = Some(token),
            Err(e) => {
                tracing::warn!("kinetic scrolling: {e}");
                self.send_scroll_stop();
            }
        }
    }

    /// (Re)starts the wait after which a finger scroll sequence gets its axis_stop, the
    /// end clients use to finish a gesture (and start their own fling, if any).
    pub(super) fn arm_scroll_stop(&mut self) {
        use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
        if let Some(token) = self.input.scroll_stop.take() {
            self.handle.remove(token);
        }
        let inserted = self.handle.insert_source(Timer::from_duration(STOP_AFTER), |_, _, state: &mut State| {
            state.input.scroll_stop = None;
            state.send_scroll_stop();
            TimeoutAction::Drop
        });
        self.input.scroll_stop = inserted.ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn precise(dx: f64, dy: f64) -> proto::Scroll {
        proto::Scroll { dx, dy, precise: true, seq: None, lift: None, hold: false }
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
        let f = axis_frame(&proto::Scroll { dx: -1.0, dy: 2.0, precise: false, seq: None, lift: None, hold: false }, 2.0, 0);
        assert_eq!(f.source, Some(AxisSource::Wheel));
        assert_eq!(f.axis, (-15.0, 30.0));
        assert_eq!(f.v120, Some((-120, 240)));
    }

    fn coast_distance(velocity: [f64; 2], hz: f64) -> ([f64; 2], usize) {
        let mut coast = Coast::from_lift(velocity).unwrap();
        let (mut total, mut steps) = ([0.0, 0.0], 0);
        loop {
            let (moved, more) = coast.step(1.0 / hz);
            total = [total[0] + moved[0], total[1] + moved[1]];
            steps += 1;
            if !more {
                return (total, steps);
            }
        }
    }

    #[test]
    fn a_lift_coasts_as_far_at_any_refresh_rate() {
        let (baseline, steps) = coast_distance([0.0, 2000.0], 60.0);
        // v / k (1 - stop / v): 2000 px/s slows to 20 px/s in 2.3 s over 989 px.
        let decay = -DECELERATION_PER_MS.ln() * 1000.0;
        let expected = 2000.0 / decay * (1.0 - STOP_SPEED / 2000.0);
        assert!((baseline[1] - expected).abs() < 1e-6, "{baseline:?} vs {expected}");
        assert_eq!(baseline[0], 0.0);
        assert!((137..=139).contains(&steps), "{steps} steps at 60 Hz");
        for hz in [30.0, 90.0, 120.0, 144.0] {
            let (total, _) = coast_distance([0.0, 2000.0], hz);
            assert!((total[1] - baseline[1]).abs() < 1e-6, "{hz} Hz: {total:?}");
        }
    }

    #[test]
    fn coasting_keeps_the_lift_direction_and_slows_every_step() {
        let mut coast = Coast::from_lift([-300.0, 400.0]).unwrap();
        let (first, _) = coast.step(1.0 / 120.0);
        let (second, _) = coast.step(1.0 / 120.0);
        assert!(first[0] < 0.0 && first[1] > 0.0);
        assert!((first[1] / first[0] + 4.0 / 3.0).abs() < 1e-9);
        assert!(second[1] < first[1] && second[1] > 0.0);
    }

    #[test]
    fn slow_or_broken_lifts_do_not_coast_and_fast_ones_are_capped() {
        assert_eq!(Coast::from_lift([0.0, 79.0]), None);
        assert_eq!(Coast::from_lift([f64::NAN, 900.0]), None);
        assert_eq!(Coast::from_lift([f64::INFINITY, 0.0]), None);
        let fast = Coast::from_lift([0.0, -50_000.0]).unwrap();
        assert_eq!(fast.velocity, [0.0, -MAX_LIFT_SPEED]);
    }

    #[test]
    fn a_long_frame_ends_coasting_at_the_stop_speed() {
        let mut coast = Coast::from_lift([1000.0, 0.0]).unwrap();
        let (moved, more) = coast.step(60.0);
        assert!(!more);
        let decay = -DECELERATION_PER_MS.ln() * 1000.0;
        assert!((moved[0] - (1000.0 - STOP_SPEED) / decay).abs() < 1e-6);
    }

    #[test]
    fn coasting_is_finger_frames_in_logical_pixels() {
        let f = coast_frame([0.0, 9.0], 3.0, 4);
        assert_eq!(f.source, Some(AxisSource::Finger));
        assert_eq!(f.axis, (0.0, 3.0));
        assert_eq!(f.stop, (false, false));
    }

    #[test]
    fn the_sequence_ends_with_a_finger_stop_on_both_axes() {
        let f = stop_frame(9);
        assert_eq!(f.source, Some(AxisSource::Finger));
        assert_eq!(f.stop, (true, true));
        assert_eq!(f.axis, (0.0, 0.0));
    }
}
