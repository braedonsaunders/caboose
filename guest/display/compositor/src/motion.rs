//! Motion streams: finding the part of a window that updates at video rates.
//!
//! Fed with the macroblocks that really changed in each picture of a window, the
//! [`Tracker`] reports a region once it has been a dense, stable rectangle that changes
//! in most pictures at [`MIN_FPS`] or more for [`START_MS`], and reports its end once
//! that has stopped being true for [`STOP_MS`] (the video paused, moved, or closed).
//! The window's stream then sends the region as its own `motion` video stream.

use caboose_display_protocol::Rect;
use std::collections::VecDeque;

const MB: usize = 16;
/// How far back the rate and the activity are measured.
pub const WINDOW_MS: u64 = 1000;
/// Pictures per second, with changes, a region must keep up.
pub const MIN_FPS: usize = 15;
/// A macroblock is active when it changed in at least this share of those pictures.
const ACTIVE_SHARE: f64 = 0.5;
/// Active macroblocks must fill this share of their bounding box.
const MIN_DENSITY: f64 = 0.6;
/// The smallest region worth a stream: 192×112 pixels.
const MIN_COLS: usize = 12;
const MIN_ROWS: usize = 7;
pub const START_MS: u64 = 1000;
pub const STOP_MS: u64 = 1000;
/// Re-evaluate at most this often.
const EVALUATE_MS: u64 = 100;

/// Activity per macroblock over the last [`WINDOW_MS`] of pictures.
pub struct Detector {
    cols: usize,
    rows: usize,
    width: u32,
    height: u32,
    /// Pictures with changes: when, and which macroblocks.
    pictures: VecDeque<(u64, Vec<u32>)>,
    count: Vec<u16>,
    /// The picture each macroblock was last counted for, so overlaps count once.
    stamp: Vec<u64>,
    serial: u64,
}

impl Detector {
    pub fn new(width: u32, height: u32) -> Self {
        let cols = (width as usize).div_ceil(MB);
        let rows = (height as usize).div_ceil(MB);
        let n = cols * rows;
        Self { cols, rows, width, height, pictures: VecDeque::new(), count: vec![0; n], stamp: vec![0; n], serial: 0 }
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// A picture at `now_ms` in which `changed` (picture pixels) really changed.
    pub fn picture(&mut self, changed: &[Rect], now_ms: u64) {
        self.expire(now_ms);
        self.serial += 1;
        let mut blocks = Vec::new();
        for r in changed {
            let x0 = r.x.max(0) as usize / MB;
            let y0 = r.y.max(0) as usize / MB;
            let x1 = ((r.x as i64 + r.w as i64).max(0) as usize).div_ceil(MB).min(self.cols);
            let y1 = ((r.y as i64 + r.h as i64).max(0) as usize).div_ceil(MB).min(self.rows);
            for row in y0..y1 {
                for col in x0..x1 {
                    let i = row * self.cols + col;
                    if self.stamp[i] != self.serial {
                        self.stamp[i] = self.serial;
                        blocks.push(i as u32);
                    }
                }
            }
        }
        if blocks.is_empty() {
            return;
        }
        for &b in &blocks {
            self.count[b as usize] += 1;
        }
        self.pictures.push_back((now_ms, blocks));
    }

    fn expire(&mut self, now_ms: u64) {
        while self.pictures.front().is_some_and(|(t, _)| now_ms >= t + WINDOW_MS) {
            let (_, blocks) = self.pictures.pop_front().unwrap();
            for b in blocks {
                self.count[b as usize] -= 1;
            }
        }
    }

    /// The region updating at video rates now, in picture pixels, if there is one.
    pub fn region(&mut self, now_ms: u64) -> Option<Rect> {
        self.expire(now_ms);
        let pictures = self.pictures.len();
        if pictures < MIN_FPS {
            return None;
        }
        let threshold = ((pictures as f64 * ACTIVE_SHARE).ceil() as u16).max(1);
        let (mut c0, mut r0, mut c1, mut r1, mut active) = (usize::MAX, usize::MAX, 0, 0, 0usize);
        for row in 0..self.rows {
            for col in 0..self.cols {
                if self.count[row * self.cols + col] >= threshold {
                    active += 1;
                    c0 = c0.min(col);
                    r0 = r0.min(row);
                    c1 = c1.max(col + 1);
                    r1 = r1.max(row + 1);
                }
            }
        }
        if active == 0 || c1 - c0 < MIN_COLS || r1 - r0 < MIN_ROWS {
            return None;
        }
        if (active as f64) < MIN_DENSITY * ((c1 - c0) * (r1 - r0)) as f64 {
            return None;
        }
        let x = (c0 * MB) as i32;
        let y = (r0 * MB) as i32;
        let w = ((c1 * MB).min(self.width as usize) - c0 * MB) as i32;
        let h = ((r1 * MB).min(self.height as usize) - r0 * MB) as i32;
        Some(Rect::new(x, y, w, h))
    }
}

/// Intersection over union of two rectangles.
pub fn iou(a: Rect, b: Rect) -> f64 {
    let (x0, y0) = (a.x.max(b.x), a.y.max(b.y));
    let (x1, y1) = ((a.x + a.w).min(b.x + b.w), (a.y + a.h).min(b.y + b.h));
    let inter = (x1 - x0).max(0) as f64 * (y1 - y0).max(0) as f64;
    let union = a.w as f64 * a.h as f64 + b.w as f64 * b.h as f64 - inter;
    if union > 0.0 {
        inter / union
    } else {
        0.0
    }
}

/// What changed about a window's motion region.
#[derive(Debug, PartialEq)]
pub enum Change {
    Start(Rect),
    Stop,
}

/// Start/stop decisions with hysteresis, for one window.
pub struct Tracker {
    pub detector: Detector,
    /// The region being streamed.
    active: Option<Rect>,
    /// When the active region last looked right.
    good_ms: u64,
    /// A region that has looked the same since `pending.1`.
    pending: Option<(Rect, u64)>,
    evaluated_ms: Option<u64>,
}

impl Tracker {
    pub fn new(width: u32, height: u32) -> Self {
        Self { detector: Detector::new(width, height), active: None, good_ms: 0, pending: None, evaluated_ms: None }
    }

    #[cfg(test)]
    pub fn active(&self) -> Option<Rect> {
        self.active
    }

    /// Decides at `now_ms`; call after each picture and once in a while without one.
    pub fn update(&mut self, now_ms: u64) -> Option<Change> {
        if self.evaluated_ms.is_some_and(|t| now_ms < t + EVALUATE_MS) {
            return None;
        }
        self.evaluated_ms = Some(now_ms);
        let region = self.detector.region(now_ms);
        match self.active {
            Some(active) => {
                if region.is_some_and(|r| iou(r, active) >= 0.5) {
                    self.good_ms = now_ms;
                } else if now_ms >= self.good_ms + STOP_MS {
                    self.active = None;
                    self.pending = None;
                    return Some(Change::Stop);
                }
                None
            }
            None => {
                let Some(r) = region else {
                    self.pending = None;
                    return None;
                };
                match self.pending {
                    Some((p, since)) if iou(p, r) >= 0.8 => {
                        if now_ms >= since + START_MS {
                            self.active = Some(r);
                            self.good_ms = now_ms;
                            self.pending = None;
                            return Some(Change::Start(r));
                        }
                    }
                    _ => self.pending = Some((r, now_ms)),
                }
                None
            }
        }
    }
}

/// `r` without `hole`: up to four rectangles (above, below, left, right).
pub fn subtract(r: Rect, hole: Rect) -> Vec<Rect> {
    let (x0, y0, x1, y1) = (r.x, r.y, r.x + r.w, r.y + r.h);
    let (hx0, hy0) = (hole.x.max(x0), hole.y.max(y0));
    let (hx1, hy1) = ((hole.x + hole.w).min(x1), (hole.y + hole.h).min(y1));
    if hx0 >= hx1 || hy0 >= hy1 {
        return vec![r];
    }
    let mut out = Vec::new();
    if hy0 > y0 {
        out.push(Rect::new(x0, y0, r.w, hy0 - y0));
    }
    if y1 > hy1 {
        out.push(Rect::new(x0, hy1, r.w, y1 - hy1));
    }
    if hx0 > x0 {
        out.push(Rect::new(x0, hy0, hx0 - x0, hy1 - hy0));
    }
    if x1 > hx1 {
        out.push(Rect::new(hx1, hy0, x1 - hx1, hy1 - hy0));
    }
    out
}

/// The part of `r` inside `area`, if any.
pub fn intersect(r: Rect, area: Rect) -> Option<Rect> {
    let (x0, y0) = (r.x.max(area.x), r.y.max(area.y));
    let (x1, y1) = ((r.x + r.w).min(area.x + area.w), (r.y + r.h).min(area.y + area.h));
    (x0 < x1 && y0 < y1).then(|| Rect::new(x0, y0, x1 - x0, y1 - y0))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VIDEO: Rect = Rect { x: 320, y: 160, w: 480, h: 272 };

    /// Plays `VIDEO` at `fps` from `from_ms` for `ms`, with a caret blinking elsewhere,
    /// and returns the changes the tracker reported.
    fn play(t: &mut Tracker, fps: u64, from_ms: u64, ms: u64) -> Vec<(u64, Change)> {
        let mut out = Vec::new();
        let step = 1000 / fps;
        let mut now = from_ms;
        while now < from_ms + ms {
            let mut changed = vec![VIDEO];
            if now % 500 < step {
                changed.push(Rect::new(40, 40, 2, 16));
            }
            t.detector.picture(&changed, now);
            if let Some(c) = t.update(now) {
                out.push((now, c));
            }
            now += step;
        }
        out
    }

    #[test]
    fn a_video_is_found_after_a_second_and_ends_after_it_pauses() {
        let mut t = Tracker::new(1280, 720);
        let changes = play(&mut t, 30, 0, 3000);
        assert_eq!(changes.len(), 1);
        let (at, Change::Start(r)) = &changes[0] else { panic!("{changes:?}") };
        // 15 pictures to look like video, then a second to be sure.
        assert!(*at >= 1400 && *at <= 1700, "started at {at}");
        assert_eq!(*r, VIDEO);
        // Paused: no pictures; the once-a-second check stops it when the last second
        // of pictures has aged out and a further second has passed.
        assert_eq!(t.update(3400), None);
        assert_eq!(t.update(4200), None);
        assert_eq!(t.update(4500), Some(Change::Stop));
        assert_eq!(t.active(), None);
    }

    #[test]
    fn slow_or_small_changes_are_not_video() {
        let mut t = Tracker::new(1280, 720);
        assert!(play(&mut t, 10, 0, 4000).is_empty(), "10 fps is not video");
        let mut t = Tracker::new(1280, 720);
        for i in 0..120u64 {
            // A 64×64 spinner at 60 fps.
            t.detector.picture(&[Rect::new(600, 300, 64, 64)], i * 16);
            assert_eq!(t.update(i * 16), None);
        }
    }

    #[test]
    fn two_animations_far_apart_are_not_one_region() {
        let mut t = Tracker::new(1280, 720);
        for i in 0..120u64 {
            let changed = [Rect::new(0, 0, 192, 112), Rect::new(1088, 608, 192, 112)];
            t.detector.picture(&changed, i * 16);
            assert_eq!(t.update(i * 16), None);
        }
    }

    #[test]
    fn a_moved_video_stops_its_stream() {
        let mut t = Tracker::new(1280, 720);
        play(&mut t, 30, 0, 2500);
        assert!(t.active().is_some());
        let moved = Rect::new(VIDEO.x, VIDEO.y + 200, VIDEO.w, VIDEO.h);
        let mut stopped = None;
        for i in 0..60u64 {
            let now = 2500 + i * 33;
            t.detector.picture(&[moved], now);
            if t.update(now) == Some(Change::Stop) {
                stopped = Some(now);
                break;
            }
        }
        assert!(stopped.is_some_and(|s| s <= 2500 + 2 * STOP_MS), "{stopped:?}");
    }

    #[test]
    fn rectangles_subtract_and_intersect() {
        let r = Rect::new(0, 0, 100, 100);
        let hole = Rect::new(10, 20, 30, 40);
        let parts = subtract(r, hole);
        let area: i32 = parts.iter().map(|p| p.w * p.h).sum();
        assert_eq!(area, 100 * 100 - 30 * 40);
        assert!(parts.iter().all(|p| intersect(*p, hole).is_none()));
        assert_eq!(subtract(r, Rect::new(200, 0, 5, 5)), vec![r]);
        assert!(subtract(hole, r).is_empty());
        assert_eq!(intersect(Rect::new(90, 90, 20, 20), r), Some(Rect::new(90, 90, 10, 10)));
        assert!((iou(r, r) - 1.0).abs() < 1e-9 && iou(r, Rect::new(200, 200, 1, 1)) == 0.0);
    }
}
