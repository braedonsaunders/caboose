//! Surface Atlas Engine (Layer 0) lossless tile codec, XXH64 tile hashing,
//! raw LZ4 block compression/decompression, and vertical scroll `CopyRect` detection.
//!
//! All algorithms in this module are pure Rust with zero external C/crate dependencies
//! so the protocol crate builds identically across Linux, macOS, and WASM targets.

use crate::{AtlasTileFormat, Rect, SurfaceCopy};

const PRIME64_1: u64 = 0x9E37_79B1_85EB_CA87;
const PRIME64_2: u64 = 0xC2B2_AE3D_27D4_EB4F;
const PRIME64_3: u64 = 0x1656_67B1_9E37_79F9;
const PRIME64_4: u64 = 0x85EB_CA77_C2B2_AE63;
const PRIME64_5: u64 = 0x27D4_EB2F_1656_67C5;

#[inline]
fn read_u64_le(buf: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(buf[offset..offset + 8].try_into().unwrap())
}

#[inline]
fn read_u32_le(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(buf[offset..offset + 4].try_into().unwrap())
}

#[inline]
fn xxh64_round(acc: u64, input: u64) -> u64 {
    acc.wrapping_add(input.wrapping_mul(PRIME64_2))
        .rotate_left(31)
        .wrapping_mul(PRIME64_1)
}

#[inline]
fn xxh64_merge_round(mut acc: u64, val: u64) -> u64 {
    let val = xxh64_round(0, val);
    acc ^= val;
    acc.wrapping_mul(PRIME64_1).wrapping_add(PRIME64_4)
}

#[inline]
fn xxh64_avalanche(mut h: u64) -> u64 {
    h ^= h >> 33;
    h = h.wrapping_mul(PRIME64_2);
    h ^= h >> 29;
    h = h.wrapping_mul(PRIME64_3);
    h ^= h >> 32;
    h
}

/// Computes the canonical 64-bit xxHash (`XXH64`) of `data` with `seed`.
pub fn xxh64(data: &[u8], seed: u64) -> u64 {
    let len = data.len();
    let mut p = 0usize;

    let mut h64 = if len >= 32 {
        let mut v1 = seed.wrapping_add(PRIME64_1).wrapping_add(PRIME64_2);
        let mut v2 = seed.wrapping_add(PRIME64_2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(PRIME64_1);

        let limit = len - 32;
        while p <= limit {
            v1 = xxh64_round(v1, read_u64_le(data, p));
            p += 8;
            v2 = xxh64_round(v2, read_u64_le(data, p));
            p += 8;
            v3 = xxh64_round(v3, read_u64_le(data, p));
            p += 8;
            v4 = xxh64_round(v4, read_u64_le(data, p));
            p += 8;
        }

        let mut h = v1
            .rotate_left(1)
            .wrapping_add(v2.rotate_left(7))
            .wrapping_add(v3.rotate_left(12))
            .wrapping_add(v4.rotate_left(18));
        h = xxh64_merge_round(h, v1);
        h = xxh64_merge_round(h, v2);
        h = xxh64_merge_round(h, v3);
        h = xxh64_merge_round(h, v4);
        h
    } else {
        seed.wrapping_add(PRIME64_5)
    };

    h64 = h64.wrapping_add(len as u64);

    while p + 8 <= len {
        let k1 = xxh64_round(0, read_u64_le(data, p));
        h64 ^= k1;
        h64 = h64
            .rotate_left(27)
            .wrapping_mul(PRIME64_1)
            .wrapping_add(PRIME64_4);
        p += 8;
    }

    if p + 4 <= len {
        h64 ^= (read_u32_le(data, p) as u64).wrapping_mul(PRIME64_1);
        h64 = h64
            .rotate_left(23)
            .wrapping_mul(PRIME64_2)
            .wrapping_add(PRIME64_3);
        p += 4;
    }

    while p < len {
        h64 ^= (data[p] as u64).wrapping_mul(PRIME64_5);
        h64 = h64.rotate_left(11).wrapping_mul(PRIME64_1);
        p += 1;
    }

    xxh64_avalanche(h64)
}

#[inline]
fn lz4_hash4(v: u32) -> usize {
    ((v.wrapping_mul(2654435761)) >> 20) as usize
}

#[inline]
fn write_lz4_len(out: &mut Vec<u8>, mut rem: usize) {
    while rem >= 255 {
        out.push(255);
        rem -= 255;
    }
    out.push(rem as u8);
}

/// Compresses `input` into an LZ4 raw block prefixed by its 4-byte little-endian uncompressed size.
pub fn lz4_compress_prepend_size(input: &[u8]) -> Vec<u8> {
    let len = input.len();
    let mut out = Vec::with_capacity(4 + len + (len / 255) + 16);
    out.extend_from_slice(&(len as u32).to_le_bytes());

    if len == 0 {
        return out;
    }

    if len < 13 {
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
        if offset > 0 && offset <= 0xFFFF && read_u32_le(input, ref_pos) == seq {
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

            let offset = offset as u16;
            out.extend_from_slice(&offset.to_le_bytes());

            if match_len - 4 >= 15 {
                write_lz4_len(&mut out, (match_len - 4) - 15);
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

    // Pre-index informative row hash matches by shift `dy` in O(H) when `total_informative >= 2`
    // so non-matching shifts are skipped in O(1) without scanning all `overlap` rows.
    let mut info_hits = Vec::new();
    let mut precomputed_info = false;
    if total_informative >= 2 && h <= u16::MAX as usize {
        let table_size = (2 * max_dy + 1) as usize;
        info_hits.resize(table_size, 0usize);
        let mut head = [u16::MAX; 1024];
        let mut next_prev = vec![u16::MAX; h];
        for (p_idx, &ph) in prev_hashes.iter().enumerate() {
            let bucket = (ph as usize) & 1023;
            next_prev[p_idx] = head[bucket];
            head[bucket] = p_idx as u16;
        }
        let max_steps = h.saturating_mul(16).max(1024);
        let mut steps = 0usize;
        precomputed_info = true;
        'info_scan: for c_idx in 1..h {
            if !curr_informative[c_idx] {
                continue;
            }
            let ch = curr_hashes[c_idx];
            let mut p = head[(ch as usize) & 1023];
            while p != u16::MAX {
                steps += 1;
                if steps > max_steps {
                    precomputed_info = false;
                    break 'info_scan;
                }
                let p_idx = p as usize;
                if prev_hashes[p_idx] == ch {
                    let dy = (c_idx as i32) - (p_idx as i32);
                    if dy != 0 && dy.abs() <= max_dy {
                        info_hits[(dy + max_dy) as usize] += 1;
                    }
                }
                p = next_prev[p_idx];
            }
        }
    }

    let mut best_dy = 0i32;
    let mut best_info_matches = 0usize;
    let mut best_matches = 0usize;

    for abs_dy in 1..=max_dy {
        for sign in [-1i32, 1i32] {
            let dy = abs_dy * sign;
            if precomputed_info {
                let fast_info = info_hits[(dy + max_dy) as usize];
                if fast_info == 0 || fast_info < best_info_matches {
                    continue;
                }
            }
            let (curr_start, prev_start, overlap) = if dy < 0 {
                let shift = (-dy) as usize;
                (0usize, shift, h - shift)
            } else {
                let shift = dy as usize;
                (shift, 0usize, h - shift)
            };

            let mut matches = 0usize;
            let mut info_matches = 0usize;
            for i in 0..overlap {
                let c_idx = curr_start + i;
                let p_idx = prev_start + i;
                if curr_hashes[c_idx] == prev_hashes[p_idx] {
                    matches += 1;
                    if curr_informative[c_idx] {
                        info_matches += 1;
                    }
                }
            }

            // Require at least 60% of overlapping rows to match overall, and when the region
            // contains vertically distinct content rows, prioritize the shift with the most
            // matching informative rows (blocking false `|dy| = 1` matches on blank background
            // while still detecting scroll inside windows with stationary headers/toolbars).
            let info_ok = if total_informative >= 2 {
                info_matches >= 1
            } else {
                true
            };
            let better = if total_informative >= 2 {
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

    let rect = if best_dy < 0 {
        let shift = -best_dy;
        Rect::new(damage.x, damage.y, damage.w, damage.h - shift)
    } else {
        let shift = best_dy;
        Rect::new(damage.x, damage.y + shift, damage.w, damage.h - shift)
    };

    Some(SurfaceCopy {
        dx: 0,
        dy: best_dy,
        rect,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xxh64_matches_reference_vectors() {
        // Empty input with seed 0 -> canonical XXH64 digest
        assert_eq!(xxh64(b"", 0), 0xEF46_DB37_51D8_E999);
        assert_eq!(xxh64(b"a", 0), 0xD24E_C4F1_A98C_6E5B);
        assert_eq!(xxh64(b"abc", 0), 0x44BC_2CF5_AD77_0999);
        // 64-byte input (>32-byte stripe path)
        let buf: Vec<u8> = (0u8..64).collect();
        let h1 = xxh64(&buf, 0);
        let h2 = xxh64(&buf, 0);
        assert_eq!(h1, h2);
        assert_ne!(h1, xxh64(&buf, 1));
    }

    #[test]
    fn lz4_round_trip_various_sizes() {
        for size in [0usize, 1, 7, 13, 64, 512, 16_384] {
            let mut data = Vec::with_capacity(size);
            for i in 0..size {
                data.push(((i * 7 + (i / 19)) & 0xFF) as u8);
            }
            let compressed = lz4_compress_prepend_size(&data);
            let decompressed = lz4_decompress_prepend_size(&compressed, size + 64).expect("decompress");
            assert_eq!(decompressed, data, "failed at size {size}");
        }
    }

    #[test]
    fn adaptive_tile_codec_round_trip_all_modes() {
        let w = 64u32;
        let h = 64u32;
        let pixels = (w * h) as usize;

        // 1. Pal2Lz4 (2 colors: text on solid background)
        let mut pal2_rgba = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            if (i % 7) == 0 {
                pal2_rgba.extend_from_slice(&[0xF0, 0xF4, 0xF8, 0xFF]);
            } else {
                pal2_rgba.extend_from_slice(&[0x10, 0x14, 0x18, 0xFF]);
            }
        }
        let (fmt2, enc2) = encode_atlas_tile(&pal2_rgba, w, h);
        assert_eq!(fmt2, AtlasTileFormat::Pal2Lz4);
        let dec2 = decode_atlas_tile(fmt2, &enc2, w, h).expect("decode pal2");
        assert_eq!(dec2, pal2_rgba);

        // 2. Pal16Lz4 (8 colors: antialiased UI glyph / border)
        let mut pal16_rgba = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            let c = ((i % 8) * 30) as u8;
            pal16_rgba.extend_from_slice(&[c, c.wrapping_add(10), 0x80, 0xFF]);
        }
        let (fmt16, enc16) = encode_atlas_tile(&pal16_rgba, w, h);
        assert_eq!(fmt16, AtlasTileFormat::Pal16Lz4);
        let dec16 = decode_atlas_tile(fmt16, &enc16, w, h).expect("decode pal16");
        assert_eq!(dec16, pal16_rgba);

        // 3. RgbaLz4 (> 16 colors: rich gradient / icon)
        let mut rgba_raw = Vec::with_capacity(pixels * 4);
        for i in 0..pixels {
            rgba_raw.extend_from_slice(&[
                (i & 0xFF) as u8,
                ((i >> 3) & 0xFF) as u8,
                ((i * 13) & 0xFF) as u8,
                0xFF,
            ]);
        }
        let (fmt_rgba, enc_rgba) = encode_atlas_tile(&rgba_raw, w, h);
        assert_eq!(fmt_rgba, AtlasTileFormat::RgbaLz4);
        let dec_rgba = decode_atlas_tile(fmt_rgba, &enc_rgba, w, h).expect("decode rgba");
        assert_eq!(dec_rgba, rgba_raw);
    }

    #[test]
    fn scroll_copy_detector_finds_vertical_translation() {
        let w = 128u32;
        let h = 128u32;
        let mut prev = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let idx = ((y * w + x) * 4) as usize;
                prev[idx] = (y as u8).wrapping_mul(17).wrapping_add(x as u8);
                prev[idx + 1] = (y as u8).wrapping_mul(31);
                prev[idx + 2] = (x as u8).wrapping_mul(13);
                prev[idx + 3] = 0xFF;
            }
        }

        // Scroll content UP by 24 pixels (dy = -24: row y in curr comes from row y + 24 in prev)
        let shift = 24u32;
        let mut curr = vec![0u8; (w * h * 4) as usize];
        for y in 0..(h - shift) {
            let src_off = ((y + shift) * w * 4) as usize;
            let dst_off = (y * w * 4) as usize;
            let row_len = (w * 4) as usize;
            curr[dst_off..dst_off + row_len].copy_from_slice(&prev[src_off..src_off + row_len]);
        }
        // Newly exposed bottom 24 rows have new content
        for y in (h - shift)..h {
            for x in 0..w {
                let idx = ((y * w + x) * 4) as usize;
                curr[idx] = 0xAA;
                curr[idx + 1] = y as u8;
                curr[idx + 2] = x as u8;
                curr[idx + 3] = 0xFF;
            }
        }

        let copy = detect_scroll_copy(&prev, &curr, w, Rect::new(0, 0, w as i32, h as i32))
            .expect("should detect vertical scroll");
        assert_eq!(copy.dx, 0);
        assert_eq!(copy.dy, -(shift as i32));
        assert_eq!(copy.rect, Rect::new(0, 0, w as i32, (h - shift) as i32));
    }

    #[test]
    fn scroll_copy_detector_locks_onto_text_on_mostly_blank_page_with_scrollbar() {
        // Models a sparse page like example.com (mostly uniform #F0F0F0 background, a centered
        // text card that scrolls up by 48 px, and a right-edge scrollbar thumb that moves down).
        let w = 256u32;
        let h = 256u32;
        let bg = [0xF0u8, 0xF0, 0xF0, 0xFF];
        let mut prev = bg.repeat((w * h) as usize);
        let mut curr = bg.repeat((w * h) as usize);

        let shift = 48i32;
        for card_row in 0..40i32 {
            let prev_y = 90 + card_row;
            let curr_y = prev_y - shift;
            for x in 48..200i32 {
                let color = [
                    (card_row as u8).wrapping_mul(29).wrapping_add(x as u8),
                    (card_row as u8).wrapping_mul(53),
                    0x33,
                    0xFF,
                ];
                let p_idx = ((prev_y as u32 * w + x as u32) * 4) as usize;
                let c_idx = ((curr_y as u32 * w + x as u32) * 4) as usize;
                prev[p_idx..p_idx + 4].copy_from_slice(&color);
                curr[c_idx..c_idx + 4].copy_from_slice(&color);
            }
        }

        // Right-edge 12px scrollbar thumb moves in the opposite direction (+20 px)
        for y in 20..80u32 {
            for x in (w - 12)..w {
                let p_idx = ((y * w + x) * 4) as usize;
                prev[p_idx..p_idx + 4].copy_from_slice(&[0x88, 0x88, 0x88, 0xFF]);
                let c_idx = (((y + 20) * w + x) * 4) as usize;
                curr[c_idx..c_idx + 4].copy_from_slice(&[0x88, 0x88, 0x88, 0xFF]);
            }
        }

        let copy = detect_scroll_copy(&prev, &curr, w, Rect::new(0, 0, w as i32, h as i32))
            .expect("should detect vertical scroll on sparse page with scrollbar");
        assert_eq!(copy.dx, 0);
        assert_eq!(copy.dy, -shift);
        assert_eq!(copy.rect, Rect::new(0, 0, w as i32, h as i32 - shift));
    }
}
