//! The probe's scroll-report check (`--scroll`): it keeps every `scroll.tree`, reads the
//! frame tag out of each decoded picture, and, with `--ruler`, reads the page's true
//! scroll position out of the picture too, so each report is checked against the very
//! picture its tag is in.
//!
//! The ruler is the one `scripts/pages/scroll-ruler.html` draws: down the content, at
//! x = `RULER_X`, every `BAND`-pixel band of the document shows its index in 16 black or
//! white blocks of `RULER_BLOCK` pixels, most significant first.

use caboose_display_protocol::{self as proto, scroll_tag};
use std::collections::{BTreeMap, VecDeque};

pub const BAND: i32 = 16;
pub const RULER_X: i32 = 8;
pub const RULER_BLOCK: i32 = 8;
const RULER_BITS: i32 = 16;
/// Reports kept to look tags up in.
const KEPT: usize = 512;

/// A luma plane, picture pixels.
pub struct Luma<'a> {
    pub data: &'a [u8],
    pub stride: usize,
    pub width: i32,
    pub height: i32,
}

impl Luma<'_> {
    fn at(&self, x: i32, y: i32) -> Option<f32> {
        (x >= 0 && y >= 0 && x < self.width && y < self.height).then(|| self.data[y as usize * self.stride + x as usize] as f32)
    }
    /// The mean of the 3x3 pixels around a point.
    fn mean(&self, x: i32, y: i32) -> Option<f32> {
        let mut sum = 0.0;
        for dy in -1..=1 {
            for dx in -1..=1 {
                sum += self.at(x + dx, y + dy)?;
            }
        }
        Some(sum / 9.0)
    }
    /// The mean of three pixels in a row: a ruler row is read one line at a time.
    fn row_mean(&self, x: i32, y: i32) -> Option<f32> {
        Some((self.at(x - 1, y)? + self.at(x, y)? + self.at(x + 1, y)?) / 3.0)
    }
}

/// Window-local display pixels to picture pixels.
#[derive(Clone, Copy)]
pub struct Mapping {
    pub sx: f64,
    pub sy: f64,
}

impl Mapping {
    pub fn new(rect: proto::Rect, crop: proto::Rect) -> Self {
        Mapping { sx: crop.w as f64 / rect.w.max(1) as f64, sy: crop.h as f64 / rect.h.max(1) as f64 }
    }
}

/// The tag in a picture, read where the report says it is.
pub fn read_tag(luma: &Luma, map: Mapping, rect: proto::Rect) -> Option<u32> {
    let side = rect.w as f64 / scroll_tag::BLOCKS as f64;
    let y = ((rect.y as f64 + rect.h as f64 / 2.0) * map.sy) as i32;
    let samples: Option<Vec<f32>> = (0..scroll_tag::BLOCKS)
        .map(|i| luma.mean(((rect.x as f64 + (i as f64 + 0.5) * side) * map.sx) as i32, y))
        .collect();
    scroll_tag::decode(&samples?)
}

/// The ruler band index at a window row, if it reads cleanly.
fn band_at(luma: &Luma, map: Mapping, x0: i32, y: i32) -> Option<u32> {
    let mut n = 0u32;
    for i in 0..RULER_BITS {
        let x = x0 + RULER_X + i * RULER_BLOCK + RULER_BLOCK / 2;
        let l = luma.row_mean((x as f64 * map.sx) as i32, (y as f64 * map.sy) as i32)?;
        if (40.0..215.0).contains(&l) {
            return None;
        }
        n = n << 1 | (l >= 128.0) as u32;
    }
    Some(n)
}

/// The scroller's content offset as the picture shows it: the first band edge below the
/// top of `clip` (window pixels), at whole-pixel precision.
pub fn read_ruler(luma: &Luma, map: Mapping, clip: proto::Rect, fixed: &[proto::Rect]) -> Option<f64> {
    // Below whatever is fixed over the top of the scroller (a sticky header).
    let covered = fixed.iter().filter(|f| f.y <= clip.y + 1).map(|f| f.y + f.h).max().unwrap_or(clip.y);
    let top = covered.max(clip.y) + 2;
    let first = band_at(luma, map, clip.x, top)?;
    for y in top + 1..(clip.y + clip.h).min(top + 3 * BAND) {
        match band_at(luma, map, clip.x, y) {
            Some(n) if n == first + 1 => return Some(((first + 1) as i32 * BAND - (y - clip.y)) as f64),
            Some(n) if n == first => {}
            _ => return None,
        }
    }
    None
}

#[derive(Default)]
pub struct ScrollCheck {
    pub trees: u64,
    reports: VecDeque<proto::ScrollTree>,
    pub latest: BTreeMap<u64, proto::ScrollTree>,
    pub tagged: u64,
    pub matched: u64,
    pub unmatched: u64,
    pub untagged: u64,
    pub ruler_checked: u64,
    pub ruler_unreadable: u64,
    pub ruler_bad: u64,
    pub ruler_max_error: f64,
    /// Pictures the newest report received before them would have placed wrongly: what
    /// binding by arrival instead of by tag would do.
    pub newest_bad: u64,
    pub epochs: u64,
    pub sent_seq: u64,
    pub applied: u64,
}

impl ScrollCheck {
    pub fn tree(&mut self, t: proto::ScrollTree) {
        self.trees += 1;
        if self.latest.get(&t.id).is_some_and(|l| l.epoch != t.epoch) {
            self.epochs += 1;
        }
        self.applied = self.applied.max(t.applied);
        self.latest.insert(t.id, t.clone());
        self.reports.push_back(t);
        while self.reports.len() > KEPT {
            self.reports.pop_front();
        }
    }

    /// One decoded picture of window `id`.
    pub fn picture(&mut self, id: u64, luma: &Luma, map: Mapping, ruler: bool) {
        let newest = self.latest.get(&id).and_then(|t| t.scrollers.first().map(|s| s.offset[1]));
        let Some(rect) = self.latest.get(&id).and_then(|t| t.tag_rect) else { return };
        let Some(tag) = read_tag(luma, map, rect) else {
            self.untagged += 1;
            return;
        };
        self.tagged += 1;
        let Some(report) = self.reports.iter().rev().find(|t| t.id == id && t.tag == Some(tag)).cloned() else {
            self.unmatched += 1;
            return;
        };
        self.matched += 1;
        if !ruler {
            return;
        }
        let Some(primary) = report.scrollers.first() else { return };
        match read_ruler(luma, map, primary.rect, &primary.fixed) {
            None => self.ruler_unreadable += 1,
            Some(shown) => {
                self.ruler_checked += 1;
                if newest.is_some_and(|n| (shown - n).abs() > 1.5) {
                    self.newest_bad += 1;
                }
                let error = (shown - primary.offset[1]).abs();
                self.ruler_max_error = self.ruler_max_error.max(error);
                if error > 1.5 {
                    self.ruler_bad += 1;
                    eprintln!(
                        "scroll: picture tagged {tag:#08x} shows offset {shown}, its report says {}",
                        primary.offset[1]
                    );
                }
            }
        }
    }

    /// The next drive: `dy` content pixels down the window's primary scroller.
    pub fn target(&mut self, id: u64, dy: f64) -> Option<proto::Message> {
        let scroller = self.latest.get(&id)?.scrollers.first()?.id;
        self.sent_seq += 1;
        Some(proto::Message::ScrollTarget(proto::ScrollTarget { id, scroller, seq: self.sent_seq, delta: [0.0, dy] }))
    }

    pub fn json(&self) -> String {
        format!(
            "{{\"trees\":{},\"epochs\":{},\"tagged\":{},\"matched\":{},\"unmatched\":{},\"untagged\":{},\"ruler_checked\":{},\"ruler_unreadable\":{},\"ruler_bad\":{},\"ruler_max_error\":{:.2},\"newest_bad\":{},\"sent_seq\":{},\"applied\":{}}}",
            self.trees, self.epochs, self.tagged, self.matched, self.unmatched, self.untagged, self.ruler_checked,
            self.ruler_unreadable, self.ruler_bad, self.ruler_max_error, self.newest_bad, self.sent_seq, self.applied
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A picture of the ruler page scrolled to `offset`, with a tag at `tag_rect`.
    fn picture(w: i32, h: i32, offset: i32, tag: Option<(proto::Rect, u32)>) -> Vec<u8> {
        let mut p = vec![16u8; (w * h) as usize];
        for y in 0..h {
            let band = ((y + offset) / BAND) as u32;
            for i in 0..RULER_BITS {
                let white = band >> (RULER_BITS - 1 - i) & 1 == 1;
                for x in RULER_X + i * RULER_BLOCK..RULER_X + (i + 1) * RULER_BLOCK {
                    p[(y * w + x) as usize] = if white { 235 } else { 16 };
                }
            }
        }
        if let Some((r, value)) = tag {
            let side = r.w / 32;
            for (i, white) in scroll_tag::encode(value).iter().enumerate() {
                for y in r.y..r.y + r.h {
                    for x in r.x + i as i32 * side..r.x + (i as i32 + 1) * side {
                        p[(y * w + x) as usize] = if *white { 235 } else { 16 };
                    }
                }
            }
        }
        p
    }

    #[test]
    fn reads_the_ruler_and_the_tag_of_a_picture() {
        let (w, h) = (400, 300);
        let tag_rect = proto::Rect::new(0, 280, 384, 12);
        let data = picture(w, h, 1234, Some((tag_rect, 0x01_0203)));
        let luma = Luma { data: &data, stride: w as usize, width: w, height: h };
        let map = Mapping { sx: 1.0, sy: 1.0 };
        assert_eq!(read_tag(&luma, map, tag_rect), Some(0x01_0203));
        assert_eq!(read_ruler(&luma, map, proto::Rect::new(0, 0, w, 270), &[]), Some(1234.0));
        assert_eq!(read_ruler(&luma, map, proto::Rect::new(0, 0, w, 270), &[proto::Rect::new(0, 0, w, 48)]), Some(1234.0));
    }
}
