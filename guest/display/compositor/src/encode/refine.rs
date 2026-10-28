//! Progressive refinement: which macroblocks of a stream to sharpen, and when.
//!
//! Every picture is coded at the stream's normal QP, which keeps updates small but
//! leaves text soft. Once a macroblock has not changed for a while, the encoder codes
//! it once more at a lower QP; its pixels on the client get sharper, and from then on
//! the encoder skips it (x264 skips a macroblock hinted constant whose reference was
//! coded at no higher a QP), so it stays sharp until it changes again.
//!
//! A macroblock that changes again soon after it was sharpened (a blinking caret, a
//! spinner) waits twice as long the next time, up to [`MAX_BACKOFF`] doublings, so it
//! does not cost a sharpening picture per blink; staying sharp for [`SETTLED_MS`] resets
//! that.

use caboose_display_protocol::Rect;

const MB: usize = 16;
pub const MAX_BACKOFF: u8 = 4;
pub const SETTLED_MS: u64 = 2000;

/// Per macroblock of one stream: when it last changed (`None` once it is sharp), when it
/// was last sharpened, and how many times in a row it changed soon after.
pub struct Quiet {
    cols: usize,
    rows: usize,
    width: u32,
    height: u32,
    after_ms: u64,
    changed_ms: Vec<Option<u64>>,
    sharpened_ms: Vec<Option<u64>>,
    backoff: Vec<u8>,
}

impl Quiet {
    /// A picture of `width × height` whose macroblocks are sharpened after `after_ms`
    /// without change. Nothing is pending until something is marked changed.
    pub fn new(width: u32, height: u32, after_ms: u64) -> Self {
        let cols = (width as usize).div_ceil(MB);
        let rows = (height as usize).div_ceil(MB);
        let n = cols * rows;
        Self {
            cols,
            rows,
            width,
            height,
            after_ms,
            changed_ms: vec![None; n],
            sharpened_ms: vec![None; n],
            backoff: vec![0; n],
        }
    }

    /// Everything changed at `now_ms` (a keyframe, a full update): a fresh start.
    pub fn all_changed(&mut self, now_ms: u64) {
        self.changed_ms.fill(Some(now_ms));
        self.sharpened_ms.fill(None);
        self.backoff.fill(0);
    }

    /// The macroblocks under `rects` (picture pixels) changed at `now_ms`.
    pub fn changed(&mut self, rects: &[Rect], now_ms: u64) {
        for r in rects {
            let Some((c0, r0, c1, r1)) = self.blocks(r) else { continue };
            for row in r0..r1 {
                for i in row * self.cols + c0..row * self.cols + c1 {
                    if self.changed_ms[i].is_none() {
                        // It was sharp: changed soon after its sharpening, or long settled?
                        self.backoff[i] = match self.sharpened_ms[i] {
                            Some(t) if now_ms < t + SETTLED_MS => (self.backoff[i] + 1).min(MAX_BACKOFF),
                            _ => 0,
                        };
                    }
                    self.changed_ms[i] = Some(now_ms);
                }
            }
        }
    }

    /// Takes the macroblocks unchanged for long enough, as rectangles in picture pixels
    /// (runs of a row, joined with the rows below when they span the same columns); they
    /// count as sharp from now on.
    pub fn take_due(&mut self, now_ms: u64) -> Vec<Rect> {
        let mut out: Vec<Rect> = Vec::new();
        // Runs of the previous row, by (first column, end column), with their index in `out`.
        let mut above: Vec<(usize, usize, usize)> = Vec::new();
        for row in 0..self.rows {
            let mut here = Vec::new();
            let mut col = 0;
            while col < self.cols {
                if !self.due(row, col, now_ms) {
                    col += 1;
                    continue;
                }
                let start = col;
                while col < self.cols && self.due(row, col, now_ms) {
                    self.changed_ms[row * self.cols + col] = None;
                    self.sharpened_ms[row * self.cols + col] = Some(now_ms);
                    col += 1;
                }
                let (x, y) = ((start * MB) as i32, (row * MB) as i32);
                let w = ((col * MB).min(self.width as usize) - start * MB) as i32;
                let h = ((row * MB + MB).min(self.height as usize) - row * MB) as i32;
                match above.iter().find(|a| a.0 == start && a.1 == col) {
                    Some(&(_, _, i)) => {
                        out[i].h += h;
                        here.push((start, col, i));
                    }
                    None => {
                        out.push(Rect::new(x, y, w, h));
                        here.push((start, col, out.len() - 1));
                    }
                }
            }
            above = here;
        }
        out
    }

    /// How long until the next macroblock is due, if any is waiting.
    pub fn next_due_ms(&self, now_ms: u64) -> Option<u64> {
        let first = (0..self.changed_ms.len()).filter_map(|i| self.due_at(i)).min()?;
        Some(first.saturating_sub(now_ms))
    }

    fn due_at(&self, i: usize) -> Option<u64> {
        self.changed_ms[i].map(|t| t + (self.after_ms << self.backoff[i]))
    }

    fn due(&self, row: usize, col: usize, now_ms: u64) -> bool {
        self.due_at(row * self.cols + col).is_some_and(|t| now_ms >= t)
    }

    fn blocks(&self, r: &Rect) -> Option<(usize, usize, usize, usize)> {
        let x0 = r.x.max(0) as usize / MB;
        let y0 = r.y.max(0) as usize / MB;
        let x1 = ((r.x as i64 + r.w as i64).max(0) as usize).div_ceil(MB).min(self.cols);
        let y1 = ((r.y as i64 + r.h as i64).max(0) as usize).div_ceil(MB).min(self.rows);
        (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_due_until_something_changed() {
        let mut q = Quiet::new(64, 64, 300);
        assert_eq!(q.next_due_ms(1000), None);
        assert!(q.take_due(1000).is_empty());
    }

    #[test]
    fn a_change_is_due_once_after_the_quiet_time() {
        let mut q = Quiet::new(64, 64, 300);
        q.changed(&[Rect::new(20, 20, 4, 4)], 1000);
        assert_eq!(q.next_due_ms(1100), Some(200));
        assert!(q.take_due(1299).is_empty());
        assert_eq!(q.take_due(1300), vec![Rect::new(16, 16, 16, 16)]);
        // Sharp now: nothing more until it changes again.
        assert_eq!(q.next_due_ms(1300), None);
        assert!(q.take_due(5000).is_empty());
    }

    #[test]
    fn a_new_change_restarts_the_wait() {
        let mut q = Quiet::new(64, 64, 300);
        q.changed(&[Rect::new(0, 0, 16, 16)], 1000);
        q.changed(&[Rect::new(0, 0, 16, 16)], 1200);
        assert!(q.take_due(1300).is_empty());
        assert_eq!(q.next_due_ms(1300), Some(200));
        assert_eq!(q.take_due(1500).len(), 1);
    }

    #[test]
    fn only_the_quiet_part_of_a_busy_picture_is_due() {
        let mut q = Quiet::new(64, 32, 300);
        q.all_changed(0);
        // A caret keeps blinking in the second macroblock of the top row.
        q.changed(&[Rect::new(16, 0, 2, 16)], 250);
        let due = q.take_due(300);
        assert_eq!(due, vec![Rect::new(0, 0, 16, 16), Rect::new(32, 0, 32, 16), Rect::new(0, 16, 64, 16)]);
        assert_eq!(q.take_due(550), vec![Rect::new(16, 0, 16, 16)]);
    }

    #[test]
    fn a_blinking_block_backs_off_and_settles_again() {
        let mut q = Quiet::new(16, 16, 300);
        let caret = [Rect::new(4, 4, 2, 10)];
        // Blinks every 500 ms: sharpened once, then it changes again before it is due.
        q.changed(&caret, 0);
        assert_eq!(q.take_due(300).len(), 1);
        for t in [500, 1000, 1500, 2000] {
            q.changed(&caret, t);
            assert!(q.take_due(t + 499).is_empty(), "sharpened a blink at {t}");
        }
        // Blinking stopped: sharpened after the longer wait.
        assert_eq!(q.next_due_ms(2000), Some(600));
        assert_eq!(q.take_due(2600).len(), 1);
        // Sharp for long, then changed: back to the short wait.
        q.changed(&caret, 2600 + SETTLED_MS);
        assert_eq!(q.next_due_ms(2600 + SETTLED_MS), Some(300));
    }

    #[test]
    fn rows_with_the_same_columns_join_and_edges_are_clipped() {
        let mut q = Quiet::new(40, 40, 0);
        q.all_changed(0);
        assert_eq!(q.take_due(0), vec![Rect::new(0, 0, 40, 40)]);
        q.changed(&[Rect::new(-5, 30, 100, 100)], 1);
        assert_eq!(q.take_due(1), vec![Rect::new(0, 16, 40, 24)]);
    }
}
