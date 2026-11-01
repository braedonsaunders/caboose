//! Which bytes of a wl_shm buffer a texture upload carries.
//!
//! Each client buffer has its own staging buffer on the GPU, laid out exactly as the shared
//! memory is (row for row, the same stride), and an upload copies only the client's damage
//! into it before the GPU copies those rectangles into the surface's texture. The phone's
//! Vulkan driver flushes what changed in a mapped range by comparing it with what the range
//! held before (docs/gpu-live.md): since a range only ever holds the same buffer's same
//! pixels, an upload of a damaged area that barely changed (a typed glyph in a line the
//! toolkit redrew whole) sends the few blocks that differ.

/// One rectangle to upload: where it is in the buffer (pixels) and the byte range of the
/// staging buffer its rows lie in (from its first pixel to its last).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Upload {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub offset: usize,
    pub len: usize,
}

/// More rectangles than this are uploaded as their bounding box.
pub const MAX_RECTS: usize = 16;

/// The uploads for `damage` (buffer pixels; `None` for the whole buffer) in a buffer of
/// `width` x `height` pixels, `stride` bytes apart, of `bpp` bytes per pixel. Damage is
/// clipped to the buffer; empty rectangles are dropped.
pub fn uploads(damage: Option<&[(i32, i32, i32, i32)]>, width: i32, height: i32, stride: usize, bpp: usize) -> Vec<Upload> {
    if width <= 0 || height <= 0 || bpp == 0 || stride < width as usize * bpp {
        return Vec::new();
    }
    let whole = [(0, 0, width, height)];
    let mut rects: Vec<(i32, i32, i32, i32)> = damage
        .unwrap_or(&whole)
        .iter()
        .filter_map(|&(x, y, w, h)| {
            let (x0, y0) = (x.max(0), y.max(0));
            let (x1, y1) = (x.saturating_add(w).min(width), y.saturating_add(h).min(height));
            (x1 > x0 && y1 > y0).then_some((x0, y0, x1 - x0, y1 - y0))
        })
        .collect();
    if rects.len() > MAX_RECTS {
        let x0 = rects.iter().map(|r| r.0).min().unwrap();
        let y0 = rects.iter().map(|r| r.1).min().unwrap();
        let x1 = rects.iter().map(|r| r.0 + r.2).max().unwrap();
        let y1 = rects.iter().map(|r| r.1 + r.3).max().unwrap();
        rects = vec![(x0, y0, x1 - x0, y1 - y0)];
    }
    rects
        .into_iter()
        .map(|(x, y, w, h)| {
            let offset = y as usize * stride + x as usize * bpp;
            let end = (y + h - 1) as usize * stride + (x + w) as usize * bpp;
            Upload { x, y, w, h, offset, len: end - offset }
        })
        .collect()
}

/// Copies an upload's rows from the client's buffer (`pixels`, the buffer's first pixel at
/// index 0) into its mapped staging range (`mapped`, the range at `upload.offset`).
pub fn copy_rows(upload: &Upload, pixels: &[u8], stride: usize, bpp: usize, mapped: &mut [u8]) {
    let row_bytes = upload.w as usize * bpp;
    for row in 0..upload.h as usize {
        let at = upload.offset + row * stride;
        let into = row * stride;
        mapped[into..into + row_bytes].copy_from_slice(&pixels[at..at + row_bytes]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_whole_buffer_is_one_upload_of_every_row() {
        // An odd-sized dialog (300x161) whose rows are padded to 1216 bytes.
        let all = uploads(None, 300, 161, 1216, 4);
        assert_eq!(all, vec![Upload { x: 0, y: 0, w: 300, h: 161, offset: 0, len: 160 * 1216 + 1200 }]);
    }

    #[test]
    fn damage_is_clipped_to_the_buffer_and_empty_damage_dropped() {
        let damage = [(-5, -5, 10, 10), (295, 150, 20, 20), (10, 10, 0, 5), (400, 0, 5, 5)];
        let got = uploads(Some(&damage), 300, 161, 1200, 4);
        assert_eq!(got.len(), 2);
        assert_eq!((got[0].x, got[0].y, got[0].w, got[0].h), (0, 0, 5, 5));
        assert_eq!((got[1].x, got[1].y, got[1].w, got[1].h), (295, 150, 5, 11));
        assert_eq!(got[1].offset, 150 * 1200 + 295 * 4);
        assert_eq!(got[1].len, 10 * 1200 + 5 * 4);
    }

    #[test]
    fn a_glyph_uploads_only_its_cell() {
        let got = uploads(Some(&[(80, 40, 9, 18)]), 800, 600, 3200, 4);
        assert_eq!(got, vec![Upload { x: 80, y: 40, w: 9, h: 18, offset: 40 * 3200 + 320, len: 17 * 3200 + 36 }]);
    }

    #[test]
    fn many_rectangles_become_their_bounding_box() {
        let damage: Vec<_> = (0..MAX_RECTS as i32 + 1).map(|i| (i * 10, i * 2, 4, 4)).collect();
        let got = uploads(Some(&damage), 400, 400, 1600, 4);
        assert_eq!(got.len(), 1);
        assert_eq!((got[0].x, got[0].y, got[0].w, got[0].h), (0, 0, MAX_RECTS as i32 * 10 + 4, MAX_RECTS as i32 * 2 + 4));
    }

    #[test]
    fn a_short_stride_or_empty_buffer_uploads_nothing() {
        assert!(uploads(None, 300, 161, 1196, 4).is_empty());
        assert!(uploads(None, 0, 161, 1200, 4).is_empty());
    }

    #[test]
    fn rows_land_at_the_same_offsets_as_in_the_buffer() {
        let (w, h, stride, bpp) = (5, 4, 24, 4);
        let pixels: Vec<u8> = (0..stride * h).map(|i| i as u8).collect();
        let up = uploads(Some(&[(1, 1, 3, 2)]), w, h as i32, stride, bpp)[0];
        let mut staging = vec![0u8; stride * h];
        copy_rows(&up, &pixels, stride, bpp, &mut staging[up.offset..up.offset + up.len]);
        for row in 0..h {
            for col in 0..w as usize {
                let i = row * stride + col * bpp;
                let inside = (1..3).contains(&row) && (1..4).contains(&col);
                assert_eq!(staging[i..i + bpp] == pixels[i..i + bpp], inside, "row {row} col {col}");
            }
        }
    }
}
