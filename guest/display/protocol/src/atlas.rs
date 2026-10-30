//! Atlas Micro-Codec, XXH64 tile hashing, LZ4 raw block codec with 4-byte size prefix,
//! and 1D/2D `CopyRect` scroll detector for Caboose Display's Surface Atlas lane.

use crate::{AtlasTileFormat, Rect, SurfaceCopy};

const PRIME64_1: u64 = 0x9E3779B185EBCA87;
const PRIME64_2: u64 = 0xC2B2AE3D27D4EB4F;
const PRIME64_3: u64 = 0x165667B19E3779F9;
const PRIME64_4: u64 = 0x85EBCA77C2B2AE63;
const PRIME64_5: u64 = 0x27D4EB2F165667C5;

#[inline]
fn xxh64_round(acc: u64, input: u64) -> u64 {
    acc.wrapping_add(input.wrapping_mul(PRIME64_2)).rotate_left(31).wrapping_mul(PRIME64_1)
}

#[inline]
fn xxh64_merge_round(mut acc: u64, val: u64) -> u64 {
    let val = xxh64_round(0, val);
    acc ^= val;
    acc.wrapping_mul(PRIME64_1).wrapping_add(PRIME64_4)
}

#[inline]
fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap())
}

#[inline]
fn read_u32_le(data: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap())
}

/// Standard 64-bit XXHash (`XXH64`).
pub fn xxh64(data: &[u8], seed: u64) -> u64 {
    let len = data.len();
    let mut p = 0usize;
    let mut h64: u64;

    if len >= 32 {
        let mut v1 = seed.wrapping_add(PRIME64_1).wrapping_add(PRIME64_2);
        let mut v2 = seed.wrapping_add(PRIME64_2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(PRIME64_1);

        let limit = len - 32;
        while p <= limit {
            v1 = xxh64_round(v1, read_u64_le(data, p));
            v2 = xxh64_round(v2, read_u64_le(data, p + 8));
            v3 = xxh64_round(v3, read_u64_le(data, p + 16));
            v4 = xxh64_round(v4, read_u64_le(data, p + 24));
            p += 32;
        }

        h64 = v1
            .rotate_left(1)
            .wrapping_add(v2.rotate_left(7))
            .wrapping_add(v3.rotate_left(12))
            .wrapping_add(v4.rotate_left(18));
        h64 = xxh64_merge_round(h64, v1);
        h64 = xxh64_merge_round(h64, v2);
        h64 = xxh64_merge_round(h64, v3);
        h64 = xxh64_merge_round(h64, v4);
    } else {
        h64 = seed.wrapping_add(PRIME64_5);
    }

    h64 = h64.wrapping_add(len as u64);

    while p + 8 <= len {
        let k1 = xxh64_round(0, read_u64_le(data, p));
        h64 ^= k1;
        h64 = h64.rotate_left(27).wrapping_mul(PRIME64_1).wrapping_add(PRIME64_4);
        p += 8;
    }

    if p + 4 <= len {
        h64 ^= (read_u32_le(data, p) as u64).wrapping_mul(PRIME64_1);
        h64 = h64.rotate_left(23).wrapping_mul(PRIME64_2).wrapping_add(PRIME64_3);
        p += 4;
    }

    while p < len {
        h64 ^= (data[p] as u64).wrapping_mul(PRIME64_5);
        h64 = h64.rotate_left(11).wrapping_mul(PRIME64_1);
        p += 1;
    }

    h64 ^= h64 >> 33;
    h64 = h64.wrapping_mul(PRIME64_2);
    h64 ^= h64 >> 29;
    h64 = h64.wrapping_mul(PRIME64_3);
    h64 ^= h64 >> 32;
    h64
}

#[inline]
fn lz4_hash4(val: u32) -> usize {
    ((val.wrapping_mul(2654435761)) >> 20) as usize & 0xFFF
}

fn write_lz4_len(out: &mut Vec<u8>, mut rem: usize) {
    while rem >= 255 {
        out.push(255);
        rem -= 255;
    }
    out.push(rem as u8);
}

/// Compresses `input` as a standard LZ4 raw block prefixed by its 4-byte little-endian
/// uncompressed length.
pub fn lz4_compress_prepend_size(input: &[u8]) -> Vec<u8> {
    let len = input.len();
    let mut out = Vec::with_capacity(4 + len + (len / 255) + 16);
    out.extend_from_slice(&(len as u32).to_le_bytes());
    if len == 0 {
        return out;
    }

    if len < 12 {
        let token = (len as u8) << 4;
        out.push(token);
        out.extend_from_slice(input);
        return out;
    }

    let mut dict = [0u32; 4096];
    let mut anchor = 0usize;
    let mut ip = 0usize;
    let match_limit = len - 5;
    let mflimit = len - 12;

    while ip <= mflimit {
        let seq = read_u32_le(input, ip);
        let h = lz4_hash4(seq);
        let ref_pos = dict[h] as usize;
        dict[h] = ip as u32;

        let offset = ip.wrapping_sub(ref_pos);
        if offset > 0 && offset <= 65535 && read_u32_le(input, ref_pos) == seq {
            // Backtrack if possible? No need, anchor..ip are literals.
            let lit_len = ip - anchor;
            let mut match_len = 4usize;
            while ip + match_len < match_limit && input[ref_pos + match_len] == input[ip + match_len] {
                match_len += 1;
            }

            let lit_code = lit_len.min(15) as u8;
            let match_code = (match_len - 4).min(15) as u8;
            out.push((lit_code << 4) | match_code);
            if lit_len >= 15 {
                write_lz4_len(&mut out, lit_len - 15);
            }
            out.extend_from_slice(&input[anchor..ip]);
            out.extend_from_slice(&(offset as u16).to_le_bytes());
            if match_len - 4 >= 15 {
                write_lz4_len(&mut out, match_len - 4 - 15);
            }

            ip += match_len;
            anchor = ip;
            if ip <= mflimit {
                dict[lz4_hash4(read_u32_le(input, ip - 2))] = (ip - 2) as u32;
            }
        } else {
            ip += 1;
        }
    }

    // Emit trailing literals
    let last_lits = len - anchor;
    let lit_code = last_lits.min(15) as u8;
    out.push(lit_code << 4);
    if last_lits >= 15 {
        write_lz4_len(&mut out, last_lits - 15);
    }
    out.extend_from_slice(&input[anchor..]);
    out
}

/// Decompresses an LZ4 raw block prefixed by a 4-byte little-endian uncompressed size.
pub fn lz4_decompress_prepend_size(data: &[u8], max_out: usize) -> Result<Vec<u8>, &'static str> {
    if data.len() < 4 {
        return Err("lz4: truncated size prefix");
    }
    let expected_len = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
    if expected_len > max_out {
        return Err("lz4: uncompressed size exceeds max_out");
    }
    if expected_len == 0 {
        return if data.len() == 4 {
            Ok(Vec::new())
        } else {
            Err("lz4: trailing bytes on empty block")
        };
    }

    let mut out = Vec::with_capacity(expected_len);
    let mut ip = 4usize;

    while ip < data.len() {
        let token = data[ip];
        ip += 1;

        let mut lit_len = (token >> 4) as usize;
        if lit_len == 15 {
            loop {
                if ip >= data.len() {
                    return Err("lz4: truncated literal length");
                }
                let s = data[ip] as usize;
                ip += 1;
                lit_len = lit_len.checked_add(s).ok_or("lz4: literal length overflow")?;
                if s != 255 {
                    break;
                }
            }
        }

        if ip.checked_add(lit_len).ok_or("lz4: literal bounds overflow")? > data.len() {
            return Err("lz4: literal exceeds input");
        }
        if out.len().checked_add(lit_len).ok_or("lz4: output overflow")? > expected_len {
            return Err("lz4: output exceeds expected size");
        }
        out.extend_from_slice(&data[ip..ip + lit_len]);
        ip += lit_len;

        if ip == data.len() {
            break;
        }

        if ip + 2 > data.len() {
            return Err("lz4: truncated match offset");
        }
        let offset = u16::from_le_bytes([data[ip], data[ip + 1]]) as usize;
        ip += 2;
        if offset == 0 || offset > out.len() {
            return Err("lz4: invalid match offset");
        }

        let mut match_len = ((token & 0x0F) as usize) + 4;
        if (token & 0x0F) == 15 {
            loop {
                if ip >= data.len() {
                    return Err("lz4: truncated match length");
                }
                let s = data[ip] as usize;
                ip += 1;
                match_len = match_len.checked_add(s).ok_or("lz4: match length overflow")?;
                if s != 255 {
                    break;
                }
            }
        }

        if out.len().checked_add(match_len).ok_or("lz4: output overflow")? > expected_len {
            return Err("lz4: match exceeds expected size");
        }

        let match_start = out.len() - offset;
        for i in 0..match_len {
            let b = out[match_start + i];
            out.push(b);
        }
    }

    if out.len() != expected_len {
        return Err("lz4: decompressed length mismatch");
    }
    Ok(out)
}

/// Encodes an RGBA8888 tile (`w * h * 4` bytes) using the adaptive lossless UI tile micro-codec:
/// - `1..=2` unique colors -> `Pal2Lz4` (1-bit packed indices)
/// - `3..=16` unique colors -> `Pal16Lz4` (4-bit packed indices)
/// - `> 16` unique colors -> `RgbaLz4` (raw RGBA8888 + LZ4)
pub fn encode_atlas_tile(rgba: &[u8], w: u32, h: u32) -> (AtlasTileFormat, Vec<u8>) {
    let pixels = (w as usize) * (h as usize);
    assert_eq!(rgba.len(), pixels * 4, "rgba length must equal w * h * 4");

    let mut palette = [[0u8; 4]; 16];
    let mut count = 0usize;

    'scan: for px in rgba.chunks_exact(4) {
        let c = [px[0], px[1], px[2], px[3]];
        for p in &palette[..count] {
            if *p == c {
                continue 'scan;
            }
        }
        if count == 16 {
            count = 17;
            break;
        }
        palette[count] = c;
        count += 1;
    }

    if (1..=2).contains(&count) {
        let c0 = palette[0];
        let c1 = if count == 2 { palette[1] } else { palette[0] };
        let packed_len = (pixels + 7) / 8;
        let mut raw = vec![0u8; 8 + packed_len];
        raw[0..4].copy_from_slice(&c0);
        raw[4..8].copy_from_slice(&c1);
        if count == 2 {
            for (i, px) in rgba.chunks_exact(4).enumerate() {
                if px == c1 {
                    raw[8 + (i >> 3)] |= 1 << (7 - (i & 7));
                }
            }
        }
        (AtlasTileFormat::Pal2Lz4, lz4_compress_prepend_size(&raw))
    } else if (3..=16).contains(&count) {
        let packed_len = (pixels + 1) / 2;
        let mut raw = Vec::with_capacity(1 + count * 4 + packed_len);
        raw.push(count as u8);
        for c in &palette[..count] {
            raw.extend_from_slice(c);
        }
        raw.resize(1 + count * 4 + packed_len, 0);
        let packed = &mut raw[1 + count * 4..];
        for (i, px) in rgba.chunks_exact(4).enumerate() {
            let mut idx = 0u8;
            for (j, p) in palette[..count].iter().enumerate() {
                if p == px {
                    idx = j as u8;
                    break;
                }
            }
            if (i & 1) == 0 {
                packed[i >> 1] |= idx << 4;
            } else {
                packed[i >> 1] |= idx & 0x0F;
            }
        }
        (AtlasTileFormat::Pal16Lz4, lz4_compress_prepend_size(&raw))
    } else {
        (AtlasTileFormat::RgbaLz4, lz4_compress_prepend_size(rgba))
    }
}

/// Decodes a `Pal2Lz4`, `Pal16Lz4`, or `RgbaLz4` tile back into exact `w * h * 4` RGBA8888 bytes.
pub fn decode_atlas_tile(fmt: AtlasTileFormat, data: &[u8], w: u32, h: u32) -> Result<Vec<u8>, &'static str> {
    let pixels = (w as usize).checked_mul(h as usize).ok_or("atlas: dimension overflow")?;
    let rgba_len = pixels.checked_mul(4).ok_or("atlas: byte size overflow")?;

    match fmt {
        AtlasTileFormat::Pal2Lz4 => {
            let packed_len = (pixels + 7) / 8;
            let expected_raw = 8 + packed_len;
            let raw = lz4_decompress_prepend_size(data, expected_raw)?;
            if raw.len() != expected_raw {
                return Err("atlas: pal2 raw size mismatch");
            }
            let c0: [u8; 4] = raw[0..4].try_into().unwrap();
            let c1: [u8; 4] = raw[4..8].try_into().unwrap();
            let packed = &raw[8..];
            let mut out = Vec::with_capacity(rgba_len);
            for i in 0..pixels {
                let bit = (packed[i >> 3] >> (7 - (i & 7))) & 1;
                out.extend_from_slice(if bit != 0 { &c1 } else { &c0 });
            }
            Ok(out)
        }
        AtlasTileFormat::Pal16Lz4 => {
            let max_raw = 1 + 16 * 4 + (pixels + 1) / 2;
            let raw = lz4_decompress_prepend_size(data, max_raw)?;
            if raw.is_empty() {
                return Err("atlas: pal16 empty payload");
            }
            let count = raw[0] as usize;
            if !(1..=16).contains(&count) {
                return Err("atlas: pal16 invalid color count");
            }
            let packed_len = (pixels + 1) / 2;
            let expected_raw = 1 + count * 4 + packed_len;
            if raw.len() != expected_raw {
                return Err("atlas: pal16 raw size mismatch");
            }
            let mut palette = [[0u8; 4]; 16];
            for c in 0..count {
                let off = 1 + c * 4;
                palette[c].copy_from_slice(&raw[off..off + 4]);
            }
            let packed = &raw[1 + count * 4..];
            let mut out = Vec::with_capacity(rgba_len);
            for i in 0..pixels {
                let byte = packed[i >> 1];
                let idx = if (i & 1) == 0 { (byte >> 4) as usize } else { (byte & 0x0F) as usize };
                if idx >= count {
                    return Err("atlas: pal16 color index out of bounds");
                }
                out.extend_from_slice(&palette[idx]);
            }
            Ok(out)
        }
        AtlasTileFormat::RgbaLz4 => {
            let raw = lz4_decompress_prepend_size(data, rgba_len)?;
            if raw.len() != rgba_len {
                return Err("atlas: rgba raw size mismatch");
            }
            Ok(raw)
        }
        AtlasTileFormat::Png => Err("atlas: PNG decoding requires external image decoder"),
    }
}

/// Detects a vertical scroll copy (`SurfaceCopy`) inside `damage` between `prev_rgba` and `curr_rgba`.
///
/// Both buffers are RGBA8888 with row stride `stride_px` pixels.
/// Requires `damage.w >= 64 && damage.h >= 64`.
///
/// To remain accurate on real browser/editor windows with scrollbars, window borders, and large
/// expanses of uniform background whitespace:
/// 1. When `damage.w >= 128`, row hashes exclude a narrow left/right gutter (`<= 32` px) so a
///    stationary or counter-moving scrollbar thumb does not corrupt scanline hashes. Any 64×64
///    tiles on the scrollbar edge that differ after the copy are patched bit-exactly by the
///    subsequent tile pass in `AtlasWindowEncoder`.
/// 2. Candidate shifts `dy` are scored primarily on **vertically informative scanlines**
///    (`curr_hashes[r] != curr_hashes[r - 1]`), preventing consecutive identical background
///    rows on sparse pages (such as `example.com`) from falsely favoring `|dy| = 1`.
pub fn detect_scroll_copy(
    prev_rgba: &[u8],
    curr_rgba: &[u8],
    stride_px: u32,
    damage: Rect,
) -> Option<SurfaceCopy> {
    if damage.w < 64 || damage.h < 64 || damage.x < 0 || damage.y < 0 {
        return None;
    }
    let stride_bytes = (stride_px as usize) * 4;
    let x_bytes = (damage.x as usize) * 4;
    let w_bytes = (damage.w as usize) * 4;
    let end_y = (damage.y + damage.h) as usize;

    if x_bytes + w_bytes > stride_bytes {
        return None;
    }
    let req_bytes = end_y.checked_mul(stride_bytes)?;
    if prev_rgba.len() < req_bytes || curr_rgba.len() < req_bytes {
        return None;
    }

    let margin_px = if damage.w >= 128 { ((damage.w as usize) / 8).min(32) } else { 0 };
    let hash_x_bytes = x_bytes + margin_px * 4;
    let hash_w_bytes = w_bytes - margin_px * 8;

    let h = damage.h as usize;
    let mut prev_hashes = Vec::with_capacity(h);
    let mut curr_hashes = Vec::with_capacity(h);

    for r in 0..h {
        let y = (damage.y as usize) + r;
        let row_start = y * stride_bytes + hash_x_bytes;
        let row_end = row_start + hash_w_bytes;
        prev_hashes.push(xxh64(&prev_rgba[row_start..row_end], 0));
        curr_hashes.push(xxh64(&curr_rgba[row_start..row_end], 0));
    }

    let mut curr_informative = vec![false; h];
    let mut total_informative = 0usize;
    for r in 1..h {
        if curr_hashes[r] != curr_hashes[r - 1] {
            curr_informative[r] = true;
            total_informative += 1;
        }
    }

    let max_dy = (damage.h / 2 - 1).min(768);
    if max_dy < 1 {
        return None;
    }

    let mut best_dy = 0i32;
    let mut best_info_matches = 0usize;
    let mut best_matches = 0usize;

    for abs_dy in 1..=max_dy {
        for sign in [-1i32, 1i32] {
            let dy = abs_dy * sign;
            let (curr_start, prev_start, overlap) = if dy < 0 {
                let shift = (-dy) as usize;
                (0usize, shift, h - shift)
            } else {
                let shift = dy as usize;
                (shift, 0usize, h - shift)
            };

            let mut matches = 0usize;
            let mut info_in_overlap = 0usize;
            let mut info_matches = 0usize;
            for i in 0..overlap {
                let c_idx = curr_start + i;
                let p_idx = prev_start + i;
                let is_info = curr_informative[c_idx];
                if is_info {
                    info_in_overlap += 1;
                }
                if curr_hashes[c_idx] == prev_hashes[p_idx] {
                    matches += 1;
                    if is_info {
                        info_matches += 1;
                    }
                }
            }

            // Require at least 60% of overlapping rows to match overall, and when the region
            // contains vertically distinct content rows, require at least half of those
            // informative rows in the overlap to match.
            let info_ok = if total_informative >= 4 {
                info_in_overlap >= 4 && info_matches * 2 >= info_in_overlap
            } else {
                true
            };
            let better = if total_informative >= 4 {
                info_matches > best_info_matches
                    || (info_matches == best_info_matches && matches > best_matches)
            } else {
                matches > best_matches
            };

            if matches * 5 >= overlap * 3 && info_ok && better {
                // Verify sampled bytes on matching rows (preferring informative rows)
                let mut verified = true;
                let step = (overlap / 8).max(1);
                for i in (0..overlap).step_by(step) {
                    if curr_hashes[curr_start + i] == prev_hashes[prev_start + i] {
                        let cy = (damage.y as usize) + curr_start + i;
                        let py = (damage.y as usize) + prev_start + i;
                        let c_off = cy * stride_bytes + hash_x_bytes;
                        let p_off = py * stride_bytes + hash_x_bytes;
                        if curr_rgba[c_off..c_off + hash_w_bytes] != prev_rgba[p_off..p_off + hash_w_bytes] {
                            verified = false;
                            break;
                        }
                    }
                }
                if verified {
                    best_info_matches = info_matches;
                    best_matches = matches;
                    best_dy = dy;
                }
            }
        }
    }

    if best_dy == 0 {
        return None;
    }

    let dst_rect = if best_dy < 0 {
        Rect::new(damage.x, damage.y, damage.w, damage.h + best_dy)
    } else {
        Rect::new(damage.x, damage.y + best_dy, damage.w, damage.h - best_dy)
    };

    Some(SurfaceCopy { dx: 0, dy: best_dy, rect: dst_rect })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xxh64_matches_standard_test_vectors() {
        assert_eq!(xxh64(b"", 0), 0xEF46DB3751D8E999);
        let h1 = xxh64(b"Caboose", 0);
        let h2 = xxh64(b"Caboose", 0);
        assert_eq!(h1, h2);
        assert_ne!(h1, 0xEF46DB3751D8E999);
        // Test > 32 bytes path
        let long = b"Caboose OS Decomposition Zero Server Video Architecture 1234567890";
        assert_eq!(xxh64(long, 0), xxh64(long, 0));
    }

    #[test]
    fn lz4_round_trips_empty_short_and_repetitive_buffers() {
        let empty = lz4_compress_prepend_size(b"");
        assert_eq!(empty, [0, 0, 0, 0]);
        assert_eq!(lz4_decompress_prepend_size(&empty, 16).unwrap(), b"");

        let short = b"hello world";
        let c_short = lz4_compress_prepend_size(short);
        assert_eq!(lz4_decompress_prepend_size(&c_short, 64).unwrap(), short);

        let mut rep = Vec::new();
        for i in 0..512 {
            rep.extend_from_slice(b"caboose-atlas-tile-");
            rep.push((i & 3) as u8);
        }
        let c_rep = lz4_compress_prepend_size(&rep);
        assert!(c_rep.len() < rep.len() / 2);
        assert_eq!(lz4_decompress_prepend_size(&c_rep, rep.len()).unwrap(), rep);
    }

    #[test]
    fn atlas_tile_codec_pal2_pal16_and_rgba_round_trip() {
        let w = 64u32;
        let h = 64u32;
        let pixels = (w * h) as usize;

        // 2-color text/background tile
        let mut pal2_rgba = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            if (i % 7) == 0 {
                pal2_rgba.extend_from_slice(&[0xCD, 0xD6, 0xF4, 0xFF]);
            } else {
                pal2_rgba.extend_from_slice(&[0x1E, 0x1E, 0x2E, 0xFF]);
            }
        }
        let (fmt2, enc2) = encode_atlas_tile(&pal2_rgba, w, h);
        assert_eq!(fmt2, AtlasTileFormat::Pal2Lz4);
        let dec2 = decode_atlas_tile(fmt2, &enc2, w, h).unwrap();
        assert_eq!(dec2, pal2_rgba);

        // 8-color anti-aliased glyph tile
        let mut pal16_rgba = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            let c = (i % 8) as u8;
            pal16_rgba.extend_from_slice(&[c * 20, c * 30, 0x40, 0xFF]);
        }
        let (fmt16, enc16) = encode_atlas_tile(&pal16_rgba, w, h);
        assert_eq!(fmt16, AtlasTileFormat::Pal16Lz4);
        let dec16 = decode_atlas_tile(fmt16, &enc16, w, h).unwrap();
        assert_eq!(dec16, pal16_rgba);

        // >16-color gradient tile
        let mut rgba_tile = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            rgba_tile.extend_from_slice(&[(i & 0xFF) as u8, ((i >> 4) & 0xFF) as u8, 0x80, 0xFF]);
        }
        let (fmt_rgba, enc_rgba) = encode_atlas_tile(&rgba_tile, w, h);
        assert_eq!(fmt_rgba, AtlasTileFormat::RgbaLz4);
        let dec_rgba = decode_atlas_tile(fmt_rgba, &enc_rgba, w, h).unwrap();
        assert_eq!(dec_rgba, rgba_tile);
    }

    #[test]
    fn scroll_copy_detector_finds_vertical_displacement() {
        let w = 128u32;
        let h = 128u32;
        let mut prev = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let off = ((y * w + x) * 4) as usize;
                prev[off] = (y & 0xFF) as u8;
                prev[off + 1] = ((y * 3 + x) & 0xFF) as u8;
                prev[off + 2] = (x & 0xFF) as u8;
                prev[off + 3] = 0xFF;
            }
        }
        // Scroll up by 16 pixels (dy = -16): curr[y] = prev[y + 16]
        let mut curr = vec![0u8; (w * h * 4) as usize];
        for y in 0..(h - 16) {
            let dst_off = (y * w * 4) as usize;
            let src_off = ((y + 16) * w * 4) as usize;
            let row_bytes = (w * 4) as usize;
            curr[dst_off..dst_off + row_bytes].copy_from_slice(&prev[src_off..src_off + row_bytes]);
        }

        let copy = detect_scroll_copy(&prev, &curr, w, Rect::new(0, 0, w as i32, h as i32)).unwrap();
        assert_eq!(copy.dx, 0);
        assert_eq!(copy.dy, -16);
        assert_eq!(copy.rect, Rect::new(0, 0, 128, 112));
    }

    #[test]
    fn scroll_copy_detector_locks_onto_text_on_mostly_blank_page_with_scrollbar() {
        // Model a mostly-white/gray page like example.com (256x256) with a 24px text band
        // and a counter-moving scrollbar thumb in the rightmost 16px column.
        let w = 256u32;
        let h = 256u32;
        let render_page = |text_top: u32, thumb_top: u32| -> Vec<u8> {
            let mut buf = vec![0xEEu8; (w * h * 4) as usize];
            for px in buf.chunks_exact_mut(4) {
                px[3] = 0xFF;
            }
            for y in text_top..(text_top + 24) {
                for x in 40..200 {
                    let off = ((y * w + x) * 4) as usize;
                    buf[off] = ((y - text_top) * 9 + (x & 7)) as u8;
                    buf[off + 1] = ((x * 5) & 0xFF) as u8;
                    buf[off + 2] = 0x22;
                    buf[off + 3] = 0xFF;
                }
            }
            // Right-hand scrollbar track + thumb in rightmost 16px (x = 240..256)
            for y in 0..h {
                for x in 240..256 {
                    let off = ((y * w + x) * 4) as usize;
                    let is_thumb = y >= thumb_top && y < thumb_top + 40;
                    let c = if is_thumb { 0x60 } else { 0xD0 };
                    buf[off] = c;
                    buf[off + 1] = c;
                    buf[off + 2] = c;
                    buf[off + 3] = 0xFF;
                }
            }
            buf
        };

        // Scroll content up by 36px (text moves from y=100 to y=64; thumb moves down from y=20 to y=40)
        let prev = render_page(100, 20);
        let curr = render_page(64, 40);
        let copy = detect_scroll_copy(&prev, &curr, w, Rect::new(0, 0, w as i32, h as i32)).unwrap();
        assert_eq!(copy.dx, 0);
        assert_eq!(copy.dy, -36);
        assert_eq!(copy.rect, Rect::new(0, 0, 256, 220));
    }
}
