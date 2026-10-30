//! Pictures of alpha windows (popups): lossless RGBA tiles, never codec frames.
//!
//! A popup's rounded corners and shadow lie inside its window geometry, and a codec
//! frame has no alpha to carry them, so an alpha window is sent only as PNG tiles of
//! the 16×16 blocks that changed, compared against a shadow of what the client shows
//! (as [`super::lavc::LavcEncoder::tiles`] does for small changes of other windows),
//! and the whole picture when nothing has been sent yet or a keyframe is asked for.

use super::lavc::{merge_columns, MAX_TILES};
use super::{convert, EncodeError, Pixels, Tiles};
use caboose_display_protocol::Rect;

pub struct AlphaTiler {
    width: u32,
    height: u32,
    /// What the client shows (premultiplied BGRA, rows `width * 4` apart); empty until
    /// the first picture.
    shadow: Vec<u8>,
}

impl AlphaTiler {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height, shadow: Vec::new() }
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// The tiles that bring the client up to date: the changed blocks of `damage`, or
    /// the whole picture when `damage` is `None` or nothing has been sent yet. The
    /// pixels are RGBA with straight alpha, as a PNG carries them.
    pub fn tiles(&mut self, src: &Pixels<'_>, damage: Option<&[Rect]>) -> Result<Tiles, EncodeError> {
        let row = self.width as usize * 4;
        let h = self.height as usize;
        if src.stride < row || src.data.len() < (h - 1) * src.stride + row {
            return Err(EncodeError("the input is smaller than the picture".into()));
        }
        let full = Rect::new(0, 0, self.width as i32, self.height as i32);
        let changed = match damage.filter(|_| self.shadow.len() == row * h) {
            Some(d) => convert::changed_blocks(src.data, src.stride, &mut self.shadow, row, self.width, self.height, d),
            None => {
                self.shadow.clear();
                for y in 0..h {
                    self.shadow.extend_from_slice(&src.data[y * src.stride..][..row]);
                }
                vec![full]
            }
        };
        // Many scattered runs (a menu's highlight moving, a repaint) go as one tile of
        // their bounding box rather than as a flurry of small ones.
        let runs = if changed.len() > MAX_TILES {
            vec![changed.iter().copied().reduce(union).unwrap_or(full)]
        } else {
            merge_columns(&changed)
        };
        let tiles = runs
            .iter()
            .map(|r| {
                let mut rgba = Vec::with_capacity(r.w as usize * r.h as usize * 4);
                for y in r.y as usize..(r.y + r.h) as usize {
                    for px in src.data[y * src.stride + r.x as usize * 4..][..r.w as usize * 4].chunks_exact(4) {
                        rgba.extend_from_slice(&straight(px));
                    }
                }
                (*r, rgba)
            })
            .collect();
        Ok(Tiles { tiles, refine_in_ms: None })
    }
}

/// The smallest rectangle holding both.
fn union(a: Rect, b: Rect) -> Rect {
    let (x0, y0) = (a.x.min(b.x), a.y.min(b.y));
    let (x1, y1) = ((a.x + a.w).max(b.x + b.w), (a.y + a.h).max(b.y + b.h));
    Rect::new(x0, y0, x1 - x0, y1 - y0)
}

/// One premultiplied BGRA pixel as straight RGBA. Opaque pixels, which is what text
/// is, pass through unchanged.
fn straight(px: &[u8]) -> [u8; 4] {
    let a = px[3];
    match a {
        0 => [0, 0, 0, 0],
        255 => [px[2], px[1], px[0], 255],
        _ => {
            let un = |c: u8| ((c as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8;
            [un(px[2]), un(px[1]), un(px[0]), a]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encode::CpuImage;

    fn pixels(image: &CpuImage) -> Pixels<'_> {
        Pixels { data: &image.data, stride: image.stride }
    }

    #[test]
    fn the_first_picture_is_one_whole_tile_and_then_only_changed_blocks() {
        let mut tiler = AlphaTiler::new(64, 32);
        let mut image = CpuImage::new(64, 32);
        let t = tiler.tiles(&pixels(&image), Some(&[Rect::new(0, 0, 8, 8)])).unwrap();
        assert_eq!(t.tiles.len(), 1);
        assert_eq!(t.tiles[0].0, Rect::new(0, 0, 64, 32));
        assert_eq!(t.tiles[0].1.len(), 64 * 32 * 4);
        assert!(t.refine_in_ms.is_none());
        // Damage with no real change sends nothing.
        assert!(tiler.tiles(&pixels(&image), Some(&[Rect::new(0, 0, 64, 32)])).unwrap().tiles.is_empty());
        // An opaque white pixel at (20, 4): its block, straight RGBA.
        image.data[4 * image.stride + 20 * 4..][..4].copy_from_slice(&[255, 255, 255, 255]);
        let t = tiler.tiles(&pixels(&image), Some(&[Rect::new(20, 4, 1, 1)])).unwrap();
        assert_eq!(t.tiles.len(), 1);
        let (r, rgba) = &t.tiles[0];
        assert_eq!((r.x, r.y, r.w, r.h), (16, 0, 16, 16));
        assert_eq!(&rgba[(4 * 16 + 4) * 4..][..4], &[255, 255, 255, 255]);
        // A keyframe is the whole picture again.
        assert_eq!(tiler.tiles(&pixels(&image), None).unwrap().tiles[0].0, Rect::new(0, 0, 64, 32));
    }

    #[test]
    fn premultiplied_pixels_are_sent_straight() {
        assert_eq!(straight(&[0, 0, 0, 0]), [0, 0, 0, 0]);
        assert_eq!(straight(&[10, 20, 30, 255]), [30, 20, 10, 255]);
        // Half-covered white: 128 premultiplied is 255 straight.
        assert_eq!(straight(&[128, 128, 128, 128]), [255, 255, 255, 128]);
    }

    #[test]
    fn many_runs_become_their_bounding_box() {
        let mut tiler = AlphaTiler::new(256, 256);
        let mut image = CpuImage::new(256, 256);
        tiler.tiles(&pixels(&image), None).unwrap();
        // One pixel in every other block of every other row: far more than MAX_TILES runs.
        let mut damage = Vec::new();
        for by in (0..16).step_by(2) {
            for bx in (0..16).step_by(2) {
                image.data[(by * 16 + 3) * image.stride + (bx * 16 + 3) * 4 + 3] = 255;
                damage.push(Rect::new(bx as i32 * 16, by as i32 * 16, 16, 16));
            }
        }
        let t = tiler.tiles(&pixels(&image), Some(&damage)).unwrap();
        assert_eq!(t.tiles.len(), 1);
        assert_eq!(t.tiles[0].0, Rect::new(0, 0, 240, 240));
    }
}
