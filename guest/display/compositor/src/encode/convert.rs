//! BGRX → I420 (BT.601, limited range), for whole pictures or only their damaged
//! rectangles. Converting just what changed is what makes an idle-looking window cheap:
//! a blinking cursor converts a few hundred pixels, not the whole frame. Every region
//! goes through this same arithmetic, so partial updates never leave seams.
//!
//! The loops are written for the compiler to vectorise; large updates are split across
//! threads by row bands.

use caboose_display_protocol::Rect;

/// Destination planes. `y` holds `height` rows of `y_stride`; `u` and `v` hold
/// `height / 2` rows of their strides.
pub struct I420<'a> {
    pub y: &'a mut [u8],
    pub y_stride: usize,
    pub u: &'a mut [u8],
    pub u_stride: usize,
    pub v: &'a mut [u8],
    pub v_stride: usize,
}

#[inline(always)]
fn luma(b: i32, g: i32, r: i32) -> u8 {
    (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8
}

#[inline(always)]
fn chroma(b: i32, g: i32, r: i32) -> (u8, u8) {
    let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
    let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
    (u as u8, v as u8)
}

/// Converts one pair of rows (an even number of pixels). Written as iterator chains
/// over exact chunks so the compiler vectorises them.
#[inline(always)]
fn convert_pair(top: &[u8], bottom: &[u8], yt: &mut [u8], yb: &mut [u8], u: &mut [u8], v: &mut [u8]) {
    for (px, y) in top.chunks_exact(4).zip(yt.iter_mut()) {
        *y = luma(px[0] as i32, px[1] as i32, px[2] as i32);
    }
    for (px, y) in bottom.chunks_exact(4).zip(yb.iter_mut()) {
        *y = luma(px[0] as i32, px[1] as i32, px[2] as i32);
    }
    for (((t, b), u), v) in top.chunks_exact(8).zip(bottom.chunks_exact(8)).zip(u.iter_mut()).zip(v.iter_mut()) {
        let sum = |o: usize| t[o] as i32 + t[4 + o] as i32 + b[o] as i32 + b[4 + o] as i32;
        let (cu, cv) = chroma((sum(0) + 2) >> 2, (sum(1) + 2) >> 2, (sum(2) + 2) >> 2);
        *u = cu;
        *v = cv;
    }
}

/// Rounds a rectangle out to even coordinates and clips it to `width × height`.
/// Returns `(x0, y0, x1, y1)`.
pub fn even_clip(r: Rect, width: u32, height: u32) -> Option<(usize, usize, usize, usize)> {
    let x0 = (r.x.max(0) as usize) & !1;
    let y0 = (r.y.max(0) as usize) & !1;
    let x1 = ((r.x as i64 + r.w as i64).max(0) as usize).div_ceil(2) * 2;
    let y1 = ((r.y as i64 + r.h as i64).max(0) as usize).div_ceil(2) * 2;
    let (x1, y1) = (x1.min(width as usize), y1.min(height as usize));
    (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
}

/// One band of rows: the luma rows `top..top + rows` and the matching chroma rows.
struct Band<'a> {
    top: usize,
    rows: usize,
    y: &'a mut [u8],
    u: &'a mut [u8],
    v: &'a mut [u8],
}

fn convert_band(src: &[u8], stride: usize, clips: &[(usize, usize, usize, usize)], b: Band<'_>, ys: usize, us: usize, vs: usize) {
    for &(x0, y0, x1, y1) in clips {
        let lo = y0.max(b.top);
        let hi = y1.min(b.top + b.rows);
        let mut row = lo;
        while row + 1 < hi {
            let top = &src[row * stride..row * stride + x1 * 4];
            let bottom = &src[(row + 1) * stride..(row + 1) * stride + x1 * 4];
            let local = row - b.top;
            let (yt, yb) = b.y[local * ys..(local + 2) * ys].split_at_mut(ys);
            let c = local / 2;
            convert_pair(
                &top[x0 * 4..x1 * 4],
                &bottom[x0 * 4..x1 * 4],
                &mut yt[x0..x1],
                &mut yb[x0..x1],
                &mut b.u[c * us + x0 / 2..c * us + x1 / 2],
                &mut b.v[c * vs + x0 / 2..c * vs + x1 / 2],
            );
            row += 2;
        }
    }
}

/// Converts the given rectangles of `src` (all of it with `None`). `width` and
/// `height` are even; `src` has `height` rows of `stride` bytes.
pub fn bgrx_to_i420(src: &[u8], stride: usize, width: u32, height: u32, rects: Option<&[Rect]>, dst: I420<'_>) {
    let clips: Vec<_> = match rects {
        None => vec![(0, 0, width as usize, height as usize)],
        Some(rs) => rs.iter().filter_map(|r| even_clip(*r, width, height)).collect(),
    };
    let area: usize = clips.iter().map(|(x0, y0, x1, y1)| (x1 - x0) * (y1 - y0)).sum();
    let h = height as usize;
    let I420 { y, y_stride, u, u_stride, v, v_stride } = dst;
    let (y, u, v) = (&mut y[..h * y_stride], &mut u[..h / 2 * u_stride], &mut v[..h / 2 * v_stride]);
    // Below about a quarter of a 1080p picture, threads cost more than they save.
    let threads = if area > 512 * 1024 { std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(4) } else { 1 };
    if threads == 1 {
        convert_band(src, stride, &clips, Band { top: 0, rows: h, y, u, v }, y_stride, u_stride, v_stride);
        return;
    }
    let rows = (h / 2).div_ceil(threads) * 2;
    std::thread::scope(|scope| {
        let bands = y.chunks_mut(rows * y_stride).zip(u.chunks_mut(rows / 2 * u_stride)).zip(v.chunks_mut(rows / 2 * v_stride));
        for (i, ((y, u), v)) in bands.enumerate() {
            let clips = &clips;
            let band = Band { top: i * rows, rows: y.len() / y_stride, y, u, v };
            scope.spawn(move || convert_band(src, stride, clips, band, y_stride, u_stride, v_stride));
        }
    });
}

/// Finds the 16×16 macroblocks inside the damaged rectangles whose pixels differ
/// from `shadow` (the previous picture, same layout as `src`), copies them into the
/// shadow, and returns them merged into horizontal runs. Applications often damage
/// more than they repaint (a whole widget for a blinking caret); comparing is far
/// cheaper than converting, so only what really changed is converted and encoded.
pub fn changed_blocks(src: &[u8], shadow: &mut [u8], stride: usize, width: u32, height: u32, rects: &[Rect]) -> Vec<Rect> {
    const MB: usize = 16;
    let (w, h) = (width as usize, height as usize);
    let cols = w.div_ceil(MB);
    let rows = h.div_ceil(MB);
    let mut touched = vec![false; cols * rows];
    for r in rects {
        if let Some((x0, y0, x1, y1)) = even_clip(*r, width, height) {
            for my in y0 / MB..y1.div_ceil(MB) {
                touched[my * cols + x0 / MB..my * cols + x1.div_ceil(MB)].fill(true);
            }
        }
    }
    let mut changed: Vec<Rect> = Vec::new();
    for my in 0..rows {
        let (y0, bh) = (my * MB, (h - my * MB).min(MB));
        let mut run: Option<(usize, usize)> = None;
        for mx in 0..=cols {
            let differs = mx < cols && touched[my * cols + mx] && {
                let (x0, bw) = (mx * MB * 4, (w - mx * MB).min(MB) * 4);
                let mut differs = false;
                for y in y0..y0 + bh {
                    let at = y * stride + x0;
                    if differs {
                        shadow[at..at + bw].copy_from_slice(&src[at..at + bw]);
                    } else if src[at..at + bw] != shadow[at..at + bw] {
                        differs = true;
                        // Rows above matched; copy from here down.
                        shadow[at..at + bw].copy_from_slice(&src[at..at + bw]);
                    }
                }
                differs
            };
            match (differs, run) {
                (true, None) => run = Some((mx, mx)),
                (true, Some((a, _))) => run = Some((a, mx)),
                (false, Some((a, b))) => {
                    let x = a * MB;
                    let width = ((b + 1) * MB).min(w) - x;
                    changed.push(Rect::new(x as i32, y0 as i32, width as i32, bh as i32));
                    run = None;
                }
                (false, None) => {}
            }
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn planes(w: usize, h: usize) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        (vec![0; w * h], vec![0; w * h / 4], vec![0; w * h / 4])
    }

    fn run(src: &[u8], w: u32, h: u32, rects: Option<&[Rect]>, p: &mut (Vec<u8>, Vec<u8>, Vec<u8>)) {
        let (y, u, v) = p;
        bgrx_to_i420(src, w as usize * 4, w, h, rects, I420 { y, y_stride: w as usize, u, u_stride: w as usize / 2, v, v_stride: w as usize / 2 });
    }

    #[test]
    fn limited_range_reference_colours() {
        // black, white, red, green, blue (B, G, R, X)
        let cases = [([0, 0, 0], (16, 128, 128)), ([255, 255, 255], (235, 128, 128)), ([0, 0, 255], (82, 90, 240)), ([0, 255, 0], (144, 54, 34)), ([255, 0, 0], (41, 240, 110))];
        for (bgr, (ey, eu, ev)) in cases {
            let src: Vec<u8> = (0..4).flat_map(|_| [bgr[0], bgr[1], bgr[2], 0]).collect();
            let mut p = planes(2, 2);
            run(&src, 2, 2, None, &mut p);
            assert_eq!((p.0[0], p.1[0], p.2[0]), (ey, eu, ev), "{bgr:?}");
        }
    }

    #[test]
    fn damaged_rectangles_only_touch_their_blocks() {
        let (w, h) = (8u32, 8u32);
        let src = vec![255u8; (w * h * 4) as usize];
        let mut p = planes(8, 8);
        run(&src, w, h, Some(&[Rect::new(3, 3, 1, 1)]), &mut p);
        // (3,3) rounds out to the 2x2 block at (2,2)..(4,4).
        for y in 0..8 {
            for x in 0..8 {
                let inside = (2..4).contains(&x) && (2..4).contains(&y);
                assert_eq!(p.0[y * 8 + x], if inside { 235 } else { 0 }, "({x},{y})");
            }
        }
        assert_eq!(p.1[4 + 1], 128);
        assert_eq!(p.1[0], 0);
    }

    #[test]
    fn threaded_and_single_conversions_agree() {
        let (w, h) = (1280u32, 720u32);
        let src: Vec<u8> = (0..w * h * 4).map(|i| (i.wrapping_mul(2654435761) >> 24) as u8).collect();
        let mut a = planes(w as usize, h as usize);
        run(&src, w, h, None, &mut a);
        let mut b = planes(w as usize, h as usize);
        for band in 0..9 {
            run(&src, w, h, Some(&[Rect::new(0, band * 80, w as i32, 80)]), &mut b);
        }
        assert!(a == b);
    }

    #[test]
    fn only_blocks_that_differ_from_the_shadow_are_reported() {
        let (w, h) = (64u32, 48u32);
        let stride = w as usize * 4;
        let mut src = vec![0u8; stride * h as usize];
        let mut shadow = src.clone();
        // One pixel in block (2, 1), one in block (3, 2); a damage rectangle covering
        // everything.
        src[(20 * w as usize + 40) * 4] = 255;
        src[(40 * w as usize + 63) * 4 + 1] = 7;
        let changed = changed_blocks(&src, &mut shadow, stride, w, h, &[Rect::new(0, 0, 64, 48)]);
        assert_eq!(changed, vec![Rect::new(32, 16, 16, 16), Rect::new(48, 32, 16, 16)]);
        assert!(src == shadow, "changed blocks are copied into the shadow");
        assert!(changed_blocks(&src, &mut shadow, stride, w, h, &[Rect::new(0, 0, 64, 48)]).is_empty());
    }

    #[test]
    fn changes_outside_the_damage_are_not_looked_at() {
        let (w, h) = (64u32, 32u32);
        let stride = w as usize * 4;
        let mut src = vec![0u8; stride * h as usize];
        let mut shadow = src.clone();
        src[0] = 1;
        assert!(changed_blocks(&src, &mut shadow, stride, w, h, &[Rect::new(32, 0, 16, 16)]).is_empty());
    }

    #[test]
    fn adjacent_blocks_merge_into_runs() {
        let (w, h) = (64u32, 16u32);
        let stride = w as usize * 4;
        let mut src = vec![0u8; stride * h as usize];
        let mut shadow = src.clone();
        src[16 * 4] = 1;
        src[32 * 4] = 1;
        assert_eq!(changed_blocks(&src, &mut shadow, stride, w, h, &[Rect::new(0, 0, 64, 16)]), vec![Rect::new(16, 0, 32, 16)]);
    }

    #[test]
    fn clipping_rounds_out_and_stays_inside() {
        assert_eq!(even_clip(Rect::new(-5, 3, 10, 2), 8, 8), Some((0, 2, 6, 6)));
        assert_eq!(even_clip(Rect::new(7, 7, 10, 10), 8, 8), Some((6, 6, 8, 8)));
        assert_eq!(even_clip(Rect::new(10, 10, 1, 1), 8, 8), None);
    }
}
