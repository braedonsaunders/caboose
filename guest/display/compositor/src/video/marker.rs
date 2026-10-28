//! The passthrough placeholder marker (guest/vaapi `marker.h`): what a passthrough video
//! surface holds instead of decoded pixels, and how the compositor finds it in a window.
//!
//! A marked surface is an 8 × 8 grid of tags over its whole coded area; each tag is 7 × 7
//! modules (56 × 56 modules in all). A module is dark (Y = 16) or bright (Y = 56). In a
//! tag, ring modules form a checkerboard border (bright when x + y is even); the 25
//! interior modules carry the payload: tag column (bits 0–2), row (3–5), the stream tag
//! the compositor assigned (6–11), the frame sequence number mod 64 (12–17), and a CRC-7
//! (x⁷ + x³ + 1) over bits 17..0 (18–24).
//!
//! Because each tag carries its position, one surviving tag gives the whole frame's
//! rectangle on screen, and the sequence number names the frame the application is
//! showing. This is a port of the driver's reference detector; both find the same hits.

pub const TAGS: usize = 8;
pub const MODS: usize = 7;
pub const GRID: usize = TAGS * MODS;
#[cfg(test)]
pub const DARK: u8 = 16;
#[cfg(test)]
pub const BRIGHT: u8 = 56;
const SCAN_THRESHOLD: u8 = 30;

pub fn crc7(data18: u32) -> u8 {
    let mut crc: u32 = 0;
    for i in (0..18).rev() {
        let input = (data18 >> i) & 1;
        let top = (crc >> 6) & 1;
        crc = (crc << 1) & 0x7f;
        if input ^ top != 0 {
            crc ^= 0x09;
        }
    }
    crc as u8
}

pub fn payload(col: u32, row: u32, tag: u32, seq: u32) -> u32 {
    let d = (col & 7) | (row & 7) << 3 | (tag & 63) << 6 | (seq & 63) << 12;
    d | (crc7(d) as u32) << 18
}

fn tag_module(x: usize, y: usize, payload: u32) -> bool {
    if x == 0 || y == 0 || x == MODS - 1 || y == MODS - 1 {
        return (x + y) & 1 == 0;
    }
    (payload >> ((y - 1) * 5 + (x - 1))) & 1 == 1
}

/// Whether grid module (i, j) of a frame marked (tag, seq) is bright.
pub fn module(i: usize, j: usize, tag: u32, seq: u32) -> bool {
    let p = payload((i / MODS) as u32, (j / MODS) as u32, tag, seq);
    tag_module(i % MODS, j % MODS, p)
}

/// Paints the marker into an 8-bit luma plane, as the driver does (for tests).
#[cfg(test)]
pub fn paint(luma: &mut [u8], pitch: usize, w: usize, h: usize, tag: u32, seq: u32) {
    for j in 0..GRID {
        for i in 0..GRID {
            let v = if module(i, j, tag, seq) { BRIGHT } else { DARK };
            for y in j * h / GRID..(j + 1) * h / GRID {
                luma[y * pitch + i * w / GRID..y * pitch + (i + 1) * w / GRID].fill(v);
            }
        }
    }
}

/// A marked frame found on screen.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub tag: u32,
    pub seq: u32,
    pub tags_found: usize,
    /// The whole coded frame in image pixels (may extend past the image when cropped).
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// The visible part, image pixels, `[x0, x1) × [y0, y1)`.
    pub clip: (i32, i32, i32, i32),
}

#[derive(Clone, Copy)]
struct Run {
    start: i32,
    len: i32,
    bright: bool,
}

#[derive(Clone, Copy)]
struct Found {
    x0: f64,
    y0: f64,
    lx: f64,
    ly: f64,
    col: u32,
    row: u32,
    tag: u32,
    seq: u32,
}

struct Image<'a> {
    g: &'a [u8],
    w: usize,
    h: usize,
    stride: usize,
}

impl Image<'_> {
    fn at(&self, x: usize, y: usize) -> u8 {
        self.g[y * self.stride + x]
    }
}

fn runs_of(px: impl Fn(usize) -> u8, n: usize, runs: &mut Vec<Run>) {
    runs.clear();
    let mut i = 0;
    while i < n {
        let b = px(i) > SCAN_THRESHOLD;
        let mut j = i + 1;
        while j < n && (px(j) > SCAN_THRESHOLD) == b {
            j += 1;
        }
        runs.push(Run { start: i as i32, len: (j - i) as i32, bright: b });
        i = j;
    }
}

/// Runs k..k+4 are dark, bright, dark, bright, dark of one length, flanked by bright runs
/// at least half that long. Returns the module length.
fn five_runs(r: &[Run], k: isize) -> Option<f64> {
    if k < 1 || k as usize + 5 >= r.len() || r[k as usize].bright {
        return None;
    }
    let k = k as usize;
    let mut sum = 0.0;
    for i in 0..5 {
        if r[k + i].bright != (i & 1 == 1) {
            return None;
        }
        sum += r[k + i].len as f64;
    }
    let l = sum / 5.0;
    if l < 1.5 {
        return None;
    }
    if (0..5).any(|i| ((r[k + i].len as f64) - l).abs() > 0.35 * l + 1.0) {
        return None;
    }
    if (r[k - 1].len as f64) < 0.5 * l || (r[k + 5].len as f64) < 0.5 * l {
        return None;
    }
    Some(l)
}

fn sample(img: &Image<'_>, cx: f64, cy: f64, rx: f64, ry: f64) -> Option<f64> {
    let x0 = ((cx - rx).floor() as i64).max(0);
    let x1 = ((cx + rx).floor() as i64).min(img.w as i64 - 1);
    let y0 = ((cy - ry).floor() as i64).max(0);
    let y1 = ((cy + ry).floor() as i64).min(img.h as i64 - 1);
    if x1 < x0 || y1 < y0 {
        return None;
    }
    let mut sum = 0u64;
    for y in y0..=y1 {
        for x in x0..=x1 {
            sum += img.at(x as usize, y as usize) as u64;
        }
    }
    Some(sum as f64 / ((x1 - x0 + 1) * (y1 - y0 + 1)) as f64)
}

// Indexing mirrors the driver's reference detector, module by module.
#[allow(clippy::needless_range_loop)]
fn read_tag(img: &Image<'_>, x0: f64, y0: f64, lx: f64, ly: f64) -> Option<Found> {
    if x0 < -0.5 || y0 < -0.5 || x0 + 7.0 * lx > img.w as f64 + 0.5 || y0 + 7.0 * ly > img.h as f64 + 0.5 {
        return None;
    }
    let mut v = [[0f64; 7]; 7];
    let (mut bright, mut dark, mut nb, mut nd) = (0.0, 0.0, 0, 0);
    for y in 0..7 {
        for x in 0..7 {
            v[y][x] = sample(img, x0 + (x as f64 + 0.5) * lx, y0 + (y as f64 + 0.5) * ly, lx / 5.0, ly / 5.0)?;
            if x == 0 || y == 0 || x == 6 || y == 6 {
                if (x + y) & 1 == 0 {
                    bright += v[y][x];
                    nb += 1;
                } else {
                    dark += v[y][x];
                    nd += 1;
                }
            }
        }
    }
    bright /= nb as f64;
    dark /= nd as f64;
    if bright - dark < 12.0 {
        return None;
    }
    let t = (bright + dark) / 2.0;
    let mut payload = 0u32;
    for y in 0..7 {
        for x in 0..7 {
            let b = v[y][x] > t;
            if x == 0 || y == 0 || x == 6 || y == 6 {
                if b != ((x + y) & 1 == 0) {
                    return None;
                }
            } else if b {
                payload |= 1 << ((y - 1) * 5 + (x - 1));
            }
        }
    }
    let data = payload & 0x3ffff;
    if crc7(data) as u32 != payload >> 18 {
        return None;
    }
    Some(Found { x0, y0, lx, ly, col: data & 7, row: (data >> 3) & 7, tag: (data >> 6) & 63, seq: (data >> 12) & 63 })
}

fn known(found: &[Found], x: f64, y: f64) -> bool {
    found.iter().any(|f| x > f.x0 - f.lx && x < f.x0 + 7.0 * f.lx && y >= f.y0 - f.ly && y < f.y0 + 7.0 * f.ly)
}

/// Least-squares fit of `pos = origin + idx × span` over the found tags; returns
/// (origin, module length).
fn fit(pos: &[f64], idx: &[f64], len: &[f64]) -> (f64, f64) {
    let n = pos.len() as f64;
    let (mut si, mut sp, mut sii, mut sip, mut sl) = (0.0, 0.0, 0.0, 0.0, 0.0);
    for i in 0..pos.len() {
        si += idx[i];
        sp += pos[i];
        sii += idx[i] * idx[i];
        sip += idx[i] * pos[i];
        sl += len[i];
    }
    let den = n * sii - si * si;
    if pos.len() >= 2 && den > 1e-9 {
        let slope = (n * sip - si * sp) / den;
        (((sp - slope * si) / n), slope / MODS as f64)
    } else {
        let module = sl / n;
        ((sp - si * MODS as f64 * module) / n, module)
    }
}

fn pixel_matches(img: &Image<'_>, x: i32, y: i32, hit: &Hit, horizontal: bool) -> bool {
    let (mx, my) = (hit.w / GRID as f64, hit.h / GRID as f64);
    let b = img.at(x as usize, y as usize) > SCAN_THRESHOLD;
    (-1..=1).any(|d| {
        let fx = (x as f64 + 0.5 + if horizontal { d as f64 } else { 0.0 } - hit.x) / mx;
        let fy = (y as f64 + 0.5 + if horizontal { 0.0 } else { d as f64 } - hit.y) / my;
        fx >= 0.0
            && fy >= 0.0
            && fx < GRID as f64
            && fy < GRID as f64
            && module(fx as usize, fy as usize, hit.tag, hit.seq) == b
    })
}

/// Fraction of sample points along a pixel column (or row) that match the marker.
fn line_match(img: &Image<'_>, hit: &Hit, pos: i32, vertical_line: bool, from: i32, to: i32) -> f64 {
    let m = if vertical_line { hit.h / GRID as f64 } else { hit.w / GRID as f64 };
    let origin = if vertical_line { hit.y } else { hit.x };
    let (mut good, mut total) = (0, 0);
    let mut c = origin + m / 2.0;
    while c < origin + GRID as f64 * m {
        let p = c as i32;
        c += m;
        if p < from || p >= to {
            continue;
        }
        let (x, y) = if vertical_line { (pos, p) } else { (p, pos) };
        good += pixel_matches(img, x, y, hit, vertical_line) as i32;
        total += 1;
    }
    if total > 0 {
        good as f64 / total as f64
    } else {
        0.0
    }
}

fn find_clip(img: &Image<'_>, hit: &mut Hit, f: &[Found]) {
    let (mut x0, mut y0, mut x1, mut y1) = (img.w as i32, img.h as i32, 0i32, 0i32);
    for t in f {
        x0 = x0.min(t.x0.ceil() as i32);
        y0 = y0.min(t.y0.ceil() as i32);
        x1 = x1.max((t.x0 + 7.0 * t.lx).floor() as i32);
        y1 = y1.max((t.y0 + 7.0 * t.ly).floor() as i32);
    }
    let lx = hit.x.ceil().max(0.0) as i32;
    let rx = (hit.x + hit.w).floor().min(img.w as f64) as i32;
    let ty = hit.y.ceil().max(0.0) as i32;
    let by = (hit.y + hit.h).floor().min(img.h as f64) as i32;
    while x0 > lx && line_match(img, hit, x0 - 1, true, y0, y1) >= 0.9 {
        x0 -= 1;
    }
    while x1 < rx && line_match(img, hit, x1, true, y0, y1) >= 0.9 {
        x1 += 1;
    }
    while y0 > ty && line_match(img, hit, y0 - 1, false, x0, x1) >= 0.9 {
        y0 -= 1;
    }
    while y1 < by && line_match(img, hit, y1, false, x0, x1) >= 0.9 {
        y1 += 1;
    }
    hit.clip = (x0, y0, x1, y1);
}

/// Finds marked frames in an 8-bit luma image. One hit per marked frame on screen (the
/// same stream can appear twice, mirrored), at most `max_hits`.
pub fn detect(grey: &[u8], width: usize, height: usize, stride: usize, max_hits: usize) -> Vec<Hit> {
    let mut hits = Vec::new();
    if width == 0 || height == 0 || width > 1 << 16 || height > 1 << 16 || grey.len() < (height - 1) * stride + width {
        return hits;
    }
    let img = Image { g: grey, w: width, h: height, stride };
    let mut rr = Vec::with_capacity(width + 1);
    let mut cr = Vec::with_capacity(height + 1);
    let mut found: Vec<Found> = Vec::new();
    for y in 0..height {
        runs_of(|x| img.at(x, y), width, &mut rr);
        for k in 1..rr.len().saturating_sub(5) {
            let Some(lx) = five_runs(&rr, k as isize) else { continue };
            let x0 = rr[k].start as f64 - lx;
            if known(&found, x0 + 3.5 * lx, y as f64) {
                continue;
            }
            let xc = (x0 + 0.5 * lx) as i64;
            if xc < 0 || xc >= width as i64 {
                continue;
            }
            runs_of(|j| img.at(xc as usize, j), height, &mut cr);
            let mut at = 0usize;
            while at + 1 < cr.len() && cr[at + 1].start <= y as i32 {
                at += 1;
            }
            for j in at as isize - 6..=at as isize + 1 {
                let Some(ly) = five_runs(&cr, j) else { continue };
                let y0 = cr[j as usize].start as f64 - ly;
                if (y as f64) < y0 || y as f64 >= y0 + 7.0 * ly {
                    continue;
                }
                if let Some(f) = read_tag(&img, x0, y0, lx, ly) {
                    found.push(f);
                    break;
                }
            }
        }
    }
    // Group tags into frames: same stream tag and the same implied frame rectangle.
    let mut group = vec![false; found.len()];
    for i in 0..found.len() {
        if hits.len() >= max_hits {
            break;
        }
        if group[i] {
            continue;
        }
        let fi = found[i];
        let fx = fi.x0 - fi.col as f64 * 7.0 * fi.lx;
        let fy = fi.y0 - fi.row as f64 * 7.0 * fi.ly;
        let mut members: Vec<Found> = Vec::new();
        let mut votes = [0u32; 64];
        for k in i..found.len() {
            let fk = found[k];
            if group[k] || fk.tag != fi.tag {
                continue;
            }
            let kx = fk.x0 - fk.col as f64 * 7.0 * fk.lx;
            let ky = fk.y0 - fk.row as f64 * 7.0 * fk.ly;
            // Per-tag estimates drift by a module or two across the frame; two copies
            // of one frame never overlap by more than a quarter.
            if (kx - fx).abs() > 14.0 * fi.lx
                || (ky - fy).abs() > 14.0 * fi.ly
                || (fk.lx - fi.lx).abs() > 0.25 * fi.lx
                || (fk.ly - fi.ly).abs() > 0.25 * fi.ly
            {
                continue;
            }
            group[k] = true;
            members.push(fk);
            votes[fk.seq as usize] += 1;
        }
        let ix: Vec<f64> = members.iter().map(|m| m.col as f64).collect();
        let iy: Vec<f64> = members.iter().map(|m| m.row as f64).collect();
        let xs: Vec<f64> = members.iter().map(|m| m.x0).collect();
        let ys: Vec<f64> = members.iter().map(|m| m.y0).collect();
        let lxs: Vec<f64> = members.iter().map(|m| m.lx).collect();
        let lys: Vec<f64> = members.iter().map(|m| m.ly).collect();
        let (ox, mx) = fit(&xs, &ix, &lxs);
        let (oy, my) = fit(&ys, &iy, &lys);
        let seq = (0..64).fold(0usize, |best, v| if votes[v] > votes[best] { v } else { best }) as u32;
        let mut hit = Hit {
            tag: fi.tag,
            seq,
            tags_found: members.len(),
            x: ox,
            y: oy,
            w: mx * GRID as f64,
            h: my * GRID as f64,
            clip: (0, 0, 0, 0),
        };
        find_clip(&img, &mut hit, &members);
        hits.push(hit);
    }
    hits
}

/// Finds markers in a BGRX picture. The picture is reduced to half resolution luma
/// first (modules of a frame shown at least 170 pixels wide stay above the detector's
/// 1.5-pixel minimum), and hits are scaled back to picture pixels.
pub fn detect_bgrx(px: &[u8], stride: usize, width: usize, height: usize, max_hits: usize) -> Vec<Hit> {
    let (gw, gh) = (width / 2, height / 2);
    if gw == 0 || gh == 0 {
        return Vec::new();
    }
    let mut grey = vec![0u8; gw * gh];
    let luma = |p: &[u8]| (((66 * p[2] as u32 + 129 * p[1] as u32 + 25 * p[0] as u32 + 128) >> 8) + 16) as u8;
    for y in 0..gh {
        let (top, bottom) = (&px[2 * y * stride..], &px[(2 * y + 1) * stride..]);
        for (x, g) in grey[y * gw..(y + 1) * gw].iter_mut().enumerate() {
            let i = 8 * x;
            let sum = luma(&top[i..]) as u32
                + luma(&top[i + 4..]) as u32
                + luma(&bottom[i..]) as u32
                + luma(&bottom[i + 4..]) as u32;
            *g = ((sum + 2) / 4) as u8;
        }
    }
    detect(&grey, gw, gh, gw, max_hits).into_iter().map(|h| refine(px, stride, width, height, h)).collect()
}

/// Re-detects a half-resolution hit at full resolution, within its visible part plus a
/// margin, so its rectangle is exact to the pixel. Falls back to the doubled hit.
fn refine(px: &[u8], stride: usize, width: usize, height: usize, half: Hit) -> Hit {
    let doubled = Hit {
        x: half.x * 2.0,
        y: half.y * 2.0,
        w: half.w * 2.0,
        h: half.h * 2.0,
        clip: (half.clip.0 * 2, half.clip.1 * 2, half.clip.2 * 2, half.clip.3 * 2),
        ..half.clone()
    };
    let margin = 8;
    let x0 = (doubled.clip.0 - margin).max(0) as usize;
    let y0 = (doubled.clip.1 - margin).max(0) as usize;
    let x1 = ((doubled.clip.2 + margin) as usize).min(width);
    let y1 = ((doubled.clip.3 + margin) as usize).min(height);
    if x1 <= x0 || y1 <= y0 {
        return doubled;
    }
    let (w, h) = (x1 - x0, y1 - y0);
    let mut grey = vec![0u8; w * h];
    for y in 0..h {
        let row = &px[(y0 + y) * stride + x0 * 4..];
        for (x, g) in grey[y * w..(y + 1) * w].iter_mut().enumerate() {
            let p = &row[x * 4..];
            *g = (((66 * p[2] as u32 + 129 * p[1] as u32 + 25 * p[0] as u32 + 128) >> 8) + 16) as u8;
        }
    }
    let (ox, oy) = (x0 as f64, y0 as f64);
    detect(&grey, w, h, w, 4)
        .into_iter()
        .find(|f| f.tag == half.tag)
        .map(|f| Hit {
            x: f.x + ox,
            y: f.y + oy,
            clip: (f.clip.0 + x0 as i32, f.clip.1 + y0 as i32, f.clip.2 + x0 as i32, f.clip.3 + y0 as i32),
            ..f
        })
        .unwrap_or(doubled)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A screen with a marked frame of `fw × fh` scaled to `dw × dh` at (`dx`, `dy`) on a
    /// `sw × sh` background, by nearest-neighbour sampling.
    #[allow(clippy::too_many_arguments)]
    fn screen(
        sw: usize,
        sh: usize,
        fw: usize,
        fh: usize,
        dx: i64,
        dy: i64,
        dw: usize,
        dh: usize,
        tag: u32,
        seq: u32,
    ) -> Vec<u8> {
        let mut frame = vec![0u8; fw * fh];
        paint(&mut frame, fw, fw, fh, tag, seq);
        let mut s = vec![200u8; sw * sh];
        for y in 0..sh as i64 {
            for x in 0..sw as i64 {
                let (u, v) = (x - dx, y - dy);
                if u >= 0 && v >= 0 && (u as usize) < dw && (v as usize) < dh {
                    let fx = u as usize * fw / dw;
                    let fy = v as usize * fh / dh;
                    s[y as usize * sw + x as usize] = frame[fy * fw + fx];
                }
            }
        }
        s
    }

    #[test]
    fn crc_and_payload_match_the_driver() {
        // Values from guest/vaapi's tests: crc7 of 0 is 0, payloads round-trip their
        // fields, and every payload's top 7 bits are the CRC of its low 18.
        assert_eq!(crc7(0), 0);
        let p = payload(3, 5, 42, 17);
        assert_eq!(p & 7, 3);
        assert_eq!((p >> 3) & 7, 5);
        assert_eq!((p >> 6) & 63, 42);
        assert_eq!((p >> 12) & 63, 17);
        assert_eq!(crc7(p & 0x3ffff) as u32, p >> 18);
    }

    #[test]
    fn finds_an_unscaled_frame() {
        let s = screen(800, 600, 448, 336, 100, 80, 448, 336, 9, 33);
        let hits = detect(&s, 800, 600, 800, 4);
        assert_eq!(hits.len(), 1);
        let h = &hits[0];
        assert_eq!((h.tag, h.seq), (9, 33));
        assert!((h.x - 100.0).abs() < 1.0 && (h.y - 80.0).abs() < 1.0, "{h:?}");
        assert!((h.w - 448.0).abs() < 2.0 && (h.h - 336.0).abs() < 2.0, "{h:?}");
        assert_eq!(h.tags_found, 64);
    }

    #[test]
    fn finds_a_scaled_and_cropped_frame() {
        // 1920x1088 coded, shown at 960x544 with its top 100 rows and left 50 columns off
        // screen.
        let s = screen(1000, 700, 1920, 1088, -50, -100, 960, 544, 3, 63);
        let hits = detect(&s, 1000, 700, 1000, 4);
        assert_eq!(hits.len(), 1, "{hits:?}");
        let h = &hits[0];
        assert_eq!((h.tag, h.seq), (3, 63));
        assert!((h.x + 50.0).abs() < 2.0 && (h.y + 100.0).abs() < 2.0, "{h:?}");
        assert!((h.w - 960.0).abs() < 4.0 && (h.h - 544.0).abs() < 4.0, "{h:?}");
        let (x0, y0, x1, y1) = h.clip;
        assert!(x0 <= 1 && y0 <= 1, "{h:?}");
        assert!((x1 - 910).abs() <= 2 && (y1 - 444).abs() <= 2, "{h:?}");
    }

    #[test]
    fn a_partly_covered_frame_reports_its_visible_part() {
        let mut s = screen(900, 700, 560, 560, 100, 100, 560, 560, 12, 1);
        // A dialog over the bottom-right quarter.
        for y in 380..700 {
            s[y * 900 + 380..y * 900 + 900].fill(230);
        }
        let hits = detect(&s, 900, 700, 900, 4);
        assert_eq!(hits.len(), 1);
        let h = &hits[0];
        assert!((h.w - 560.0).abs() < 2.0, "the whole frame is still known: {h:?}");
        let (x0, y0, _x1, y1) = h.clip;
        assert_eq!((x0, y0), (100, 100));
        assert!(y1 >= 650, "{h:?}");
    }

    #[test]
    fn finds_a_marker_in_a_bgrx_picture_as_an_application_shows_it() {
        // Limited-range Y 16 / 56 with neutral chroma reach the screen as RGB 0 / 47.
        let (w, h) = (1280usize, 720usize);
        let grey = screen(w, h, 640, 360, 300, 200, 640, 360, 21, 40);
        let mut bgrx = vec![255u8; w * h * 4];
        for (i, g) in grey.iter().enumerate() {
            let v = match *g {
                DARK => 0,
                BRIGHT => 47,
                _ => 230,
            };
            bgrx[i * 4..i * 4 + 3].fill(v);
        }
        let hits = detect_bgrx(&bgrx, w * 4, w, h, 4);
        assert_eq!(hits.len(), 1, "{hits:?}");
        let hit = &hits[0];
        assert_eq!((hit.tag, hit.seq), (21, 40));
        // Refined at full resolution: exact to the pixel.
        assert!((hit.x - 300.0).abs() < 0.6 && (hit.y - 200.0).abs() < 0.6, "{hit:?}");
        assert!((hit.w - 640.0).abs() < 1.0 && (hit.h - 360.0).abs() < 1.0, "{hit:?}");
        let (x0, y0, x1, y1) = hit.clip;
        assert!((x0, y0) == (300, 200) && (x1 - 940).abs() <= 1 && (y1 - 560).abs() <= 1, "{hit:?}");
    }

    #[test]
    fn nothing_is_found_in_ordinary_content() {
        let s: Vec<u8> = (0..640 * 480).map(|i: usize| ((i * 7919) % 251) as u8).collect();
        assert!(detect(&s, 640, 480, 640, 4).is_empty());
        let flat = vec![16u8; 320 * 240];
        assert!(detect(&flat, 320, 240, 320, 4).is_empty());
    }

    #[test]
    fn two_streams_are_two_hits() {
        let mut s = screen(1200, 500, 448, 448, 20, 20, 448, 448, 1, 5);
        let b = screen(1200, 500, 448, 448, 700, 30, 448, 448, 2, 6);
        for y in 0..500 {
            for x in 650..1200 {
                s[y * 1200 + x] = b[y * 1200 + x];
            }
        }
        let mut hits = detect(&s, 1200, 500, 1200, 4);
        hits.sort_by_key(|h| h.tag);
        assert_eq!(hits.iter().map(|h| (h.tag, h.seq)).collect::<Vec<_>>(), vec![(1, 5), (2, 6)]);
    }
}
