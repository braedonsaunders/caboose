//! Surface Atlas Engine (Layer 0): per-session LRU tile cache tracker (`AtlasCacheTracker`)
//! and per-window RGBA8888 shadow buffer, `CopyRect` scroll detector, solid-fill coalescer,
//! and adaptive lossless tile encoder (`AtlasWindowEncoder`).

use crate::encode::{Input, Pixels, ShmPicture};
#[cfg(test)]
use crate::encode::CpuImage;
use crate::motion;
use caboose_display_protocol::atlas::{detect_scroll_copy, encode_atlas_tile, xxh64};
use caboose_display_protocol::{
    Rect, Size, SurfaceBatch, SurfaceFill, SurfaceTile, SurfaceTileRef,
};
use std::collections::{HashMap, VecDeque};

pub const ATLAS_CACHE_CAPACITY: usize = 32_768;
/// Conservative server-side LRU capacity (leaving a 4,096-tile margin below the client's
/// 32,768-tile cache so minor LRU ordering differences never reference a client-evicted tile).
pub const SERVER_ATLAS_CACHE_CAPACITY: usize = ATLAS_CACHE_CAPACITY - 4_096;
const TILE_SIZE: i32 = 64;

/// Tracks which 64×64 RGBA8888 tile hashes the connected display client currently holds in
/// its session-wide LRU cache (up to 32,768 tiles on the client, tracked conservatively up to
/// [`SERVER_ATLAS_CACHE_CAPACITY`] on the server).
///
/// Entries are only inserted/touched via [`AtlasCacheTracker::try_record_published_batch`] when a
/// [`SurfaceBatch`] is actually sent to the client on the main event loop, ensuring workers
/// never emit [`SurfaceTileRef`]s for intra-batch duplicate new tiles or unpublished frames.
#[derive(Clone)]
pub struct AtlasCacheTracker {
    pub epoch: u64,
    capacity: usize,
    order: VecDeque<(u64, u64)>,
    entries: HashMap<u64, u64>,
    stamp: u64,
}

impl Default for AtlasCacheTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl AtlasCacheTracker {
    pub fn new() -> Self {
        Self::with_capacity(SERVER_ATLAS_CACHE_CAPACITY)
    }

    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            epoch: 1,
            capacity: capacity.max(1),
            order: VecDeque::new(),
            entries: HashMap::new(),
            stamp: 0,
        }
    }

    /// Clears the cache and advances `epoch`, returning the new epoch value for `SurfaceReset`.
    pub fn reset(&mut self) -> u64 {
        self.epoch += 1;
        self.order.clear();
        self.entries.clear();
        self.stamp = 0;
        self.epoch
    }

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Pure read-only check whether `hash` has already been published to the client's cache.
    pub fn contains(&self, hash: u64) -> bool {
        self.entries.contains_key(&hash)
    }

    /// If `hash` is present in the client's cache, marks it most-recently-used and returns `true`.
    pub fn contains_and_touch(&mut self, hash: u64) -> bool {
        if self.entries.contains_key(&hash) {
            self.stamp += 1;
            self.entries.insert(hash, self.stamp);
            self.order.push_back((hash, self.stamp));
            self.compact_if_needed();
            true
        } else {
            false
        }
    }

    /// Inserts `hash` as most-recently-used, evicting the least-recently-used entry if at capacity.
    pub fn insert(&mut self, hash: u64) {
        self.stamp += 1;
        let s = self.stamp;
        self.entries.insert(hash, s);
        self.order.push_back((hash, s));
        while self.entries.len() > self.capacity {
            if let Some((old_hash, old_stamp)) = self.order.pop_front() {
                if self.entries.get(&old_hash) == Some(&old_stamp) {
                    self.entries.remove(&old_hash);
                }
            } else {
                break;
            }
        }
        self.compact_if_needed();
    }

    /// Verifies that every `SurfaceTileRef` in `batch` is still present in the session cache
    /// (not evicted by a concurrent window's batch since worker encoding), and if so, touches
    /// all `refs` and inserts all 64×64 `tiles`.
    pub fn try_record_published_batch(&mut self, batch: &SurfaceBatch) -> bool {
        if !batch.refs.iter().all(|r| self.entries.contains_key(&r.hash)) {
            return false;
        }
        for r in &batch.refs {
            let _ = self.contains_and_touch(r.hash);
        }
        for t in &batch.tiles {
            if t.rect.w == TILE_SIZE && t.rect.h == TILE_SIZE {
                if let Some(hash) = t.hash {
                    self.insert(hash);
                }
            }
        }
        true
    }

    /// Records all `refs` (LRU touch) and 64×64 `tiles` (LRU insert) in `batch` once the batch
    /// is published to the client connection.
    #[allow(dead_code)]
    pub fn record_published_batch(&mut self, batch: &SurfaceBatch) {
        let _ = self.try_record_published_batch(batch);
    }

    fn compact_if_needed(&mut self) {
        if self.order.len() > self.capacity.saturating_mul(4).max(64) {
            self.order.retain(|(h, s)| self.entries.get(h) == Some(s));
        }
    }
}

/// Per-window RGBA8888 shadow buffer and `SurfaceBatch` encoder.
#[derive(Default)]
pub struct AtlasWindowEncoder {
    pub shadow: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub seq: u64,
    staging: Vec<u8>,
}

impl AtlasWindowEncoder {
    pub fn new() -> Self {
        Self::default()
    }

    #[allow(dead_code)]
    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Encodes a window picture from `Input` (`CpuImage` or `ShmPicture`) into an atomic
    /// `SurfaceBatch`, updating `self.shadow` while consulting `cache` read-only.
    ///
    /// Callers must invoke [`AtlasCacheTracker::try_record_published_batch`] when the returned
    /// `SurfaceBatch` is actually sent to the client.
    #[allow(clippy::too_many_arguments)]
    pub fn encode_input(
        &mut self,
        window_id: u64,
        pts_us: u64,
        rect: Rect,
        width: u32,
        height: u32,
        input: Input<'_>,
        alpha: bool,
        keyframe: bool,
        damage: Option<&[Rect]>,
        excluded: Option<Rect>,
        cache: &AtlasCacheTracker,
    ) -> Result<(Option<SurfaceBatch>, Vec<Rect>), String> {
        match input {
            Input::Cpu(image) => {
                if image.width < width || image.height < height {
                    return Err(format!(
                        "atlas input {}x{} smaller than {}x{}",
                        image.width, image.height, width, height
                    ));
                }
                let pixels = Pixels { data: &image.data, stride: image.stride };
                Ok(self.encode_pixels(
                    window_id, pts_us, rect, width, height, &pixels, alpha, keyframe, damage, excluded, cache,
                ))
            }
            Input::CpuAt(image, x, y) => {
                if x + width > image.width || y + height > image.height {
                    return Err("atlas input crop outside image".into());
                }
                let start = y as usize * image.stride + x as usize * 4;
                let pixels = Pixels { data: &image.data[start..], stride: image.stride };
                Ok(self.encode_pixels(
                    window_id, pts_us, rect, width, height, &pixels, alpha, keyframe, damage, excluded, cache,
                ))
            }
            Input::Shm(shm) => {
                self.encode_shm(
                    window_id, pts_us, rect, width, height, shm, alpha, keyframe, damage, excluded, cache,
                )
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn encode_shm(
        &mut self,
        window_id: u64,
        pts_us: u64,
        rect: Rect,
        width: u32,
        height: u32,
        shm: &ShmPicture,
        alpha: bool,
        keyframe: bool,
        damage: Option<&[Rect]>,
        excluded: Option<Rect>,
        cache: &AtlasCacheTracker,
    ) -> Result<(Option<SurfaceBatch>, Vec<Rect>), String> {
        smithay::wayland::shm::with_buffer_contents(&shm.buffer, |ptr, len, data| {
            let (w, h) = (width as i32, height as i32);
            if shm.x < 0 || shm.y < 0 || shm.x + w > data.width || shm.y + h > data.height {
                return Err("atlas picture is outside shm buffer".to_string());
            }
            let stride = data.stride as usize;
            let start = data.offset as usize + shm.y as usize * stride + shm.x as usize * 4;
            if start + (height as usize).saturating_sub(1) * stride + (width as usize) * 4 > len {
                return Err("atlas shm buffer is outside pool".to_string());
            }
            // SAFETY: Smithay maps `len` bytes at `ptr` for the duration of this closure.
            let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
            let pixels = Pixels { data: &pool[start..], stride };
            Ok(self.encode_pixels(
                window_id, pts_us, rect, width, height, &pixels, alpha, keyframe, damage, excluded, cache,
            ))
        })
        .map_err(|e| format!("shm buffer: {e:?}"))?
    }

    #[allow(clippy::too_many_arguments)]
    pub fn encode_pixels(
        &mut self,
        window_id: u64,
        pts_us: u64,
        rect: Rect,
        width: u32,
        height: u32,
        src: &Pixels<'_>,
        alpha: bool,
        keyframe: bool,
        damage: Option<&[Rect]>,
        excluded: Option<Rect>,
        cache: &AtlasCacheTracker,
    ) -> (Option<SurfaceBatch>, Vec<Rect>) {
        if width == 0 || height == 0 {
            return (None, Vec::new());
        }
        let w_usize = width as usize;
        let h_usize = height as usize;
        let total_bytes = w_usize * h_usize * 4;
        let resized = self.width != width || self.height != height || self.shadow.len() != total_bytes;
        let is_keyframe = keyframe || resized;

        if resized {
            self.width = width;
            self.height = height;
            self.shadow.clear();
            self.shadow.resize(total_bytes, 0);
        }
        if self.staging.len() != total_bytes {
            self.staging.resize(total_bytes, 0);
            self.staging.copy_from_slice(&self.shadow);
        }

        let full = Rect::new(0, 0, width as i32, height as i32);
        let raw_damage: Vec<Rect> = match damage.filter(|_| !is_keyframe) {
            None => vec![full],
            Some(d) => d.iter().filter_map(|r| motion::intersect(*r, full)).collect(),
        };

        let effective_damage: Vec<Rect> = match excluded.and_then(|ex| motion::intersect(ex, full)) {
            None => raw_damage,
            Some(ex) => raw_damage.into_iter().flat_map(|r| motion::subtract(r, ex)).collect(),
        };

        if effective_damage.is_empty() && !is_keyframe {
            return (None, Vec::new());
        }

        let cols = w_usize.div_ceil(TILE_SIZE as usize);
        let rows = h_usize.div_ceil(TILE_SIZE as usize);
        let mut dirty_tiles = vec![false; cols * rows];

        if is_keyframe {
            if let Some(ex) = excluded.and_then(|ex| motion::intersect(ex, full)) {
                for r in &effective_damage {
                    mark_tiles(&mut dirty_tiles, cols, rows, *r);
                }
                convert_bgrx_regions_to_rgba(
                    src.data,
                    src.stride,
                    &mut self.staging,
                    w_usize * 4,
                    &effective_damage,
                    alpha,
                );
                let _ = ex;
            } else {
                dirty_tiles.fill(true);
                convert_bgrx_regions_to_rgba(
                    src.data,
                    src.stride,
                    &mut self.staging,
                    w_usize * 4,
                    &[full],
                    alpha,
                );
            }
        } else {
            convert_bgrx_regions_to_rgba(
                src.data,
                src.stride,
                &mut self.staging,
                w_usize * 4,
                &effective_damage,
                alpha,
            );
            for r in &effective_damage {
                mark_tiles(&mut dirty_tiles, cols, rows, *r);
            }
        }

        let mut copies = Vec::new();
        if !is_keyframe && excluded.is_none() {
            let scroll_candidates = coalesced_scroll_regions(&effective_damage, width as i32, height as i32);
            for cand in scroll_candidates {
                if cand.w >= 64 && cand.h >= 64 {
                    if effective_damage.len() > 1 {
                        // Ensure the entire candidate bounding box is converted into staging
                        // and marked dirty before applying an in-place shadow copy.
                        convert_bgrx_regions_to_rgba(
                            src.data,
                            src.stride,
                            &mut self.staging,
                            w_usize * 4,
                            &[cand],
                            alpha,
                        );
                        mark_tiles(&mut dirty_tiles, cols, rows, cand);
                    }
                    if let Some(copy) = detect_scroll_copy(&self.shadow, &self.staging, width, cand) {
                        apply_surface_copy(&mut self.shadow, width, height, copy);
                        copies.push(copy);
                    }
                }
            }
        }

        let allow_refs = !is_keyframe && std::env::var("CABOOSE_ATLAS_NO_REFS").as_deref() != Ok("1");

        let mut fills: Vec<SurfaceFill> = Vec::new();
        let mut refs: Vec<SurfaceTileRef> = Vec::new();
        let mut tiles: Vec<SurfaceTile> = Vec::new();
        let mut changed_rects: Vec<Rect> = Vec::new();

        for copy in &copies {
            changed_rects.push(copy.rect);
        }

        let mut tile_buf = Vec::with_capacity((TILE_SIZE as usize) * (TILE_SIZE as usize) * 4);
        let row_bytes = w_usize * 4;

        for ty in 0..rows {
            let y0 = (ty * TILE_SIZE as usize) as i32;
            let th = ((height as i32) - y0).min(TILE_SIZE);
            let mut prev_fill_idx: Option<usize> = None;

            for tx in 0..cols {
                if !dirty_tiles[ty * cols + tx] {
                    prev_fill_idx = None;
                    continue;
                }
                let x0 = (tx * TILE_SIZE as usize) as i32;
                let tw = ((width as i32) - x0).min(TILE_SIZE);
                let tile_rect = Rect::new(x0, y0, tw, th);

                if !is_keyframe && tile_matches(&self.shadow, &self.staging, row_bytes, tile_rect) {
                    prev_fill_idx = None;
                    continue;
                }

                // Copy new pixels into shadow and extract linear tile_buf
                tile_buf.clear();
                let x_byte = (x0 as usize) * 4;
                let w_byte = (tw as usize) * 4;
                for r in 0..(th as usize) {
                    let off = ((y0 as usize) + r) * row_bytes + x_byte;
                    let slice = &self.staging[off..off + w_byte];
                    self.shadow[off..off + w_byte].copy_from_slice(slice);
                    tile_buf.extend_from_slice(slice);
                }
                changed_rects.push(tile_rect);

                if let Some(rgba) = uniform_rgba(&tile_buf) {
                    if let Some(idx) = prev_fill_idx {
                        let last = &mut fills[idx];
                        if last.rgba == rgba
                            && last.rect.y == tile_rect.y
                            && last.rect.h == tile_rect.h
                            && last.rect.x + last.rect.w == tile_rect.x
                        {
                            last.rect.w += tile_rect.w;
                            continue;
                        }
                    }
                    prev_fill_idx = Some(fills.len());
                    fills.push(SurfaceFill { rect: tile_rect, rgba });
                    continue;
                }
                prev_fill_idx = None;

                if tw == TILE_SIZE && th == TILE_SIZE {
                    let hash = xxh64(&tile_buf, 0);
                    // Only emit a `SurfaceTileRef` if `hash` was ALREADY published to the client
                    // in a prior batch (`cache` is immutable during batch assembly). Clients apply
                    // `batch.refs` before `batch.tiles`, so a tile newly introduced in this batch
                    // must always be sent in `batch.tiles`.
                    if allow_refs && cache.contains(hash) {
                        refs.push(SurfaceTileRef { x: x0, y: y0, hash });
                    } else {
                        let (format, data) = encode_atlas_tile(&tile_buf, tw as u32, th as u32);
                        tiles.push(SurfaceTile {
                            rect: tile_rect,
                            hash: Some(hash),
                            format,
                            data,
                        });
                    }
                } else {
                    let (format, data) = encode_atlas_tile(&tile_buf, tw as u32, th as u32);
                    tiles.push(SurfaceTile {
                        rect: tile_rect,
                        hash: None,
                        format,
                        data,
                    });
                }
            }
        }

        // Merge vertically adjacent identical-width/x/color fills
        coalesce_vertical_fills(&mut fills);

        if !is_keyframe && copies.is_empty() && fills.is_empty() && refs.is_empty() && tiles.is_empty() {
            return (None, Vec::new());
        }

        let seq = self.seq;
        self.seq += 1;

        let batch = SurfaceBatch {
            id: window_id,
            seq,
            pts_us,
            size: Size { w: width as i32, h: height as i32 },
            rect,
            keyframe: is_keyframe,
            copies,
            fills,
            refs,
            tiles,
        };
        (Some(batch), changed_rects)
    }
}

fn mark_tiles(dirty: &mut [bool], cols: usize, rows: usize, r: Rect) {
    if r.w <= 0 || r.h <= 0 {
        return;
    }
    let tx0 = (r.x.max(0) as usize) / (TILE_SIZE as usize);
    let ty0 = (r.y.max(0) as usize) / (TILE_SIZE as usize);
    let tx1 = ((r.x + r.w).max(0) as usize).div_ceil(TILE_SIZE as usize).min(cols);
    let ty1 = ((r.y + r.h).max(0) as usize).div_ceil(TILE_SIZE as usize).min(rows);
    for ty in ty0..ty1.min(rows) {
        for tx in tx0..tx1 {
            dirty[ty * cols + tx] = true;
        }
    }
}

fn convert_bgrx_regions_to_rgba(
    src: &[u8],
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
    regions: &[Rect],
    alpha: bool,
) {
    for r in regions {
        if r.w <= 0 || r.h <= 0 || r.x < 0 || r.y < 0 {
            continue;
        }
        let x0 = r.x as usize;
        let y0 = r.y as usize;
        let w = r.w as usize;
        let h = r.h as usize;
        for row in 0..h {
            let sy = y0 + row;
            let s_off = sy * src_stride + x0 * 4;
            let d_off = sy * dst_stride + x0 * 4;
            let s_row = &src[s_off..s_off + w * 4];
            let d_row = &mut dst[d_off..d_off + w * 4];
            if alpha {
                for (s_px, d_px) in s_row.chunks_exact(4).zip(d_row.chunks_exact_mut(4)) {
                    let a = s_px[3];
                    match a {
                        0 => d_px.copy_from_slice(&[0, 0, 0, 0]),
                        255 => d_px.copy_from_slice(&[s_px[2], s_px[1], s_px[0], 255]),
                        _ => {
                            let un = |c: u8| ((c as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8;
                            d_px.copy_from_slice(&[un(s_px[2]), un(s_px[1]), un(s_px[0]), a]);
                        }
                    }
                }
            } else {
                for (s_px, d_px) in s_row.chunks_exact(4).zip(d_row.chunks_exact_mut(4)) {
                    d_px[0] = s_px[2];
                    d_px[1] = s_px[1];
                    d_px[2] = s_px[0];
                    d_px[3] = 0xFF;
                }
            }
        }
    }
}

fn coalesced_scroll_regions(damage: &[Rect], width: i32, height: i32) -> Vec<Rect> {
    if damage.is_empty() {
        return Vec::new();
    }
    if damage.len() == 1 {
        return vec![damage[0]];
    }
    let mut x0 = i32::MAX;
    let mut y0 = i32::MAX;
    let mut x1 = i32::MIN;
    let mut y1 = i32::MIN;
    for r in damage {
        x0 = x0.min(r.x.max(0));
        y0 = y0.min(r.y.max(0));
        x1 = x1.max((r.x + r.w).min(width));
        y1 = y1.max((r.y + r.h).min(height));
    }
    if x1 > x0 && y1 > y0 {
        vec![Rect::new(x0, y0, x1 - x0, y1 - y0)]
    } else {
        Vec::new()
    }
}

/// Shifts `shadow` in place according to `SurfaceCopy { dx, dy, rect }`, where `rect` is the
/// destination rectangle and `(rect.x - dx, rect.y - dy)` is the source origin.
pub fn apply_surface_copy(buf: &mut [u8], width: u32, height: u32, copy: caboose_display_protocol::SurfaceCopy) {
    let dst = copy.rect;
    if dst.w <= 0 || dst.h <= 0 {
        return;
    }
    let src_x = dst.x - copy.dx;
    let src_y = dst.y - copy.dy;
    if dst.x < 0
        || dst.y < 0
        || src_x < 0
        || src_y < 0
        || dst.x + dst.w > width as i32
        || dst.y + dst.h > height as i32
        || src_x + dst.w > width as i32
        || src_y + dst.h > height as i32
    {
        return;
    }
    let stride = (width as usize) * 4;
    let row_bytes = (dst.w as usize) * 4;
    let h = dst.h as usize;

    if copy.dy > 0 {
        for r in (0..h).rev() {
            let sy = (src_y as usize) + r;
            let dy = (dst.y as usize) + r;
            let s_off = sy * stride + (src_x as usize) * 4;
            let d_off = dy * stride + (dst.x as usize) * 4;
            buf.copy_within(s_off..s_off + row_bytes, d_off);
        }
    } else if copy.dy < 0 {
        for r in 0..h {
            let sy = (src_y as usize) + r;
            let dy = (dst.y as usize) + r;
            let s_off = sy * stride + (src_x as usize) * 4;
            let d_off = dy * stride + (dst.x as usize) * 4;
            buf.copy_within(s_off..s_off + row_bytes, d_off);
        }
    } else if copy.dx != 0 {
        for r in 0..h {
            let sy = (src_y as usize) + r;
            let dy = (dst.y as usize) + r;
            let s_off = sy * stride + (src_x as usize) * 4;
            let d_off = dy * stride + (dst.x as usize) * 4;
            buf.copy_within(s_off..s_off + row_bytes, d_off);
        }
    }
}

fn tile_matches(shadow: &[u8], staging: &[u8], row_bytes: usize, r: Rect) -> bool {
    let x_byte = (r.x as usize) * 4;
    let w_byte = (r.w as usize) * 4;
    for row in 0..(r.h as usize) {
        let off = ((r.y as usize) + row) * row_bytes + x_byte;
        if shadow[off..off + w_byte] != staging[off..off + w_byte] {
            return false;
        }
    }
    true
}

fn uniform_rgba(tile_rgba: &[u8]) -> Option<u32> {
    if tile_rgba.len() < 4 {
        return None;
    }
    let first: [u8; 4] = tile_rgba[0..4].try_into().unwrap();
    for px in tile_rgba[4..].chunks_exact(4) {
        if px != first {
            return None;
        }
    }
    Some(u32::from_be_bytes(first))
}

fn coalesce_vertical_fills(fills: &mut Vec<SurfaceFill>) {
    let mut i = 0;
    while i < fills.len() {
        let mut j = i + 1;
        while j < fills.len() {
            if fills[j].rgba == fills[i].rgba
                && fills[j].rect.x == fills[i].rect.x
                && fills[j].rect.w == fills[i].rect.w
                && fills[i].rect.y + fills[i].rect.h == fills[j].rect.y
            {
                fills[i].rect.h += fills[j].rect.h;
                fills.remove(j);
            } else {
                j += 1;
            }
        }
        i += 1;
    }
}

/// Applies a `SurfaceBatch` to an RGBA8888 surface buffer and tile cache, returning `(width, height)`.
/// Used by unit tests and `caboose-display-probe` to reconstruct the exact window surface.
#[allow(dead_code)]
pub fn reconstruct_surface_batch(
    surface: &mut Vec<u8>,
    surface_size: &mut (u32, u32),
    tile_cache: &mut HashMap<u64, Vec<u8>>,
    batch: &SurfaceBatch,
) -> Result<(), String> {
    let w = batch.size.w.max(0) as u32;
    let h = batch.size.h.max(0) as u32;
    let needed = (w as usize) * (h as usize) * 4;
    if *surface_size != (w, h) || surface.len() != needed {
        *surface_size = (w, h);
        surface.clear();
        surface.resize(needed, 0);
    }
    for copy in &batch.copies {
        apply_surface_copy(surface, w, h, *copy);
    }
    let stride = (w as usize) * 4;
    for fill in &batch.fills {
        let r = fill.rect;
        if r.x < 0 || r.y < 0 || r.x + r.w > w as i32 || r.y + r.h > h as i32 {
            return Err("fill out of bounds".into());
        }
        let px = fill.rgba.to_be_bytes();
        for y in (r.y as usize)..((r.y + r.h) as usize) {
            let row = &mut surface[y * stride + (r.x as usize) * 4..y * stride + ((r.x + r.w) as usize) * 4];
            for dst in row.chunks_exact_mut(4) {
                dst.copy_from_slice(&px);
            }
        }
    }
    for tref in &batch.refs {
        let Some(tile) = tile_cache.get(&tref.hash) else {
            return Err(format!("missing cached tile hash 0x{:016x}", tref.hash));
        };
        if tref.x < 0 || tref.y < 0 || tref.x + TILE_SIZE > w as i32 || tref.y + TILE_SIZE > h as i32 {
            return Err("tile ref out of bounds".into());
        }
        for row in 0..(TILE_SIZE as usize) {
            let s_off = row * (TILE_SIZE as usize) * 4;
            let d_off = ((tref.y as usize) + row) * stride + (tref.x as usize) * 4;
            surface[d_off..d_off + (TILE_SIZE as usize) * 4]
                .copy_from_slice(&tile[s_off..s_off + (TILE_SIZE as usize) * 4]);
        }
    }
    for tile in &batch.tiles {
        let r = tile.rect;
        if r.x < 0 || r.y < 0 || r.w <= 0 || r.h <= 0 || r.x + r.w > w as i32 || r.y + r.h > h as i32 {
            return Err("tile out of bounds".into());
        }
        let decoded = caboose_display_protocol::atlas::decode_atlas_tile(
            tile.format,
            &tile.data,
            r.w as u32,
            r.h as u32,
        )
        .map_err(|e| e.to_string())?;
        if let Some(hash) = tile.hash {
            if r.w == TILE_SIZE && r.h == TILE_SIZE {
                tile_cache.insert(hash, decoded.clone());
            }
        }
        let row_bytes = (r.w as usize) * 4;
        for row in 0..(r.h as usize) {
            let s_off = row * row_bytes;
            let d_off = ((r.y as usize) + row) * stride + (r.x as usize) * 4;
            surface[d_off..d_off + row_bytes].copy_from_slice(&decoded[s_off..s_off + row_bytes]);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paint_test_image(w: u32, h: u32, y_offset: u32) -> CpuImage {
        let mut img = CpuImage::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let off = (y as usize) * img.stride + (x as usize) * 4;
                let sy = y + y_offset;
                if x < 64 && y < 64 && y_offset == 0 {
                    // Solid color tile at top-left (B=0x30, G=0x20, R=0x10)
                    img.data[off..off + 4].copy_from_slice(&[0x30, 0x20, 0x10, 0x00]);
                } else {
                    // Textured content
                    let r = ((sy.wrapping_mul(17) ^ x.wrapping_mul(31)) & 0xFF) as u8;
                    let g = ((sy.wrapping_mul(53) + x.wrapping_mul(7)) & 0xFF) as u8;
                    let b = ((sy ^ (x * 3)) & 0xFF) as u8;
                    img.data[off..off + 4].copy_from_slice(&[b, g, r, 0x00]);
                }
            }
        }
        img
    }

    #[test]
    fn keyframe_emission_and_bit_exact_reconstruction() {
        let (w, h) = (160u32, 140u32); // Includes 64x64 tiles and clipped edge tiles (32px right, 12px bottom)
        let img = paint_test_image(w, h, 0);
        let mut enc = AtlasWindowEncoder::new();
        let mut cache = AtlasCacheTracker::new();
        let rect = Rect::new(0, 0, w as i32, h as i32);

        let (batch, _) = enc
            .encode_input(1, 1000, rect, w, h, Input::Cpu(&img), false, true, None, None, &cache)
            .unwrap();
        let batch = batch.expect("keyframe must emit SurfaceBatch");
        assert!(cache.try_record_published_batch(&batch));
        assert!(batch.keyframe);
        assert!(!batch.fills.is_empty(), "top-left uniform tile should emit SurfaceFill");
        assert!(!batch.tiles.is_empty(), "patterned tiles should emit SurfaceTile");

        let mut client_surface = Vec::new();
        let mut client_size = (0, 0);
        let mut client_cache = HashMap::new();
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &batch).unwrap();

        assert_eq!(client_size, (w, h));
        assert_eq!(client_surface, enc.shadow, "reconstructed RGBA8888 surface must match shadow byte-for-byte");

        // Verify exact conversion from BGRX to RGBA8888 (with alpha = 0xFF)
        for y in 0..h as usize {
            for x in 0..w as usize {
                let s_off = y * img.stride + x * 4;
                let d_off = (y * w as usize + x) * 4;
                assert_eq!(
                    &client_surface[d_off..d_off + 4],
                    &[img.data[s_off + 2], img.data[s_off + 1], img.data[s_off], 0xFF]
                );
            }
        }
    }

    #[test]
    fn vertical_scroll_detection_emits_copy_and_only_encodes_exposed_strip() {
        let (w, h) = (128u32, 192u32);
        let img0 = paint_test_image(w, h, 10);
        let mut enc = AtlasWindowEncoder::new();
        let mut cache = AtlasCacheTracker::new();
        let rect = Rect::new(0, 0, w as i32, h as i32);

        let (batch0, _) = enc
            .encode_input(1, 1000, rect, w, h, Input::Cpu(&img0), false, true, None, None, &cache)
            .unwrap();
        let batch0 = batch0.unwrap();
        assert!(cache.try_record_published_batch(&batch0));

        let mut client_surface = Vec::new();
        let mut client_size = (0, 0);
        let mut client_cache = HashMap::new();
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &batch0).unwrap();

        // Scroll content up by 32 pixels (y_offset = 10 + 32 = 42, so dy = -32)
        let img1 = paint_test_image(w, h, 42);
        let damage = [Rect::new(0, 0, w as i32, h as i32)];
        let (batch1, _) = enc
            .encode_input(1, 2000, rect, w, h, Input::Cpu(&img1), false, false, Some(&damage), None, &cache)
            .unwrap();
        let batch1 = batch1.expect("scroll frame must emit SurfaceBatch");
        assert!(cache.try_record_published_batch(&batch1));

        assert_eq!(batch1.copies.len(), 1, "must detect vertical scroll copy");
        assert_eq!(batch1.copies[0].dx, 0);
        assert_eq!(batch1.copies[0].dy, -32);
        assert_eq!(batch1.copies[0].rect, Rect::new(0, 0, 128, 160));
        // Only the bottom row of 64x64 tiles (y = 128..192, 2 tiles wide) has newly exposed pixels!
        // The top two rows (y = 0..128) match the shifted shadow and emit 0 tiles!
        assert_eq!(batch1.tiles.len(), 2, "only the 2 bottom exposed tiles should be encoded");
        assert!(batch1.tiles.iter().all(|t| t.rect.y == 128));

        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &batch1).unwrap();
        assert_eq!(client_surface, enc.shadow, "client surface after CopyRect + exposed strip must be bit-exact");
    }

    #[test]
    fn scroll_with_stationary_scrollbar_emits_copy_and_reconstructs_bit_exact() {
        let (w, h) = (256u32, 192u32);
        let make_frame = |y_offset: u32, thumb_y: u32| -> CpuImage {
            let mut img = paint_test_image(w, h, y_offset);
            // Paint a 16px right-edge scrollbar track and counter-moving thumb
            for y in 0..h {
                for x in (w - 16)..w {
                    let off = (y as usize) * img.stride + (x as usize) * 4;
                    let c = if y >= thumb_y && y < thumb_y + 32 { 0x55 } else { 0xCC };
                    img.data[off..off + 4].copy_from_slice(&[c, c, c, 0x00]);
                }
            }
            img
        };

        let img0 = make_frame(10, 16);
        let img1 = make_frame(42, 48); // Content scrolls up by 32px; scrollbar thumb moves down by 32px
        let mut enc = AtlasWindowEncoder::new();
        let mut cache = AtlasCacheTracker::new();
        let rect = Rect::new(0, 0, w as i32, h as i32);

        let mut client_surface = Vec::new();
        let mut client_size = (0, 0);
        let mut client_cache = HashMap::new();

        let (b0, _) = enc
            .encode_input(1, 1000, rect, w, h, Input::Cpu(&img0), false, true, None, None, &cache)
            .unwrap();
        let b0 = b0.unwrap();
        assert!(cache.try_record_published_batch(&b0));
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b0).unwrap();

        let damage = [Rect::new(0, 0, w as i32, h as i32)];
        let (b1, _) = enc
            .encode_input(1, 2000, rect, w, h, Input::Cpu(&img1), false, false, Some(&damage), None, &cache)
            .unwrap();
        let b1 = b1.unwrap();
        assert!(cache.try_record_published_batch(&b1));
        assert_eq!(b1.copies.len(), 1, "must still emit CopyRect despite counter-moving scrollbar");
        assert_eq!(b1.copies[0].dy, -32);
        // Out of 12 total 64x64 tiles (4x3), the 6 interior scrolled tiles in the top 2 rows are skipped!
        assert!(b1.tiles.len() <= 6, "interior scrolled tiles must be skipped by CopyRect");

        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b1).unwrap();
        assert_eq!(client_surface, enc.shadow, "scrollbar + scrolled content must reconstruct bit-exactly");
    }

    #[test]
    fn tab_switch_revisited_view_emits_zero_byte_tile_refs() {
        let (w, h) = (128u32, 128u32);
        let tab_a = paint_test_image(w, h, 100);
        let tab_b = paint_test_image(w, h, 500);
        let mut enc = AtlasWindowEncoder::new();
        let mut cache = AtlasCacheTracker::new();
        let rect = Rect::new(0, 0, w as i32, h as i32);

        let mut client_surface = Vec::new();
        let mut client_size = (0, 0);
        let mut client_cache = HashMap::new();

        // Frame 1: Tab A (4 full 64x64 tiles)
        let (b1, _) = enc
            .encode_input(1, 1000, rect, w, h, Input::Cpu(&tab_a), false, true, None, None, &cache)
            .unwrap();
        let b1 = b1.unwrap();
        assert!(cache.try_record_published_batch(&b1));
        assert_eq!(b1.tiles.len(), 4);
        assert_eq!(b1.refs.len(), 0);
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b1).unwrap();
        let expected_tab_a = client_surface.clone();

        // Frame 2: Switch to Tab B (4 new 64x64 tiles)
        let (b2, _) = enc
            .encode_input(1, 2000, rect, w, h, Input::Cpu(&tab_b), false, false, None, None, &cache)
            .unwrap();
        let b2 = b2.unwrap();
        assert!(cache.try_record_published_batch(&b2));
        assert_eq!(b2.tiles.len(), 4);
        assert_eq!(b2.refs.len(), 0);
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b2).unwrap();

        // Frame 3: Switch back to Tab A -> all 4 tiles are already in `AtlasCacheTracker`, emitted as `refs`!
        let (b3, _) = enc
            .encode_input(1, 3000, rect, w, h, Input::Cpu(&tab_a), false, false, None, None, &cache)
            .unwrap();
        let b3 = b3.unwrap();
        assert!(cache.try_record_published_batch(&b3));
        assert_eq!(b3.tiles.len(), 0, "revisited tab must encode 0 tile bytes");
        assert_eq!(b3.refs.len(), 4, "revisited tab must emit 4 SurfaceTileRef entries");

        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b3).unwrap();
        assert_eq!(client_surface, expected_tab_a, "reconstructed surface from refs must match Tab A bit-for-byte");
    }

    #[test]
    fn duplicate_new_tiles_in_same_delta_batch_and_unpublished_batches_never_emit_premature_refs() {
        let (w, h) = (128u32, 64u32);
        let initial = paint_test_image(w, h, 10);
        let mut enc1 = AtlasWindowEncoder::new();
        let mut enc2 = AtlasWindowEncoder::new();
        let mut cache = AtlasCacheTracker::new();
        let rect = Rect::new(0, 0, w as i32, h as i32);

        let mut client_surface = Vec::new();
        let mut client_size = (0, 0);
        let mut client_cache = HashMap::new();

        // 1. Keyframe on window 1 and window 2
        let (b1, _) = enc1
            .encode_input(1, 1000, rect, w, h, Input::Cpu(&initial), false, true, None, None, &cache)
            .unwrap();
        let b1 = b1.unwrap();
        assert!(cache.try_record_published_batch(&b1));
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &b1).unwrap();

        let (b2_init, _) = enc2
            .encode_input(2, 1000, rect, w, h, Input::Cpu(&initial), false, true, None, None, &cache)
            .unwrap();
        let b2_init = b2_init.unwrap();
        assert!(cache.try_record_published_batch(&b2_init));

        // 2. Construct an image where BOTH 64x64 tiles (x=0..64 and x=64..128) have the EXACT SAME
        //    new textured pattern (never seen before in `cache`).
        let mut dup_img = CpuImage::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let tx = x % 64;
                let off = (y as usize) * dup_img.stride + (x as usize) * 4;
                let r = ((y.wrapping_mul(37) ^ tx.wrapping_mul(19) ^ 0xA5) & 0xFF) as u8;
                let g = ((y.wrapping_mul(73) + tx.wrapping_mul(11) + 0x5A) & 0xFF) as u8;
                let b = ((y ^ (tx * 5) ^ 0x3C) & 0xFF) as u8;
                dup_img.data[off..off + 4].copy_from_slice(&[b, g, r, 0x00]);
            }
        }

        // Encode delta batch on window 1 (without publishing yet)
        let (delta1, _) = enc1
            .encode_input(1, 2000, rect, w, h, Input::Cpu(&dup_img), false, false, None, None, &cache)
            .unwrap();
        let delta1 = delta1.unwrap();
        // Because clients apply `refs` before `tiles`, the second 64x64 tile in `delta1` MUST NOT
        // be emitted as a `ref` to the first tile in the same batch!
        assert_eq!(delta1.refs.len(), 0, "intra-batch duplicate new tile must not emit premature ref");
        assert_eq!(delta1.tiles.len(), 2, "both identical new tiles in the batch must be sent as tiles");

        // Before `delta1` is published to `cache`, window 2 encodes the same `dup_img` concurrently.
        // Because `delta1` is not published yet, window 2 must also emit `tiles` (not `refs`)!
        let (delta2, _) = enc2
            .encode_input(2, 2000, rect, w, h, Input::Cpu(&dup_img), false, false, None, None, &cache)
            .unwrap();
        let delta2 = delta2.unwrap();
        assert_eq!(delta2.refs.len(), 0, "unpublished worker batch must not pollute shared cache");
        assert_eq!(delta2.tiles.len(), 2);

        // Client applies `delta1` (`refs` before `tiles`) with zero missing-hash errors!
        reconstruct_surface_batch(&mut client_surface, &mut client_size, &mut client_cache, &delta1).unwrap();
        assert_eq!(client_surface, enc1.shadow);

        // Now publish `delta1` to the session cache tracker.
        assert!(cache.try_record_published_batch(&delta1));
        assert!(cache.contains(delta1.tiles[0].hash.unwrap()));
    }

    #[test]
    fn try_record_published_batch_rejects_evicted_ref_from_concurrent_window() {
        let mut cache = AtlasCacheTracker::with_capacity(2);
        cache.insert(0x1111);
        cache.insert(0x2222);
        assert!(cache.contains(0x1111));

        // Window A snapshots `cache` when 0x1111 is present and builds a batch referencing 0x1111.
        let batch_a = SurfaceBatch {
            id: 1,
            seq: 2,
            pts_us: 2000,
            size: Size { w: 64, h: 64 },
            rect: Rect::new(0, 0, 64, 64),
            keyframe: false,
            copies: Vec::new(),
            fills: Vec::new(),
            refs: vec![SurfaceTileRef { x: 0, y: 0, hash: 0x1111 }],
            tiles: Vec::new(),
        };

        // Meanwhile Window B publishes a new tile 0x3333, evicting 0x1111 from the 2-entry cache.
        cache.insert(0x3333);
        assert!(!cache.contains(0x1111));

        // When Window A's batch reaches publication on the main loop, `try_record_published_batch`
        // must reject it so the session schedules a clean keyframe instead of sending a stale ref.
        assert!(!cache.try_record_published_batch(&batch_a));
    }
}
