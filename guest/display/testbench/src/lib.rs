//! Pure logic of the testbench: the stepping marker, the protocol checklist
//! and the JSON report. The Wayland and X11 front ends in `main.rs`/`x11.rs`
//! fill these in from real events; nothing here talks to a compositor.

/// A marker that steps one position per frame. A dropped frame leaves a gap
/// of two steps; a repeated frame shows the same position twice. Positions
/// wrap, so frame `n` is always at `(n * STEP) % span`.
#[derive(Debug, Default)]
pub struct Marker {
    pub frame: u64,
}

pub const STEP_PX: i32 = 16;
pub const MARKER_W: i32 = 16;

impl Marker {
    /// The marker's x for the current frame in a surface `width` px wide.
    pub fn x(&self, width: i32) -> i32 {
        let span = (width - MARKER_W).max(1);
        ((self.frame as i32 * STEP_PX) % span).max(0)
    }
    pub fn advance(&mut self) {
        self.frame += 1;
    }
    /// The six top-row blocks encoding `frame % 64` in binary, most
    /// significant first, so a screenshot identifies the exact frame.
    pub fn frame_bits(&self) -> [bool; 6] {
        let v = (self.frame % 64) as u32;
        std::array::from_fn(|i| v & (1 << (5 - i)) != 0)
    }
}

/// One logged input event: timing and kind only on the Wayland side the
/// front end adds detail such as a button or keysym name it received itself.
#[derive(Debug, Clone)]
pub struct InputEvent {
    pub at_us: u64,
    pub kind: String,
    pub detail: String,
}

/// One presentation-feedback sample for a frame.
#[derive(Debug, Clone, Copy)]
pub struct Presented {
    pub frame: u64,
    pub presented_us: u64,
    pub refresh_ns: u32,
    pub seq: u64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CheckState {
    Pass,
    Fail,
    Info,
    Untested,
}

#[derive(Debug, Clone)]
pub struct Check {
    pub id: String,
    pub state: CheckState,
    pub detail: String,
}

impl Check {
    pub fn new(id: &str, state: CheckState, detail: impl Into<String>) -> Self {
        Self { id: id.into(), state, detail: detail.into() }
    }
}

/// The whole `--auto` report, rendered as JSON without a JSON dependency.
#[derive(Debug, Default)]
pub struct Report {
    pub mode: String,
    pub globals: Vec<(String, u32)>,
    pub checks: Vec<Check>,
    pub inputs: Vec<InputEvent>,
    pub presented: Vec<Presented>,
    pub frames: u64,
    pub width: i32,
    pub height: i32,
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn state_name(s: CheckState) -> &'static str {
    match s {
        CheckState::Pass => "pass",
        CheckState::Fail => "fail",
        CheckState::Info => "info",
        CheckState::Untested => "untested",
    }
}

/// Nearest-rank percentile in microseconds; `None` when empty.
pub fn percentile_us(mut values: Vec<u64>, p: f64) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    let rank = (p * values.len() as f64).ceil() as usize;
    Some(values[rank.clamp(1, values.len()) - 1])
}

/// Gaps between consecutive presented frames, and how many refreshes each
/// gap spans (a gap over 1.5 refreshes is a skipped vblank).
pub fn present_stats(presented: &[Presented]) -> (Option<u64>, Option<u64>, u64) {
    let gaps: Vec<u64> = presented.windows(2).map(|w| w[1].presented_us.saturating_sub(w[0].presented_us)).collect();
    let skipped = presented
        .windows(2)
        .filter(|w| {
            let refresh_us = (w[0].refresh_ns as u64) / 1000;
            refresh_us > 0 && w[1].presented_us.saturating_sub(w[0].presented_us) > refresh_us * 3 / 2
        })
        .count() as u64;
    (percentile_us(gaps.clone(), 0.5), percentile_us(gaps, 0.95), skipped)
}

impl Report {
    pub fn failed(&self) -> bool {
        self.checks.iter().any(|c| c.state == CheckState::Fail)
    }

    pub fn to_json(&self) -> String {
        let globals: Vec<String> = self
            .globals
            .iter()
            .map(|(n, v)| format!("{{\"interface\":\"{}\",\"version\":{}}}", esc(n), v))
            .collect();
        let checks: Vec<String> = self
            .checks
            .iter()
            .map(|c| format!("{{\"id\":\"{}\",\"state\":\"{}\",\"detail\":\"{}\"}}", esc(&c.id), state_name(c.state), esc(&c.detail)))
            .collect();
        let inputs: Vec<String> = self
            .inputs
            .iter()
            .map(|e| format!("{{\"at_us\":{},\"kind\":\"{}\",\"detail\":\"{}\"}}", e.at_us, esc(&e.kind), esc(&e.detail)))
            .collect();
        let (p50, p95, skipped) = present_stats(&self.presented);
        let presented: Vec<String> = self
            .presented
            .iter()
            .map(|p| format!("{{\"frame\":{},\"presented_us\":{},\"refresh_ns\":{},\"seq\":{}}}", p.frame, p.presented_us, p.refresh_ns, p.seq))
            .collect();
        format!(
            "{{\"mode\":\"{}\",\"ok\":{},\"frames\":{},\"width\":{},\"height\":{},\"globals\":[{}],\"checks\":[{}],\"inputs\":[{}],\"presented\":[{}],\"present_gap_us\":{{\"p50\":{},\"p95\":{},\"skipped\":{}}}}}\n",
            esc(&self.mode),
            !self.failed(),
            self.frames,
            self.width,
            self.height,
            globals.join(","),
            checks.join(","),
            inputs.join(","),
            presented.join(","),
            p50.map_or("null".into(), |v| v.to_string()),
            p95.map_or("null".into(), |v| v.to_string()),
            skipped,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marker_steps_one_position_per_frame_and_wraps() {
        let mut m = Marker::default();
        assert_eq!(m.x(640), 0);
        m.advance();
        assert_eq!(m.x(640), STEP_PX);
        for _ in 0..1000 {
            m.advance();
        }
        assert!(m.x(640) >= 0 && m.x(640) + MARKER_W <= 640);
        assert_eq!(m.frame_bits(), {
            let v = (1001u32) % 64;
            std::array::from_fn(|i| v & (1 << (5 - i)) != 0)
        });
    }

    #[test]
    fn present_stats_names_skipped_refreshes() {
        let p: Vec<Presented> = (0..5)
            .map(|i| Presented { frame: i, presented_us: i * 16_667 + if i > 2 { 16_667 } else { 0 }, refresh_ns: 16_667_000, seq: i })
            .collect();
        let (p50, _, skipped) = present_stats(&p);
        assert_eq!(p50, Some(16_667));
        assert_eq!(skipped, 1);
    }

    #[test]
    fn the_report_is_json_and_fails_with_a_failed_check() {
        let mut r = Report { mode: "wayland".into(), frames: 3, width: 640, height: 360, ..Default::default() };
        r.globals.push(("wl_compositor".into(), 6));
        r.checks.push(Check::new("shm_argb8888", CheckState::Pass, "advertised"));
        let j = r.to_json();
        assert!(j.contains("\"ok\":true") && j.contains("wl_compositor"), "{j}");
        r.checks.push(Check::new("frame_callback", CheckState::Fail, "none in 2 s"));
        assert!(r.failed() && r.to_json().contains("\"ok\":false"));
    }
}
