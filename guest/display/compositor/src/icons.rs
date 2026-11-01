//! A window's own icon, for `window.create`'s `icon`: the one image of those an
//! application offers (X11 `_NET_WM_ICON`, xdg-toplevel-icon buffers) that a client shows
//! in its taskbar, as PNG.

use smithay::reexports::wayland_server::protocol::{wl_buffer::WlBuffer, wl_shm};
use smithay::wayland::shm::with_buffer_contents;

/// The size a taskbar draws an icon at on a phone (52 points at 3x is 156 pixels).
const WANTED: u32 = 128;
/// No larger image is sent: a bigger one costs bytes and gains nothing.
const LARGEST: u32 = 256;

/// One image an application offers, as straight-alpha ARGB (`0xAARRGGBB`) pixels, rows
/// top to bottom.
pub struct Image<'a> {
    pub width: u32,
    pub height: u32,
    pub argb: &'a [u32],
}

/// The images in an `_NET_WM_ICON` value: `width, height, width × height pixels`,
/// repeated. A truncated or empty image ends the list.
pub fn net_wm_icon(value: &[u32]) -> Vec<Image<'_>> {
    let mut images = Vec::new();
    let mut rest = value;
    while let [width, height, tail @ ..] = rest {
        let (width, height) = (*width, *height);
        let Some(len) = (width as usize).checked_mul(height as usize).filter(|&n| n > 0 && n <= tail.len()) else { break };
        images.push(Image { width, height, argb: &tail[..len] });
        rest = &tail[len..];
    }
    images
}

/// The image to show: the smallest at least `WANTED` pixels square, else the largest, of
/// those no larger than `LARGEST`.
pub fn best<'a, 'b>(images: &'b [Image<'a>]) -> Option<&'b Image<'a>> {
    let side = |i: &Image| i.width.max(i.height);
    let usable = images.iter().filter(|i| side(i) <= LARGEST);
    usable.clone().filter(|i| side(i) >= WANTED).min_by_key(|i| side(i)).or_else(|| usable.max_by_key(|i| side(i)))
}

/// The image as an RGBA PNG.
pub fn png(image: &Image) -> Option<Vec<u8>> {
    let mut rgba = Vec::with_capacity(image.argb.len() * 4);
    for &p in image.argb {
        rgba.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, p as u8, (p >> 24) as u8]);
    }
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, image.width, image.height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().ok()?;
    writer.write_image_data(&rgba).ok()?;
    writer.finish().ok()?;
    Some(out)
}

/// The icon an `_NET_WM_ICON` value gives, as PNG.
pub fn from_net_wm_icon(value: &[u32]) -> Option<Vec<u8>> {
    png(best(&net_wm_icon(value))?)
}

/// wl_shm's ARGB8888 is premultiplied; `_NET_WM_ICON` and PNG are straight.
pub fn unpremultiply(p: u32) -> u32 {
    let a = p >> 24;
    if a == 0 || a == 255 {
        return if a == 0 { 0 } else { p };
    }
    let channel = |shift: u32| (((p >> shift) & 0xff) * 255 + a / 2) / a;
    (a << 24) | (channel(16).min(255) << 16) | (channel(8).min(255) << 8) | channel(0).min(255)
}

/// A copy of an xdg-toplevel-icon buffer's pixels: width, height and straight-alpha ARGB,
/// or why the buffer cannot be an icon.
pub fn read_shm_icon(buffer: &WlBuffer) -> Result<(u32, u32, Vec<u32>), &'static str> {
    with_buffer_contents(buffer, |ptr, len, data| {
        let (w, h, stride, offset) = (data.width, data.height, data.stride, data.offset);
        if !matches!(data.format, wl_shm::Format::Argb8888 | wl_shm::Format::Xrgb8888) {
            return Err("the icon buffer must be ARGB8888 or XRGB8888");
        }
        if w <= 0 || w != h {
            return Err("the icon buffer must be square");
        }
        if stride < w * 4 || offset < 0 || offset as usize + stride as usize * (h as usize - 1) + w as usize * 4 > len {
            return Err("the icon buffer lies outside its pool");
        }
        // SAFETY: the pool maps `len` bytes at `ptr` for the duration of this call.
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        let opaque = data.format == wl_shm::Format::Xrgb8888;
        let mut argb = Vec::with_capacity((w * h) as usize);
        for row in 0..h as usize {
            let start = offset as usize + row * stride as usize;
            for px in bytes[start..start + w as usize * 4].chunks_exact(4) {
                let p = u32::from_le_bytes([px[0], px[1], px[2], px[3]]);
                argb.push(if opaque { p | 0xff00_0000 } else { unpremultiply(p) });
            }
        }
        Ok((w as u32, h as u32, argb))
    })
    .map_err(|_| "the icon buffer must be backed by wl_shm")?
}

/// The best of an icon's images (`best`), as PNG.
pub fn png_of_images(images: &[(u32, u32, Vec<u32>)]) -> Option<Vec<u8>> {
    let images: Vec<Image> = images.iter().map(|(width, height, argb)| Image { width: *width, height: *height, argb }).collect();
    png(best(&images)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn icon(sizes: &[u32]) -> Vec<u32> {
        sizes.iter().flat_map(|&s| [s, s].into_iter().chain(std::iter::repeat_n(0xff00_00ff, (s * s) as usize))).collect()
    }

    #[test]
    fn the_smallest_image_at_least_the_wanted_size_is_chosen() {
        let value = icon(&[16, 32, 256, 128, 48]);
        let images = net_wm_icon(&value);
        assert_eq!(images.len(), 5);
        assert_eq!(best(&images).map(|i| i.width), Some(128));
    }

    #[test]
    fn a_small_icon_alone_is_used_and_a_huge_one_is_not() {
        let value = icon(&[32]);
        assert_eq!(best(&net_wm_icon(&value)).map(|i| i.width), Some(32));
        let value = icon(&[512, 48]);
        assert_eq!(best(&net_wm_icon(&value)).map(|i| i.width), Some(48));
        let value = icon(&[512]);
        assert!(best(&net_wm_icon(&value)).is_none());
    }

    #[test]
    fn a_truncated_value_keeps_only_whole_images() {
        let mut value = icon(&[16]);
        value.extend_from_slice(&[32, 32, 1, 2, 3]);
        assert_eq!(net_wm_icon(&value).len(), 1);
        assert!(net_wm_icon(&[]).is_empty());
        assert!(net_wm_icon(&[0, 0]).is_empty());
        assert!(net_wm_icon(&[u32::MAX, u32::MAX, 1]).is_empty());
    }

    #[test]
    fn premultiplied_pixels_are_unpremultiplied() {
        assert_eq!(unpremultiply(0x8040_2000), 0x8080_4000);
        assert_eq!(unpremultiply(0xff12_3456), 0xff12_3456);
        assert_eq!(unpremultiply(0x00ff_ffff), 0);
    }

    #[test]
    fn argb_becomes_straight_rgba() {
        let png = from_net_wm_icon(&[1, 2, 0x80ff_0000, 0xff00_ff00]).unwrap();
        let mut reader = png::Decoder::new(std::io::Cursor::new(png)).read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size()];
        let frame = reader.next_frame(&mut buf).unwrap();
        assert_eq!((frame.width, frame.height), (1, 2));
        assert_eq!(&buf[..8], &[0xff, 0, 0, 0x80, 0, 0xff, 0, 0xff]);
    }
}
