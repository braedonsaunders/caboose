//! Scroll offload: finds when a window's new picture is the picture the client shows,
//! moved (a scroll), so it can go as a `frame.copy` and lossless tiles for whatever the
//! move does not reproduce instead of as a coded picture (docs/display.md, "Copies").
//!
//! Everything here is pure: the picture the client shows and the new one in, a plan out.
//! A plan is exact: applying its copy and then its tiles to the shown picture gives the
//! new picture, byte for byte, in the region it covers, and it touches nothing outside it.
//! The match share only decides whether a copy is worth sending.
//!
//! The search is bounded so that it costs far less than the picture it replaces: one hash
//! per row of the damaged region in each picture, a vote over those hashes for the
//! vertical shift, column hashes only when the window was just scrolled sideways, and an
//! exact comparison of at most [`MAX_CANDIDATES`] shifts that gives up as soon as too many
//! blocks differ.

use caboose_display_protocol::Rect;
use std::collections::HashMap;

/// Tiles and the match count are in blocks of this size, the encoder's macroblocks.
pub const BLOCK: usize = 16;
/// A copy is sent only when it reproduces at least this share (percent) of its region's
/// blocks exactly; the other blocks go as tiles.
pub const MIN_MATCH_PERCENT: usize = 90;
/// Damage smaller than this (picture pixels) goes as tiles or a picture: a copy is for
/// scrolls of a large area.
pub const MIN_REGION_PX: usize = 128 * 128;
/// At most this many tile rectangles follow a copy.
pub const MAX_TILE_RECTS: usize = 64;
/// At most this many shifts are compared exactly.
pub const MAX_CANDIDATES: usize = 4;
/// A voted shift needs this many distinct rows (or columns) agreeing on it.
const MIN_VOTES: usize = 2;

/// BGRX pixels, 4 bytes each: `data` starts at the picture's top-left pixel, rows
/// `stride` bytes apart.
#[derive(Clone, Copy)]
pub struct Plane<'a> {
    pub data: &'a [u8],
    pub stride: usize,
}

impl Plane<'_> {
    fn holds(&self, width: usize, height: usize) -> bool {
        height > 0 && self.stride >= width * 4 && self.data.len() >= (height - 1) * self.stride + width * 4
    }

    fn row(&self, y: usize, x0: usize, x1: usize) -> &[u8] {
        &self.data[y * self.stride + x0 * 4..y * self.stride + x1 * 4]
    }
}

/// A copy and the tiles that complete it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    /// The pixels to copy (picture pixels), as the client shows them.
    pub src: Rect,
    /// Where `src`'s top-left pixel lands.
    pub dst: (i32, i32),
    /// The blocks the copy does not reproduce, joined into rectangles: the client gets the
    /// new picture's pixels there, after the copy.
    pub tiles: Vec<Rect>,
    /// Everywhere the client's picture now differs from the encoder's last coded picture,
    /// for the next picture to code: the copied area out to whole blocks, and the tiles.
    pub stale: Vec<Rect>,
}

/// The copy that turns `shown` into `new` in the damaged region, when one reproduces at
/// least [`MIN_MATCH_PERCENT`] of the region's blocks. `damage` is what changed (picture
/// pixels); outside it the two pictures are the same. `hints` are shifts the window was
/// just scrolled by (picture pixels, the content's movement), tried besides the voted ones.
pub fn plan(
    shown: Plane<'_>,
    new: Plane<'_>,
    width: u32,
    height: u32,
    damage: &[Rect],
    hints: &[(i32, i32)],
) -> Option<Plan> {
    let (w, h) = (width as usize, height as usize);
    if !shown.holds(w, h) || !new.holds(w, h) {
        return None;
    }
    let region = block_bounds(damage, w, h)?;
    let Region { x0, y0, x1, y1 } = region;
    if (x1 - x0) * (y1 - y0) < MIN_REGION_PX {
        return None;
    }
    let shown_rows: Vec<u64> = (y0..y1).map(|y| hash(shown.row(y, x0, x1))).collect();
    let new_rows: Vec<u64> = (y0..y1).map(|y| hash(new.row(y, x0, x1))).collect();
    // The rows that changed: rows above and below them are the same in both pictures, and
    // a copy that leaves them alone needs no tiles for them.
    let first = new_rows.iter().zip(&shown_rows).position(|(a, b)| a != b)?;
    let last = new_rows.iter().zip(&shown_rows).rposition(|(a, b)| a != b)?;
    let band = (y0 + first, y0 + last + 1);
    let (band_h, region_w) = (band.1 - band.0, x1 - x0);
    let fits = |&(dx, dy): &(i32, i32)| {
        (dx, dy) != (0, 0) && (dx.unsigned_abs() as usize) * 2 < region_w && (dy.unsigned_abs() as usize) * 2 < band_h
    };

    let mut candidates: Vec<(i32, i32)> = Vec::with_capacity(MAX_CANDIDATES);
    let mut add = |c: (i32, i32)| {
        if fits(&c) && !candidates.contains(&c) && candidates.len() < MAX_CANDIDATES {
            candidates.push(c);
        }
    };
    if let Some(dy) = vote(&shown_rows[first..=last], &new_rows[first..=last], band_h / 2) {
        add((0, dy));
    }
    if hints.iter().any(|&(dx, _)| dx != 0) {
        let shown_columns = column_hashes(shown, x0, x1, band.0, band.1);
        let new_columns = column_hashes(new, x0, x1, band.0, band.1);
        if let Some(dx) = vote(&shown_columns, &new_columns, region_w / 2) {
            add((dx, 0));
        }
    }
    for &hint in hints {
        add(hint);
    }

    let blocks = (x1 - x0).div_ceil(BLOCK) * (y1 - y0).div_ceil(BLOCK);
    let band_blocks = (x1 - x0).div_ceil(BLOCK) * (band.1.div_ceil(BLOCK) - band.0 / BLOCK);
    // More differing blocks than this, and the copy is not worth it: the share the copy
    // must reproduce, and at most half of the blocks that changed.
    let allowed = (blocks * (100 - MIN_MATCH_PERCENT) / 100).min(band_blocks / 2);
    candidates.into_iter().find_map(|shift| {
        let copy = Shift::new(region, band, shift)?;
        let missed = copy.misses(shown, new, allowed, region)?;
        let tiles = rectangles(&missed, x1, y1);
        if tiles.len() > MAX_TILE_RECTS {
            return None;
        }
        let mut stale = vec![copy.blocks(region)];
        stale.extend_from_slice(&tiles);
        Some(Plan { src: copy.src(), dst: (copy.x0 as i32, copy.y0 as i32), tiles, stale })
    })
}

/// A block-aligned rectangle of the picture, clipped to it: `x0..x1` by `y0..y1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Region {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
}

/// The bounding box of `damage` in the picture, out to whole blocks.
fn block_bounds(damage: &[Rect], w: usize, h: usize) -> Option<Region> {
    let mut bounds: Option<Region> = None;
    for r in damage {
        let x0 = r.x.max(0) as usize;
        let y0 = r.y.max(0) as usize;
        let x1 = ((r.x as i64 + r.w as i64).max(0) as usize).min(w);
        let y1 = ((r.y as i64 + r.h as i64).max(0) as usize).min(h);
        if x0 >= x1 || y0 >= y1 {
            continue;
        }
        bounds = Some(match bounds {
            None => Region { x0, y0, x1, y1 },
            Some(b) => Region { x0: b.x0.min(x0), y0: b.y0.min(y0), x1: b.x1.max(x1), y1: b.y1.max(y1) },
        });
    }
    bounds.map(|b| Region {
        x0: b.x0 / BLOCK * BLOCK,
        y0: b.y0 / BLOCK * BLOCK,
        x1: (b.x1.div_ceil(BLOCK) * BLOCK).min(w),
        y1: (b.y1.div_ceil(BLOCK) * BLOCK).min(h),
    })
}

/// The copy of the band of changed rows by `(dx, dy)`: its destination `x0..x1` by
/// `y0..y1`, inside the band, and its source that far back.
#[derive(Debug, Clone, Copy)]
struct Shift {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    dx: isize,
    dy: isize,
}

impl Shift {
    fn new(region: Region, band: (usize, usize), (dx, dy): (i32, i32)) -> Option<Self> {
        let (dx, dy) = (dx as isize, dy as isize);
        let (rx0, rx1) = (region.x0 as isize, region.x1 as isize);
        let (b0, b1) = (band.0 as isize, band.1 as isize);
        let (x0, x1) = (rx0.max(rx0 + dx), rx1.min(rx1 + dx));
        let (y0, y1) = (b0.max(b0 + dy), b1.min(b1 + dy));
        (x0 < x1 && y0 < y1).then_some(Shift {
            x0: x0 as usize,
            y0: y0 as usize,
            x1: x1 as usize,
            y1: y1 as usize,
            dx,
            dy,
        })
    }

    fn src(&self) -> Rect {
        Rect::new(
            (self.x0 as isize - self.dx) as i32,
            (self.y0 as isize - self.dy) as i32,
            (self.x1 - self.x0) as i32,
            (self.y1 - self.y0) as i32,
        )
    }

    /// The destination out to whole blocks, inside the region.
    fn blocks(&self, region: Region) -> Rect {
        let x0 = self.x0 / BLOCK * BLOCK;
        let y0 = self.y0 / BLOCK * BLOCK;
        let x1 = (self.x1.div_ceil(BLOCK) * BLOCK).min(region.x1);
        let y1 = (self.y1.div_ceil(BLOCK) * BLOCK).min(region.y1);
        Rect::new(x0 as i32, y0 as i32, (x1 - x0) as i32, (y1 - y0) as i32)
    }

    /// The region's blocks (top-left corners, in rows) that the copy does not turn into
    /// `new`'s pixels exactly; `None` once there are more than `allowed`.
    fn misses(&self, shown: Plane<'_>, new: Plane<'_>, allowed: usize, region: Region) -> Option<Vec<(usize, usize)>> {
        let mut missed = Vec::new();
        for by in (region.y0..region.y1).step_by(BLOCK) {
            let bye = (by + BLOCK).min(region.y1);
            for bx in (region.x0..region.x1).step_by(BLOCK) {
                let bxe = (bx + BLOCK).min(region.x1);
                if !(by..bye).all(|y| self.row_matches(shown, new, y, bx, bxe)) {
                    missed.push((bx, by));
                    if missed.len() > allowed {
                        return None;
                    }
                }
            }
        }
        Some(missed)
    }

    /// Whether row `y`, columns `x0..x1`, shows `new`'s pixels after the copy.
    fn row_matches(&self, shown: Plane<'_>, new: Plane<'_>, y: usize, x0: usize, x1: usize) -> bool {
        let after = new.row(y, x0, x1);
        if y < self.y0 || y >= self.y1 {
            return after == shown.row(y, x0, x1);
        }
        // Columns x0..cs and ce..x1 keep what the client showed; cs..ce are copied.
        let cs = x0.max(self.x0).min(x1);
        let ce = x1.min(self.x1).max(cs);
        let before = shown.row(y, x0, x1);
        if after[..(cs - x0) * 4] != before[..(cs - x0) * 4] || after[(ce - x0) * 4..] != before[(ce - x0) * 4..] {
            return false;
        }
        if cs == ce {
            return true;
        }
        let sy = (y as isize - self.dy) as usize;
        let (sx0, sx1) = ((cs as isize - self.dx) as usize, (ce as isize - self.dx) as usize);
        after[(cs - x0) * 4..(ce - x0) * 4] == *shown.row(sy, sx0, sx1)
    }
}

/// The shift most changed rows agree on: row `i` of `new` equal to row `i - shift` of
/// `shown`, at least [`MIN_VOTES`] times, with `|shift| < limit`. Only rows whose hash
/// occurs once in `shown` vote, so blank rows, which match anywhere, say nothing.
fn vote(shown: &[u64], new: &[u64], limit: usize) -> Option<i32> {
    let mut once: HashMap<u64, Option<usize>> = HashMap::with_capacity(shown.len());
    for (i, &h) in shown.iter().enumerate() {
        once.entry(h).and_modify(|at| *at = None).or_insert(Some(i));
    }
    let mut votes: HashMap<i32, usize> = HashMap::new();
    for (i, &h) in new.iter().enumerate() {
        if h == shown[i] {
            continue;
        }
        if let Some(&Some(j)) = once.get(&h) {
            let shift = i as i32 - j as i32;
            if (shift.unsigned_abs() as usize) < limit {
                *votes.entry(shift).or_default() += 1;
            }
        }
    }
    votes
        .into_iter()
        .filter(|&(_, n)| n >= MIN_VOTES)
        // The most votes; between equals, the smaller shift.
        .max_by_key(|&(shift, n)| (n, std::cmp::Reverse(shift.unsigned_abs()), shift))
        .map(|(shift, _)| shift)
}

const K: u64 = 0x9e37_79b9_7f4a_7c15;

fn finish(mut h: u64) -> u64 {
    h ^= h >> 32;
    h = h.wrapping_mul(K);
    h ^ (h >> 29)
}

/// A 64-bit hash of a row of pixels, four words at a time.
fn hash(bytes: &[u8]) -> u64 {
    let mut lanes: [u64; 4] =
        [0x243f_6a88_85a3_08d3, 0x1319_8a2e_0370_7344, 0xa409_3822_299f_31d0, 0x082e_fa98_ec4e_6c89];
    let mut chunks = bytes.chunks_exact(32);
    for chunk in &mut chunks {
        for (lane, word) in lanes.iter_mut().zip(chunk.chunks_exact(8)) {
            *lane = (*lane ^ u64::from_le_bytes(word.try_into().unwrap())).wrapping_mul(K).rotate_left(29);
        }
    }
    let mut h = lanes[0] ^ lanes[1].rotate_left(16) ^ lanes[2].rotate_left(32) ^ lanes[3].rotate_left(48);
    for &b in chunks.remainder() {
        h = (h ^ b as u64).wrapping_mul(K);
    }
    finish(h ^ bytes.len() as u64)
}

/// A hash of each column `x0..x1` over rows `y0..y1`, read row by row.
fn column_hashes(p: Plane<'_>, x0: usize, x1: usize, y0: usize, y1: usize) -> Vec<u64> {
    let mut columns = vec![0x243f_6a88_85a3_08d3u64; x1 - x0];
    for y in y0..y1 {
        for (column, px) in columns.iter_mut().zip(p.row(y, x0, x1).chunks_exact(4)) {
            let v = u32::from_le_bytes(px.try_into().unwrap()) as u64;
            *column = (*column ^ v).wrapping_mul(K).rotate_left(23);
        }
    }
    columns.into_iter().map(finish).collect()
}

/// Blocks (top-left corners, in rows) as rectangles, clipped to `x1`, `y1`: runs along
/// each block row, then runs over the same columns in consecutive rows joined.
fn rectangles(blocks: &[(usize, usize)], x1: usize, y1: usize) -> Vec<Rect> {
    let mut runs: Vec<Rect> = Vec::new();
    for &(bx, by) in blocks {
        let (bw, bh) = ((bx + BLOCK).min(x1) - bx, (by + BLOCK).min(y1) - by);
        match runs.last_mut() {
            Some(r) if r.y as usize == by && (r.x + r.w) as usize == bx => r.w += bw as i32,
            _ => runs.push(Rect::new(bx as i32, by as i32, bw as i32, bh as i32)),
        }
    }
    let mut out: Vec<Rect> = Vec::with_capacity(runs.len());
    for r in runs {
        match out.iter_mut().find(|o| o.x == r.x && o.w == r.w && o.y + o.h == r.y) {
            Some(o) => o.h += r.h,
            None => out.push(r),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 480;
    const H: usize = 480;

    /// A document of text-like rows: every 18th line group ends in four blank rows, which
    /// are all alike; the others are noise, so each is its own. `(sx, sy)` is how far it
    /// is scrolled.
    fn doc(x: usize, y: usize) -> [u8; 4] {
        if y % 18 >= 14 {
            return [0xf4, 0xf4, 0xf4, 0];
        }
        let mut z = (y as u64) << 32 | x as u64;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^= z >> 31;
        [z as u8, (z >> 8) as u8, (z >> 16) as u8, 0]
    }

    fn page(sx: usize, sy: usize) -> Vec<u8> {
        let mut p = vec![0; W * H * 4];
        for y in 0..H {
            for x in 0..W {
                p[(y * W + x) * 4..][..4].copy_from_slice(&doc(x + sx, y + sy));
            }
        }
        p
    }

    fn plane(p: &[u8]) -> Plane<'_> {
        Plane { data: p, stride: W * 4 }
    }

    fn attempt(shown: Plane<'_>, new: Plane<'_>, damage: &[Rect], hints: &[(i32, i32)]) -> Option<Plan> {
        super::plan(shown, new, W as u32, H as u32, damage, hints)
    }

    fn all() -> Vec<Rect> {
        vec![Rect::new(0, 0, W as i32, H as i32)]
    }

    fn fill(p: &mut [u8], r: Rect, v: u8) {
        for y in r.y as usize..(r.y + r.h) as usize {
            p[(y * W + r.x as usize) * 4..][..r.w as usize * 4].fill(v);
        }
    }

    /// What the client shows after the plan: `shown`, then the copy (as if from a copy of
    /// the picture taken first, since source and destination overlap), then the tiles with
    /// `new`'s pixels.
    fn apply(shown: &[u8], new: &[u8], plan: &Plan) -> Vec<u8> {
        let before = shown.to_vec();
        let mut out = shown.to_vec();
        let (sx, sy, w, h) = (plan.src.x as usize, plan.src.y as usize, plan.src.w as usize, plan.src.h as usize);
        let (dx, dy) = (plan.dst.0 as usize, plan.dst.1 as usize);
        for row in 0..h {
            out[((dy + row) * W + dx) * 4..][..w * 4].copy_from_slice(&before[((sy + row) * W + sx) * 4..][..w * 4]);
        }
        for t in &plan.tiles {
            for y in t.y as usize..(t.y + t.h) as usize {
                let at = (y * W + t.x as usize) * 4;
                out[at..at + t.w as usize * 4].copy_from_slice(&new[at..at + t.w as usize * 4]);
            }
        }
        out
    }

    fn exact(shown: &[u8], new: &[u8], damage: &[Rect], hints: &[(i32, i32)]) -> Plan {
        let plan = attempt(plane(shown), plane(new), damage, hints).expect("a copy");
        assert!(apply(shown, new, &plan) == new, "the copy and its tiles must give the new picture exactly: {plan:?}");
        plan
    }

    fn tiled_px(plan: &Plan) -> usize {
        plan.tiles.iter().map(|t| (t.w * t.h) as usize).sum()
    }

    #[test]
    fn a_vertical_scroll_is_a_copy_and_its_exposed_edge() {
        let (shown, new) = (page(0, 0), page(0, 18));
        let plan = exact(&shown, &new, &all(), &[]);
        assert_eq!((plan.src, plan.dst), (Rect::new(0, 18, W as i32, (H - 18) as i32), (0, 0)));
        // The rows 462..480 that scrolled into view, in whole blocks.
        assert_eq!(plan.tiles, vec![Rect::new(0, 448, W as i32, 32)]);
        assert_eq!(plan.stale, vec![Rect::new(0, 0, W as i32, 464), Rect::new(0, 448, W as i32, 32)]);
        // Scrolling the other way.
        let plan = exact(&new, &shown, &all(), &[]);
        assert_eq!(plan.dst.1 - plan.src.y, 18);
    }

    #[test]
    fn a_horizontal_scroll_is_found_when_the_window_was_scrolled_sideways() {
        let (shown, new) = (page(0, 0), page(24, 0));
        // The hint is the client's delta, not the application's exact step; voting finds it.
        let plan = exact(&shown, &new, &all(), &[(-20, 0)]);
        assert_eq!((plan.src.x, plan.dst.0), (24, 0));
        assert_eq!(plan.tiles, vec![Rect::new(448, 0, 32, H as i32)]);
        // Without a sideways scroll the columns are not looked at.
        assert!(attempt(plane(&shown), plane(&new), &all(), &[]).is_none());
    }

    #[test]
    fn a_static_header_stays_out_of_the_copy() {
        let (mut shown, mut new) = (page(0, 0), page(0, 30));
        // A toolbar that does not scroll.
        fill(&mut shown, Rect::new(0, 0, W as i32, 64), 0x55);
        fill(&mut new, Rect::new(0, 0, W as i32, 64), 0x55);
        let plan = exact(&shown, &new, &all(), &[]);
        assert!(plan.src.y >= 64 && plan.dst.1 >= 64, "{plan:?}");
        assert!(plan.tiles.iter().all(|t| t.y >= 64), "{plan:?}");
    }

    #[test]
    fn a_changed_caret_inside_the_scroll_goes_as_a_tile() {
        let (shown, mut new) = (page(0, 0), page(0, 18));
        // A caret blinks on, and an unrelated widget changes, while the page scrolls.
        let caret = Rect::new(200, 96, 2, 16);
        fill(&mut new, caret, 0x00);
        fill(&mut new, Rect::new(36, 290, 20, 9), 0x80);
        let plan = exact(&shown, &new, &all(), &[]);
        assert_eq!((plan.src.y, plan.dst.1), (18, 0));
        // The caret's block, the widget's two blocks and the exposed edge.
        assert!(plan.tiles.contains(&Rect::new(192, 96, 16, 16)), "{plan:?}");
        assert_eq!(tiled_px(&plan), 16 * 16 + 2 * 16 * 16 + W * 32);
    }

    #[test]
    fn the_hinted_scroll_is_used_when_rows_cannot_vote() {
        // Repeating content: every row occurs more than once, so nothing votes, but the
        // scroll the window was given checks out exactly.
        let stripes = |sy: usize| {
            let mut p = vec![0; W * H * 4];
            for y in 0..H {
                for x in 0..W {
                    let v = (((y + sy) % 64) * 4 + x % 3) as u8;
                    p[(y * W + x) * 4..][..4].copy_from_slice(&[v, v, v, 0]);
                }
            }
            p
        };
        let (shown, new) = (stripes(0), stripes(32));
        assert!(attempt(plane(&shown), plane(&new), &all(), &[]).is_none());
        let plan = exact(&shown, &new, &all(), &[(0, -32)]);
        assert_eq!(plan.dst.1 - plan.src.y, -32);
    }

    #[test]
    fn too_few_matching_blocks_is_no_copy() {
        let (shown, mut new) = (page(0, 0), page(0, 18));
        // A sixth of the blocks change besides the scroll: over the 10% the copy may miss.
        for by in (0..H).step_by(16 * 6) {
            fill(&mut new, Rect::new(0, by as i32, W as i32, 16), 0x11);
        }
        assert!(attempt(plane(&shown), plane(&new), &all(), &[(0, -18)]).is_none());
    }

    #[test]
    fn nothing_moved_is_no_copy() {
        let shown = page(0, 0);
        // Unchanged: there is nothing to copy.
        assert!(attempt(plane(&shown), plane(&shown), &all(), &[(0, -18)]).is_none());
        // Changed, but not moved: a picture, not a copy.
        let mut new = shown.clone();
        fill(&mut new, Rect::new(0, 0, W as i32, H as i32), 0x33);
        assert!(attempt(plane(&shown), plane(&new), &all(), &[(0, -18), (5, 0)]).is_none());
        // Small damage is for tiles.
        assert!(attempt(plane(&shown), plane(&page(0, 18)), &[Rect::new(0, 0, 64, 64)], &[]).is_none());
    }

    #[test]
    fn shifts_of_half_the_region_or_more_are_not_tried() {
        let (shown, new) = (page(0, 0), page(0, 250));
        assert!(attempt(plane(&shown), plane(&new), &all(), &[(0, -250)]).is_none());
        let (shown, new) = (page(0, 0), page(240, 0));
        assert!(attempt(plane(&shown), plane(&new), &all(), &[(-240, 0)]).is_none());
    }

    #[test]
    fn the_copy_stays_inside_the_damage() {
        let (shown, scrolled) = (page(0, 0), page(0, 18));
        // Only the right half (an editor beside a fixed sidebar) scrolled.
        let mut new = shown.clone();
        for y in 0..H {
            let at = (y * W + 240) * 4;
            new[at..at + 240 * 4].copy_from_slice(&scrolled[at..at + 240 * 4]);
        }
        let damage = [Rect::new(240, 0, 240, H as i32)];
        let plan = exact(&shown, &new, &damage, &[]);
        assert!(plan.src.x >= 240 && plan.dst.0 >= 240, "{plan:?}");
        assert!(plan.tiles.iter().chain(&plan.stale).all(|r| r.x >= 240), "{plan:?}");
    }

    #[test]
    fn short_or_mismatched_buffers_are_no_copy() {
        let (shown, new) = (page(0, 0), page(0, 18));
        assert!(attempt(plane(&shown[..W * 4 * 10]), plane(&new), &all(), &[]).is_none());
        assert!(attempt(Plane { data: &shown, stride: 8 }, plane(&new), &all(), &[]).is_none());
    }

    #[test]
    fn blocks_join_into_rows_then_columns() {
        let blocks = [(0, 0), (16, 0), (48, 0), (0, 16), (16, 16), (48, 16)];
        assert_eq!(rectangles(&blocks, 60, 30), vec![Rect::new(0, 0, 32, 30), Rect::new(48, 0, 12, 30)]);
    }
}
