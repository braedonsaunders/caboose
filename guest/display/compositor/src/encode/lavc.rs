//! Encoders through libavcodec that take pixels in system memory (wl_shm buffers, or GPU
//! buffers read back):
//!
//! - software: libx264 (H.264) and libx265 (HEVC), after a BGRX → I420 conversion of
//!   only the damaged rectangles ([`super::convert`]); for H.264 also a hint to libx264
//!   that the rest of the picture is unchanged, and the sharpening of what has gone
//!   quiet ([`super::refine`]);
//! - NVENC: h264_nvenc, hevc_nvenc and av1_nvenc. NVENC takes BGRX as is and converts on
//!   the GPU, so the CPU only copies the picture into NVENC's input buffer. This is the
//!   path on WSL2, where clients hand over wl_shm buffers and CUDA reaches the GPU
//!   through /dev/dxg.

use super::{convert, refine, scroll, Copied, CpuImage, EncodeError, Encoder, Input, Picture, Pixels, Settings, Tiles};

/// More changed runs than this go into a picture rather than tiles.
pub(super) const MAX_TILES: usize = 32;
/// More updates than this within `TILE_WINDOW_MS` are an animation: pictures, not tiles
/// (typing reaches about 15 keys a second).
const MAX_TILE_UPDATES: usize = 7;
const TILE_WINDOW_MS: u64 = 500;

/// Joins runs that span the same columns in consecutive rows, so a glyph is one tile
/// rather than one per macroblock row.
pub(super) fn merge_columns(runs: &[Rect]) -> Vec<Rect> {
    let mut out: Vec<Rect> = Vec::with_capacity(runs.len());
    for r in runs {
        match out.iter_mut().find(|o| o.x == r.x && o.w == r.w && o.y + o.h == r.y) {
            Some(o) => o.h += r.h,
            None => out.push(*r),
        }
    }
    out
}

/// A rectangle of BGRX pixels as packed RGB, for a tile.
fn rgb(src: &Pixels<'_>, r: Rect) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(r.w as usize * r.h as usize * 3);
    for y in r.y as usize..(r.y + r.h) as usize {
        for px in src.data[y * src.stride + r.x as usize * 4..][..r.w as usize * 4].chunks_exact(4) {
            rgb.extend_from_slice(&[px[2], px[1], px[0]]);
        }
    }
    rgb
}
use caboose_display_protocol::Codec;
use caboose_display_protocol::Rect;
use ff::format::Pixel;
use ffmpeg_next as ff;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Family {
    Software,
    Nvenc,
}

pub fn encoder_name(family: Family, codec: Codec) -> &'static str {
    match (family, codec) {
        (Family::Software, Codec::H264) => "libx264",
        (Family::Software, Codec::Hevc) => "libx265",
        (Family::Software, Codec::Av1) => "libsvtav1",
        (Family::Nvenc, Codec::H264) => "h264_nvenc",
        (Family::Nvenc, Codec::Hevc) => "hevc_nvenc",
        (Family::Nvenc, Codec::Av1) => "av1_nvenc",
        (Family::Software, Codec::Vp9) => "libvpx-vp9",
        (Family::Nvenc, Codec::Vp9) => "vp9 (NVENC has no VP9 encoder)",
    }
}

/// Opens a small encoder and encodes one picture, so a codec is offered only if it
/// actually works in this build of libavcodec.
pub fn probe(family: Family, codec: Codec) -> Result<(), EncodeError> {
    if codec == Codec::Vp9 || (family == Family::Software && codec == Codec::Av1) {
        return Err(EncodeError(format!("{} is not offered for window streams", codec.as_str())));
    }
    let settings = Settings { threads: 1, ..Settings::default() };
    // NVENC's minimum is larger than 64x64 on some generations.
    let (w, h) = if family == Family::Nvenc { (256, 256) } else { (64, 64) };
    let mut encoder = LavcEncoder::new(family, codec, w, h, &settings)?;
    let image = CpuImage::new(w, h);
    let picture = encoder.encode(Input::Cpu(&image), true, None)?;
    if picture.data.is_empty() || !picture.keyframe {
        return Err(EncodeError("probe produced no keyframe".into()));
    }
    Ok(())
}

pub struct LavcEncoder {
    family: Family,
    codec: Codec,
    encoder: ff::encoder::Video,
    /// The picture handed to the encoder: I420 for software, BGRX for NVENC.
    picture: ff::frame::Video,
    /// Software: the BGRX the picture was last converted from, to find which damaged
    /// blocks really changed. (NVENC's picture is BGRX and serves for itself.)
    shadow: Vec<u8>,
    /// Frozen base pixels under an independently encoded motion stream.
    excluded: Option<(Rect, Vec<u8>)>,
    masked: Vec<u8>,
    width: u32,
    height: u32,
    pts: i64,
    /// libx264 with refinement: what to sharpen, and the QP offset that sharpens it.
    quiet: Option<refine::Quiet>,
    refine_offset: i32,
    clock: std::time::Instant,
    /// Software: areas sent as tiles since the last picture. The shadow already holds
    /// them (it is what the client shows); the next picture must convert and code them.
    stale: Vec<Rect>,
    /// When recent updates came (ms on `clock`): a window that updates at animation rates
    /// gets pictures, which video coding makes far smaller than tiles.
    updates: std::collections::VecDeque<u64>,
}

// SAFETY: the libavcodec and libswscale contexts are owned exclusively by this value
// and are used from one thread at a time; libx264/libx265 contexts are not tied to the
// thread that created them.
unsafe impl Send for LavcEncoder {}

impl LavcEncoder {
    pub fn new(
        family: Family,
        codec: Codec,
        width: u32,
        height: u32,
        settings: &Settings,
    ) -> Result<Self, EncodeError> {
        if width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 {
            return Err(EncodeError(format!("{width}x{height} is not an even, non-empty size")));
        }
        let name = encoder_name(family, codec);
        let format = match family {
            Family::Software => Pixel::YUV420P,
            Family::Nvenc => Pixel::BGRZ,
        };
        let av = ff::encoder::find_by_name(name).ok_or_else(|| EncodeError(format!("libavcodec has no {name}")))?;
        let mut video = ff::codec::context::Context::new_with_codec(av).encoder().video()?;
        video.set_width(width);
        video.set_height(height);
        video.set_format(format);
        video.set_time_base(ff::Rational(1, 1_000_000));
        video.set_frame_rate(Some(ff::Rational(60, 1)));
        video.set_max_b_frames(0);
        video.set_colorspace(ff::color::Space::BT470BG);
        video.set_color_range(ff::color::Range::MPEG);
        unsafe {
            let ctx = video.as_mut_ptr();
            (*ctx).color_primaries = ff::ffi::AVColorPrimaries::AVCOL_PRI_BT709;
            (*ctx).color_trc = ff::ffi::AVColorTransferCharacteristic::AVCOL_TRC_IEC61966_2_1;
            // Keyframes only on request: a new client, request_keyframe, a resize.
            (*ctx).gop_size = -1;
        }
        let mut options = ff::Dictionary::new();
        options.set("forced-idr", "1");
        if family == Family::Nvenc {
            // P1 + ultra-low-latency tuning, no lookahead or B-frames, one frame in flight.
            options.set("preset", "p1");
            options.set("tune", "ull");
            options.set("zerolatency", "1");
            options.set("delay", "0");
            options.set("rc", "vbr");
            options.set("cq", &settings.crf.to_string());
            if codec == Codec::H264 {
                options.set("profile", "high");
            }
        }
        match (family, codec) {
            (Family::Nvenc, _) => {}
            (Family::Software, Codec::H264) => {
                options.set("tune", "zerolatency");
                // CRF with qcomp=1 codes every P picture at the CRF's QP: x264 skips a
                // macroblock hinted constant only when its reference was coded at no
                // higher a QP, which a floating per-frame QP keeps breaking. (Constant QP
                // would too, but it turns AQ off, which the refinement's per-macroblock QP
                // offsets need, and it skips the lowres pass whose motion vectors find a
                // scroll: 10× fewer bits for one at 1080p.) AQ at 1/100 of its usual
                // strength moves no macroblock's QP; it only lets the offsets through.
                options.set("crf", &settings.crf.to_string());
                options.set("preset", &settings.preset);
                options.set("profile", "high");
                options.set("threads", &settings.threads_for(width, height).to_string());
                // Keyframes only on request: a new client, request_keyframe, a resize.
                options.set(
                    "x264-params",
                    "keyint=infinite:scenecut=0:repeat-headers=1:aud=0:qcomp=1:aq-mode=1:aq-strength=0.01",
                );
                // Unchanged macroblocks are skipped from the damage hint (hint_changes).
                options.set("mb_info", "1");
            }
            (Family::Software, Codec::Hevc) => {
                options.set("tune", "zerolatency");
                options.set("crf", &settings.crf.to_string());
                options.set("preset", "ultrafast");
                // x265 pins its thread pool to NUMA nodes, which fails (noisily) inside
                // containers; one encoder thread needs no pool.
                let threads = settings.threads_for(width, height);
                let pools = if threads <= 1 { "none".to_owned() } else { threads.to_string() };
                options.set(
                    "x265-params",
                    &format!("keyint=-1:scenecut=0:repeat-headers=1:log-level=none:pools={pools}:frame-threads=1"),
                );
            }
            (_, Codec::Vp9) | (Family::Software, Codec::Av1) => {
                return Err(EncodeError(format!("{} is not offered for window streams", codec.as_str())))
            }
        }
        let encoder = video.open_with(options)?;
        let picture = ff::frame::Video::new(format, width, height);
        let refines = family == Family::Software
            && codec == Codec::H264
            && settings.refine_qp > 0
            && settings.refine_qp < settings.crf;
        Ok(Self {
            family,
            codec,
            encoder,
            picture,
            shadow: Vec::new(),
            excluded: None,
            masked: Vec::new(),
            width,
            height,
            pts: 0,
            quiet: refines.then(|| refine::Quiet::new(width, height, settings.refine_after_ms as u64)),
            refine_offset: settings.refine_qp as i32 - settings.crf as i32,
            clock: std::time::Instant::now(),
            stale: Vec::new(),
            updates: Default::default(),
        })
    }

    /// Brings the encoder's picture up to date with `src`: only the damaged rectangles,
    /// or all of it. Returns the macroblocks that really changed when that is known
    /// (software encoders with damage).
    fn convert(&mut self, src: &Pixels<'_>, damage: Option<&[Rect]>) -> Result<Option<Vec<Rect>>, EncodeError> {
        let row = self.width as usize * 4;
        let h = self.height as usize;
        if src.stride < row || src.data.len() < (h - 1) * src.stride + row {
            return Err(EncodeError("the input is smaller than the picture".into()));
        }
        // The encoder may still hold a reference to the last picture (it does not, for
        // libx264 and NVENC, which copy their input); if it is replaced, its old content
        // is gone and everything must be converted.
        let before = unsafe { (*self.picture.as_ptr()).buf[0] };
        unsafe {
            if ff::ffi::av_frame_make_writable(self.picture.as_mut_ptr()) < 0 {
                return Err(EncodeError("could not make the picture writable".into()));
            }
        }
        let damage = if unsafe { (*self.picture.as_ptr()).buf[0] } == before { damage } else { None };
        match self.family {
            Family::Nvenc => {
                let stride = self.picture.stride(0);
                let full = [Rect::new(0, 0, self.width as i32, self.height as i32)];
                let dst = self.picture.data_mut(0);
                for r in damage.unwrap_or(&full) {
                    let Some((x0, y0, x1, y1)) = convert::even_clip(*r, self.width, self.height) else { continue };
                    for y in y0..y1 {
                        dst[y * stride + x0 * 4..y * stride + x1 * 4]
                            .copy_from_slice(&src.data[y * src.stride + x0 * 4..y * src.stride + x1 * 4]);
                    }
                }
                Ok(None)
            }
            Family::Software => {
                let (ys, us, vs) = (self.picture.stride(0), self.picture.stride(1), self.picture.stride(2));
                // SAFETY: the three planes are distinct allocations of at least
                // `stride × rows` bytes each, as av_frame_get_buffer made them.
                let (y, u, v) = unsafe {
                    let f = self.picture.as_mut_ptr();
                    (
                        std::slice::from_raw_parts_mut((*f).data[0], ys * h),
                        std::slice::from_raw_parts_mut((*f).data[1], us * h / 2),
                        std::slice::from_raw_parts_mut((*f).data[2], vs * h / 2),
                    )
                };
                let planes = convert::I420 { y, y_stride: ys, u, u_stride: us, v, v_stride: vs };
                let damage = damage.filter(|_| self.shadow.len() == row * h);
                Ok(match damage {
                    Some(d) => {
                        let mut changed = convert::changed_blocks(
                            src.data,
                            src.stride,
                            &mut self.shadow,
                            row,
                            self.width,
                            self.height,
                            d,
                        );
                        changed.append(&mut self.stale);
                        convert::bgrx_to_i420(src.data, src.stride, self.width, self.height, Some(&changed), planes);
                        Some(changed)
                    }
                    None => {
                        self.stale.clear();
                        convert::bgrx_to_i420(src.data, src.stride, self.width, self.height, None, planes);
                        self.shadow.clear();
                        for r in 0..h {
                            self.shadow.extend_from_slice(&src.data[r * src.stride..r * src.stride + row]);
                        }
                        None
                    }
                })
            }
        }
    }

    /// Converts the areas sent as tiles since the last picture from the shadow (what the
    /// client shows) into the picture, and returns them.
    fn convert_stale(&mut self) -> Result<Vec<Rect>, EncodeError> {
        let mut stale = std::mem::take(&mut self.stale);
        if stale.is_empty() {
            return Ok(stale);
        }
        let row = self.width as usize * 4;
        let h = self.height as usize;
        let before = unsafe { (*self.picture.as_ptr()).buf[0] };
        unsafe {
            if ff::ffi::av_frame_make_writable(self.picture.as_mut_ptr()) < 0 {
                return Err(EncodeError("could not make the picture writable".into()));
            }
        }
        let replaced = unsafe { (*self.picture.as_ptr()).buf[0] } != before;
        let (ys, us, vs) = (self.picture.stride(0), self.picture.stride(1), self.picture.stride(2));
        // SAFETY: as in `convert`; the shadow is a separate allocation of `row × h` bytes.
        let (y, u, v) = unsafe {
            let f = self.picture.as_mut_ptr();
            (
                std::slice::from_raw_parts_mut((*f).data[0], ys * h),
                std::slice::from_raw_parts_mut((*f).data[1], us * h / 2),
                std::slice::from_raw_parts_mut((*f).data[2], vs * h / 2),
            )
        };
        let planes = convert::I420 { y, y_stride: ys, u, u_stride: us, v, v_stride: vs };
        if replaced {
            // The picture lost its content: all of it comes from the shadow.
            stale = vec![Rect::new(0, 0, self.width as i32, self.height as i32)];
        }
        convert::bgrx_to_i420(&self.shadow, row, self.width, self.height, Some(&stale), planes);
        Ok(stale)
    }

    /// Runs `f` on the input's pixels at the picture's top-left: an image, part of one,
    /// or a client's shm buffer read in place.
    fn with_pixels<R>(
        &mut self,
        input: Input<'_>,
        f: impl FnOnce(&mut Self, &Pixels<'_>) -> Result<R, EncodeError>,
    ) -> Result<R, EncodeError> {
        match input {
            Input::Cpu(image) => {
                if image.width != self.width || image.height != self.height {
                    return Err(EncodeError(format!(
                        "input {}x{} does not match the encoder's {}x{}",
                        image.width, image.height, self.width, self.height
                    )));
                }
                self.with_visible_pixels(&Pixels { data: &image.data, stride: image.stride }, f)
            }
            Input::CpuAt(image, x, y) => {
                if x + self.width > image.width || y + self.height > image.height {
                    return Err(EncodeError(format!(
                        "{}x{} at ({x}, {y}) is outside the {}x{} input",
                        self.width, self.height, image.width, image.height
                    )));
                }
                let start = y as usize * image.stride + x as usize * 4;
                self.with_visible_pixels(&Pixels { data: &image.data[start..], stride: image.stride }, f)
            }
            Input::Shm(p) => {
                let read = smithay::wayland::shm::with_buffer_contents(&p.buffer, |ptr, len, data| {
                    let (w, h) = (self.width as i32, self.height as i32);
                    if p.x < 0 || p.y < 0 || p.x + w > data.width || p.y + h > data.height {
                        return Err(EncodeError("the picture is outside the buffer".into()));
                    }
                    let start = data.offset as usize + p.y as usize * data.stride as usize + p.x as usize * 4;
                    if start > len {
                        return Err(EncodeError("the buffer is outside its pool".into()));
                    }
                    // SAFETY: with_buffer_contents maps `len` bytes of the pool at `ptr`
                    // for this closure and turns a truncated pool into an error.
                    let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
                    self.with_visible_pixels(&Pixels { data: &pool[start..], stride: data.stride as usize }, f)
                });
                read.map_err(|e| EncodeError(format!("shm buffer: {e:?}")))?
            }
        }
    }

    /// Exclusion is an input invariant, not a damage hint: neither a full convert
    /// nor tile comparison can see newer pixels beneath the video layer.
    fn with_visible_pixels<R>(
        &mut self,
        src: &Pixels<'_>,
        f: impl FnOnce(&mut Self, &Pixels<'_>) -> Result<R, EncodeError>,
    ) -> Result<R, EncodeError> {
        let Some((rect, frozen)) = &self.excluded else { return f(self, src) };
        let row = self.width as usize * 4;
        let height = self.height as usize;
        if src.stride < row || src.data.len() < (height - 1) * src.stride + row {
            return Err(EncodeError("the input is smaller than the picture".into()));
        }
        let mut masked = std::mem::take(&mut self.masked);
        masked.resize(row * height, 0);
        for y in 0..height {
            masked[y * row..(y + 1) * row].copy_from_slice(&src.data[y * src.stride..][..row]);
        }
        let frozen_row = rect.w as usize * 4;
        for y in 0..rect.h as usize {
            let start = (rect.y as usize + y) * row + rect.x as usize * 4;
            masked[start..start + frozen_row].copy_from_slice(&frozen[y * frozen_row..][..frozen_row]);
        }
        let result = f(self, &Pixels { data: &masked, stride: row });
        self.masked = masked;
        result
    }

    /// The changed blocks of `damage` as tiles, if they are few and small enough;
    /// otherwise nothing is taken and the caller encodes a picture.
    fn take_tiles(&mut self, src: &Pixels<'_>, damage: &[Rect], max_px: u64) -> Result<Option<Tiles>, EncodeError> {
        let row = self.width as usize * 4;
        if self.family != Family::Software || self.shadow.len() != row * self.height as usize {
            return Ok(None);
        }
        let now = self.now_ms();
        while self.updates.front().is_some_and(|t| now >= t + TILE_WINDOW_MS) {
            self.updates.pop_front();
        }
        self.updates.push_back(now);
        if self.updates.len() > MAX_TILE_UPDATES {
            return Ok(None);
        }
        if src.stride < row || src.data.len() < (self.height as usize - 1) * src.stride + row {
            return Err(EncodeError("the input is smaller than the picture".into()));
        }
        let changed =
            convert::changed_blocks(src.data, src.stride, &mut self.shadow, row, self.width, self.height, damage);
        let area: u64 = changed.iter().map(|r| r.w as u64 * r.h as u64).sum();
        // The shadow now holds these blocks either way, so the next picture codes them.
        self.stale.extend_from_slice(&changed);
        if area > max_px || changed.len() > MAX_TILES {
            return Ok(None);
        }
        let tiles = merge_columns(&changed).iter().map(|r| (*r, rgb(src, *r))).collect();
        Ok(Some(Tiles { tiles, refine_in_ms: self.quiet.as_ref().and_then(|q| q.next_due_ms(now)) }))
    }

    /// The input as a copy of what the client shows plus tiles, if it is a scroll of it;
    /// otherwise nothing is taken (the shadow is untouched) and the caller goes on as usual.
    fn take_copy(
        &mut self,
        src: &Pixels<'_>,
        damage: &[Rect],
        hints: &[(i32, i32)],
    ) -> Result<Option<Copied>, EncodeError> {
        let row = self.width as usize * 4;
        let h = self.height as usize;
        // The shadow is what the client shows. Under a motion stream it holds frozen
        // pixels the client does not show, so nothing is copied then.
        if self.family != Family::Software || self.shadow.len() != row * h || self.excluded.is_some() {
            return Ok(None);
        }
        if src.stride < row || src.data.len() < (h - 1) * src.stride + row {
            return Err(EncodeError("the input is smaller than the picture".into()));
        }
        let shown = scroll::Plane { data: &self.shadow, stride: row };
        let new = scroll::Plane { data: src.data, stride: src.stride };
        let Some(plan) = scroll::plan(shown, new, self.width, self.height, damage, hints) else { return Ok(None) };
        let tiles = plan.tiles.iter().map(|r| (*r, rgb(src, *r))).collect();
        // After the copy and the tiles the client shows the input: everywhere they change
        // (`stale`) the shadow takes it, and the next picture codes it.
        for r in &plan.stale {
            for y in r.y as usize..(r.y + r.h) as usize {
                let (x0, x1) = (r.x as usize * 4, (r.x + r.w) as usize * 4);
                self.shadow[y * row + x0..y * row + x1]
                    .copy_from_slice(&src.data[y * src.stride + x0..y * src.stride + x1]);
            }
        }
        // A scroll copies much the same area time after time; it is coded once.
        let within = |a: &Rect, b: &Rect| a.x <= b.x && a.y <= b.y && a.x + a.w >= b.x + b.w && a.y + a.h >= b.y + b.h;
        for r in &plan.stale {
            if !self.stale.iter().any(|s| within(s, r)) {
                self.stale.retain(|s| !within(r, s));
                self.stale.push(*r);
            }
        }
        Ok(Some(Copied {
            src: plan.src,
            dst: [plan.dst.0, plan.dst.1],
            tiles,
            refine_in_ms: self.quiet.as_ref().and_then(|q| q.next_due_ms(self.now_ms())),
            changed: plan.stale,
        }))
    }

    /// Tells libx264 which macroblocks changed, so it skips analysing the rest.
    fn hint_changes(&mut self, damage: &[Rect]) {
        #[repr(C)]
        struct AVVideoRect {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        }
        #[repr(C)]
        struct AVVideoHint {
            nb_rects: usize,
            rect_offset: usize,
            rect_size: usize,
            kind: libc::c_int,
        }
        extern "C" {
            fn av_video_hint_create_side_data(frame: *mut ff::ffi::AVFrame, nb_rects: usize) -> *mut AVVideoHint;
        }
        const AV_VIDEO_HINT_TYPE_CHANGED: libc::c_int = 1;
        let rects: Vec<_> = damage.iter().filter_map(|r| convert::even_clip(*r, self.width, self.height)).collect();
        // SAFETY: libavutil allocates the hint with room for `rects.len()` rectangles at
        // `rect_offset`, `rect_size` apart, and attaches it to the frame, which frees it.
        unsafe {
            let hint = av_video_hint_create_side_data(self.picture.as_mut_ptr(), rects.len());
            if hint.is_null() {
                return;
            }
            (*hint).kind = AV_VIDEO_HINT_TYPE_CHANGED;
            for (i, (x0, y0, x1, y1)) in rects.into_iter().enumerate() {
                let r = (hint as *mut u8).add((*hint).rect_offset + i * (*hint).rect_size) as *mut AVVideoRect;
                *r = AVVideoRect { x: x0 as u32, y: y0 as u32, width: (x1 - x0) as u32, height: (y1 - y0) as u32 };
            }
        }
    }

    /// Codes `regions` at the refinement QP (libx264 turns the offset into per-macroblock
    /// quant offsets).
    fn sharpen(&mut self, regions: &[Rect]) {
        if regions.is_empty() {
            return;
        }
        let size = std::mem::size_of::<ff::ffi::AVRegionOfInterest>();
        // SAFETY: the side data is allocated with room for `regions.len()` entries, and
        // the frame owns (and frees) it.
        unsafe {
            let sd = ff::ffi::av_frame_new_side_data(
                self.picture.as_mut_ptr(),
                ff::ffi::AVFrameSideDataType::AV_FRAME_DATA_REGIONS_OF_INTEREST,
                size * regions.len(),
            );
            if sd.is_null() {
                return;
            }
            let rois = (*sd).data as *mut ff::ffi::AVRegionOfInterest;
            for (i, r) in regions.iter().enumerate() {
                *rois.add(i) = ff::ffi::AVRegionOfInterest {
                    self_size: size as u32,
                    top: r.y,
                    bottom: r.y + r.h,
                    left: r.x,
                    right: r.x + r.w,
                    // In units of the QP range, which libx264 takes as 0..51 at 8 bits.
                    qoffset: ff::ffi::AVRational { num: self.refine_offset, den: 51 },
                };
            }
        }
    }

    fn clear_side_data(&mut self) {
        use ff::ffi::AVFrameSideDataType::{AV_FRAME_DATA_REGIONS_OF_INTEREST, AV_FRAME_DATA_VIDEO_HINT};
        // SAFETY: removing side data the frame may or may not carry.
        unsafe {
            ff::ffi::av_frame_remove_side_data(self.picture.as_mut_ptr(), AV_FRAME_DATA_VIDEO_HINT);
            ff::ffi::av_frame_remove_side_data(self.picture.as_mut_ptr(), AV_FRAME_DATA_REGIONS_OF_INTEREST);
        }
    }

    fn now_ms(&self) -> u64 {
        self.clock.elapsed().as_millis() as u64
    }

    /// Sends the picture as it stands (with whatever side data it carries) and collects
    /// the encoded picture.
    fn send(&mut self, keyframe: bool) -> Result<Picture, EncodeError> {
        self.picture.set_pts(Some(self.pts));
        self.pts += 1;
        self.picture.set_kind(if keyframe { ff::picture::Type::I } else { ff::picture::Type::None });
        self.encoder.send_frame(&self.picture)?;
        self.clear_side_data();
        let mut data = Vec::new();
        let mut key = false;
        let mut packet = ff::Packet::empty();
        loop {
            match self.encoder.receive_packet(&mut packet) {
                Ok(()) => {
                    key |= packet.is_key();
                    data.extend_from_slice(packet.data().unwrap_or_default());
                }
                Err(ff::Error::Other { errno: libc::EAGAIN }) => break,
                Err(e) => return Err(e.into()),
            }
        }
        if data.is_empty() {
            return Err(EncodeError(format!("{} produced no picture", self.name())));
        }
        let now = self.now_ms();
        Ok(Picture {
            data,
            keyframe: key,
            refine_in_ms: self.quiet.as_ref().and_then(|q| q.next_due_ms(now)),
            changed: None,
        })
    }
}

impl Encoder for LavcEncoder {
    fn exclude(&mut self, region: Option<Rect>) {
        let region = region
            .and_then(|r| convert::even_clip(r, self.width, self.height))
            .map(|(x0, y0, x1, y1)| Rect::new(x0 as i32, y0 as i32, (x1 - x0) as i32, (y1 - y0) as i32));
        if self.excluded.as_ref().map(|(r, _)| *r) == region {
            return;
        }
        self.excluded = region.map(|rect| {
            let row = rect.w as usize * 4;
            let mut frozen = vec![0; row * rect.h as usize];
            let source = match self.family {
                Family::Software if self.shadow.len() == self.width as usize * self.height as usize * 4 => {
                    Some((self.shadow.as_slice(), self.width as usize * 4))
                }
                Family::Nvenc if self.pts > 0 => Some((self.picture.data(0), self.picture.stride(0))),
                _ => None,
            };
            if let Some((pixels, stride)) = source {
                for y in 0..rect.h as usize {
                    let start = (rect.y as usize + y) * stride + rect.x as usize * 4;
                    frozen[y * row..][..row].copy_from_slice(&pixels[start..][..row]);
                }
            }
            (rect, frozen)
        });
        if self.excluded.is_none() {
            self.masked.clear();
        }
    }

    fn codec(&self) -> Codec {
        self.codec
    }

    fn name(&self) -> &'static str {
        encoder_name(self.family, self.codec)
    }

    fn coded_size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    fn encode(&mut self, input: Input<'_>, keyframe: bool, damage: Option<&[Rect]>) -> Result<Picture, EncodeError> {
        let damage = if keyframe { None } else { damage };
        let t0 = std::time::Instant::now();
        let changed = self.with_pixels(input, |enc, pixels| enc.convert(pixels, damage))?;
        let convert_us = t0.elapsed().as_micros();
        self.clear_side_data();
        // Areas quiet for long enough are sharpened in this picture, which goes out anyway.
        let now = self.now_ms();
        let due = match (self.quiet.as_mut(), &changed) {
            (None, _) => Vec::new(),
            (Some(q), Some(changed)) if !keyframe => {
                q.changed(changed, now);
                q.take_due(now)
            }
            (Some(q), _) => {
                q.all_changed(now);
                Vec::new()
            }
        };
        if let (Some(changed), Codec::H264) = (&changed, self.codec) {
            tracing::trace!(
                "{} of {} macroblock rows-runs changed, {} px; sharpening {} px",
                changed.len(),
                self.height.div_ceil(16),
                changed.iter().map(|r| (r.w * r.h) as u64).sum::<u64>(),
                due.iter().map(|r| (r.w * r.h) as u64).sum::<u64>()
            );
            let hinted: Vec<Rect> = changed.iter().chain(&due).copied().collect();
            self.hint_changes(&hinted);
        }
        self.sharpen(&due);
        let mut picture = self.send(keyframe)?;
        tracing::trace!("convert {convert_us} µs, encode {} µs", t0.elapsed().as_micros() - convert_us);
        picture.changed = changed;
        Ok(picture)
    }

    fn tiles(&mut self, input: Input<'_>, damage: &[Rect], max_px: u64) -> Result<Option<Tiles>, EncodeError> {
        self.with_pixels(input, |enc, pixels| enc.take_tiles(pixels, damage, max_px))
    }

    fn copy(&mut self, input: Input<'_>, damage: &[Rect], hints: &[(i32, i32)]) -> Result<Option<Copied>, EncodeError> {
        self.with_pixels(input, |enc, pixels| enc.take_copy(pixels, damage, hints))
    }

    fn refine(&mut self) -> Result<Picture, EncodeError> {
        if self.quiet.is_none() {
            return Err(EncodeError(format!("{} does not refine", self.name())));
        }
        // The client shows tiles newer than the picture, losslessly; this picture
        // repaints them, so it carries them, as sharp as the rest it sharpens.
        let stale = self.convert_stale()?;
        let now = self.now_ms();
        let mut sharp = self.quiet.as_mut().unwrap().take_due(now);
        sharp.extend_from_slice(&stale);
        tracing::trace!("sharpening {} px", sharp.iter().map(|r| (r.w * r.h) as u64).sum::<u64>());
        self.clear_side_data();
        // Everything else is hinted constant: skipped, at no cost.
        self.hint_changes(&sharp);
        self.sharpen(&sharp);
        self.send(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gradient(width: u32, height: u32, shift: u32) -> CpuImage {
        let mut image = CpuImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let i = y as usize * image.stride + x as usize * 4;
                image.data[i] = ((x + shift) * 4) as u8;
                image.data[i + 1] = (y * 4) as u8;
                image.data[i + 2] = 128;
            }
        }
        image
    }

    fn nal_types(codec: Codec, data: &[u8]) -> Vec<u8> {
        let mut types = Vec::new();
        let mut i = 0;
        while i + 3 < data.len() {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                let header = data[i + 3];
                types.push(match codec {
                    Codec::Hevc => (header >> 1) & 0x3f,
                    _ => header & 0x1f,
                });
                i += 3;
            } else {
                i += 1;
            }
        }
        types
    }

    #[test]
    fn h264_keyframes_carry_parameter_sets_and_deltas_do_not() {
        ff::init().unwrap();
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 128, 96, &Settings::default()).unwrap();
        let first = enc.encode(Input::Cpu(&gradient(128, 96, 0)), true, None).unwrap();
        assert!(first.keyframe);
        let types = nal_types(Codec::H264, &first.data);
        assert!(types.contains(&7) && types.contains(&8) && types.contains(&5), "{types:?}");
        let second = enc.encode(Input::Cpu(&gradient(128, 96, 3)), false, None).unwrap();
        assert!(!second.keyframe);
        assert!(!nal_types(Codec::H264, &second.data).contains(&7));
        let forced = enc.encode(Input::Cpu(&gradient(128, 96, 6)), true, None).unwrap();
        assert!(forced.keyframe);
        assert!(nal_types(Codec::H264, &forced.data).contains(&5));
    }

    #[test]
    fn hevc_keyframes_carry_vps_sps_pps() {
        ff::init().unwrap();
        let mut enc = LavcEncoder::new(Family::Software, Codec::Hevc, 64, 64, &Settings::default()).unwrap();
        let first = enc.encode(Input::Cpu(&gradient(64, 64, 0)), true, None).unwrap();
        assert!(first.keyframe);
        let types = nal_types(Codec::Hevc, &first.data);
        assert!(types.contains(&32) && types.contains(&33) && types.contains(&34), "{types:?}");
        let second = enc.encode(Input::Cpu(&gradient(64, 64, 2)), false, None).unwrap();
        assert!(!second.keyframe);
    }

    #[test]
    fn runs_in_the_same_columns_join() {
        let runs =
            [Rect::new(16, 0, 32, 16), Rect::new(16, 16, 32, 16), Rect::new(0, 16, 16, 16), Rect::new(16, 48, 32, 16)];
        assert_eq!(
            merge_columns(&runs),
            [Rect::new(16, 0, 32, 32), Rect::new(0, 16, 16, 16), Rect::new(16, 48, 32, 16)]
        );
    }

    #[test]
    fn small_changes_become_tiles_and_the_next_picture_carries_them() {
        ff::init().unwrap();
        let settings = Settings { threads: 1, refine_qp: 0, ..Settings::default() };
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 128, 64, &settings).unwrap();
        let mut image = gradient(128, 64, 0);
        enc.encode(Input::Cpu(&image), true, None).unwrap();
        // A glyph: 10x20 pixels changed.
        for y in 20..40 {
            image.data[y * image.stride + 40 * 4..][..40].fill(0xff);
        }
        let damage = [Rect::new(32, 16, 32, 32)];
        let t = enc.tiles(Input::Cpu(&image), &damage, 65536).unwrap().unwrap();
        assert_eq!(t.tiles.len(), 1, "one tile for the glyph's column");
        let (r, rgb) = &t.tiles[0];
        // x 40..50 crosses from one macroblock column into the next.
        assert_eq!((r.x, r.y, r.w, r.h), (32, 16, 32, 32));
        assert_eq!(rgb.len(), 32 * 32 * 3);
        assert_eq!(&rgb[(4 * 32 + 8) * 3..][..3], &[0xff, 0xff, 0xff]);
        // Nothing new changed, but the next picture codes the tiled blocks.
        let p = enc.encode(Input::Cpu(&image), false, Some(&[])).unwrap();
        assert_eq!(p.changed.unwrap(), vec![Rect::new(32, 16, 32, 16), Rect::new(32, 32, 32, 16)]);
        // An animation (many updates in quick succession) gets pictures.
        let mut tiled = 0;
        for i in 0..12u8 {
            image.data[30 * image.stride + 40 * 4] = i;
            if enc.tiles(Input::Cpu(&image), &damage, 65536).unwrap().is_some() {
                tiled += 1;
            } else {
                enc.encode(Input::Cpu(&image), false, Some(&damage)).unwrap();
            }
        }
        assert!(tiled < 7, "{tiled} of 12 quick updates went as tiles");
        // A change too big for tiles is left to a picture.
        assert!(enc.tiles(Input::Cpu(&gradient(128, 64, 9)), &[Rect::new(0, 0, 128, 64)], 1024).unwrap().is_none());
    }

    #[test]
    fn a_scroll_becomes_a_copy_that_the_next_picture_carries() {
        ff::init().unwrap();
        let settings = Settings { threads: 1, refine_qp: 0, ..Settings::default() };
        let (w, h) = (256u32, 512u32);
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, w, h, &settings).unwrap();
        let image = text(w, h);
        enc.encode(Input::Cpu(&image), true, None).unwrap();
        // Scrolled down by 18 rows; the rows that come into view are new content.
        let mut scrolled = CpuImage::new(w, h);
        scrolled.data.copy_from_slice(&image.data);
        scrolled.data.rotate_left(scrolled.stride * 18);
        let all = [Rect::new(0, 0, w as i32, h as i32)];
        let copy = enc.copy(Input::Cpu(&scrolled), &all, &[(0, -18)]).unwrap().expect("a copy");
        assert_eq!((copy.src, copy.dst), (Rect::new(0, 18, w as i32, h as i32 - 18), [0, 0]));
        // What the client shows after the copy and its tiles is the scrolled picture, byte
        // for byte (B, G, R).
        let mut shown = image.data.clone();
        let (src, dst, stride) = (copy.src, copy.dst, image.stride);
        for y in 0..src.h as usize {
            let (from, to) = (
                (src.y as usize + y) * stride + src.x as usize * 4,
                (dst[1] as usize + y) * stride + dst[0] as usize * 4,
            );
            shown[to..to + src.w as usize * 4].copy_from_slice(&image.data[from..from + src.w as usize * 4]);
        }
        for (r, rgb) in &copy.tiles {
            for (i, px) in rgb.chunks_exact(3).enumerate() {
                let (x, y) = (r.x as usize + i % r.w as usize, r.y as usize + i / r.w as usize);
                shown[y * stride + x * 4..][..3].copy_from_slice(&[px[2], px[1], px[0]]);
            }
        }
        for (a, b) in shown.chunks_exact(4).zip(scrolled.data.chunks_exact(4)) {
            assert_eq!(a[..3], b[..3]);
        }
        // The encoder's record of what the client shows is the scrolled picture, and the
        // next picture codes the copied area.
        assert!(enc.shadow == scrolled.data);
        let next = enc.encode(Input::Cpu(&scrolled), false, Some(&[])).unwrap();
        assert!(next.changed.unwrap().contains(&Rect::new(0, 0, w as i32, 496)));
        // Under a motion stream the shadow holds frozen pixels: no copies.
        enc.exclude(Some(Rect::new(32, 32, 64, 64)));
        assert!(enc.copy(Input::Cpu(&image), &all, &[(0, 18)]).unwrap().is_none());
    }

    #[test]
    fn odd_sizes_are_rejected() {
        assert!(LavcEncoder::new(Family::Software, Codec::H264, 99, 64, &Settings::default()).is_err());
    }

    /// Dark strokes on white, like text.
    fn text(width: u32, height: u32) -> CpuImage {
        let mut image = CpuImage::new(width, height);
        for y in 0..height as usize {
            for x in 0..width as usize {
                let ink = (x % 9 < 2 && y % 18 < 12) || (y % 18 == 5 && x % 9 < 6) || (x * 7 + y * 13) % 97 < 3;
                let v = if ink { 0x20 } else { 0xf4 };
                image.data[y * image.stride + x * 4..][..4].copy_from_slice(&[v, v, v, 0]);
            }
        }
        image
    }

    /// Decodes pictures in order and measures them against the encoder's input.
    struct Decoder(ff::decoder::Video);

    impl Decoder {
        fn new() -> Self {
            let codec = ff::decoder::find(ff::codec::Id::H264).unwrap();
            Self(ff::codec::context::Context::new_with_codec(codec).decoder().video().unwrap())
        }

        /// Luma PSNR of `picture`, decoded, against what `enc` was given.
        fn psnr(&mut self, picture: &Picture, enc: &LavcEncoder) -> f64 {
            self.0.send_packet(&ff::Packet::copy(&picture.data)).unwrap();
            let mut out = ff::frame::Video::empty();
            self.0.receive_frame(&mut out).unwrap();
            let src = &enc.picture;
            let (w, h) = (enc.width as usize, enc.height as usize);
            let mut se = 0.0;
            for y in 0..h {
                let a = &src.data(0)[y * src.stride(0)..][..w];
                let b = &out.data(0)[y * out.stride(0)..][..w];
                se += a.iter().zip(b).map(|(&a, &b)| (a as f64 - b as f64).powi(2)).sum::<f64>();
            }
            10.0 * (255.0f64.powi(2) / (se / (w * h) as f64).max(1e-9)).log10()
        }
    }

    #[test]
    fn excluded_motion_pixels_survive_keyframes_tiles_and_refinement() {
        ff::init().unwrap();
        let settings = Settings { threads: 1, refine_after_ms: 0, ..Settings::default() };
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 128, 96, &settings).unwrap();
        let mut decoder = Decoder::new();
        let mut image = CpuImage::new(128, 96);
        image.data.fill(40);
        let first = enc.encode(Input::Cpu(&image), true, None).unwrap();
        decoder.psnr(&first, &enc);
        let region = Rect::new(32, 16, 64, 64);
        enc.exclude(Some(region));
        image.data.fill(240);
        let mut assert_frozen = |picture: Picture, enc: &LavcEncoder| {
            decoder.0.send_packet(&ff::Packet::copy(&picture.data)).unwrap();
            let mut decoded = ff::frame::Video::empty();
            decoder.0.receive_frame(&mut decoded).unwrap();
            // Check the encoder's picture and its decoded output, not only the
            // masked RGB scratch buffer. The original ROI is dark, the live one white.
            let y = enc.picture.data(0)[40 * enc.picture.stride(0) + 48];
            assert!(y < 80, "motion leaked into the base: luma {y}");
            let decoded_y = decoded.data(0)[40 * decoded.stride(0) + 48];
            assert!(decoded_y < 80, "motion leaked into the decoded base: luma {decoded_y}");
        };
        let key = enc.encode(Input::Cpu(&image), true, None).unwrap();
        assert!(key.keyframe);
        assert_frozen(key, &enc);
        // Full damage and tile comparison must also use the frozen source.
        let tiles = enc.tiles(Input::Cpu(&image), &[region], 65536).unwrap().unwrap();
        assert!(tiles.tiles.is_empty());
        let delta = enc.encode(Input::Cpu(&image), false, None).unwrap();
        assert_frozen(delta, &enc);
        let sharp = enc.refine().unwrap();
        assert_frozen(sharp, &enc);
        assert!(image.data.iter().all(|p| *p == 240), "mask changed the motion source");
        enc.exclude(None);
        enc.encode(Input::Cpu(&image), false, Some(&[region])).unwrap();
        assert!(enc.picture.data(0)[40 * enc.picture.stride(0) + 48] > 200, "retirement did not repaint");
    }

    #[test]
    fn quiet_pictures_are_sharpened_once_and_stay_sharp() {
        ff::init().unwrap();
        let settings = Settings { threads: 1, refine_after_ms: 0, ..Settings::default() };
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 256, 128, &settings).unwrap();
        let mut dec = Decoder::new();
        let mut image = text(256, 128);
        let key = enc.encode(Input::Cpu(&image), true, None).unwrap();
        assert_eq!(key.refine_in_ms, Some(0));
        let soft = dec.psnr(&key, &enc);
        let sharp = enc.refine().unwrap();
        assert!(!sharp.keyframe && sharp.refine_in_ms.is_none());
        let refined = dec.psnr(&sharp, &enc);
        assert!(refined > soft + 4.0, "refinement took {soft:.1} dB to {refined:.1} dB");
        // An update elsewhere keeps the sharpened pixels.
        for y in 40..56 {
            image.data[y * image.stride + 64 * 4..][..64].fill(0x80);
        }
        let update = enc.encode(Input::Cpu(&image), false, Some(&[Rect::new(64, 40, 16, 16)])).unwrap();
        assert!(dec.psnr(&update, &enc) > refined - 1.0);
        // Nothing changed and nothing left to sharpen: an empty picture.
        let idle = enc.encode(Input::Cpu(&image), false, Some(&[])).unwrap();
        assert!(idle.data.len() < 64 && idle.refine_in_ms.is_none());
    }

    #[test]
    fn refinement_waits_for_quiet_and_can_be_turned_off() {
        ff::init().unwrap();
        let image = text(64, 64);
        let settings = Settings { threads: 1, refine_after_ms: 300, ..Settings::default() };
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 64, 64, &settings).unwrap();
        let key = enc.encode(Input::Cpu(&image), true, None).unwrap();
        assert!(key.refine_in_ms.is_some_and(|ms| ms > 200 && ms <= 300));
        let off = Settings { threads: 1, refine_qp: 0, ..Settings::default() };
        let mut enc = LavcEncoder::new(Family::Software, Codec::H264, 64, 64, &off).unwrap();
        assert!(enc.encode(Input::Cpu(&image), true, None).unwrap().refine_in_ms.is_none());
        assert!(enc.refine().is_err());
        let mut hevc = LavcEncoder::new(Family::Software, Codec::Hevc, 64, 64, &settings).unwrap();
        assert!(hevc.encode(Input::Cpu(&image), true, None).unwrap().refine_in_ms.is_none());
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    /// `cargo test -p caboose-display bench_ -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn bench_720p_ui_update() {
        ff::init().unwrap();
        let (w, h) = (1280u32, 720u32);
        for (label, damaged) in [("whole picture", false), ("damage only", true)] {
            let settings = Settings { threads: 1, ..Settings::default() };
            let mut enc = LavcEncoder::new(Family::Software, Codec::H264, w, h, &settings).unwrap();
            let mut image = CpuImage::new(w, h);
            image.data.iter_mut().for_each(|b| *b = 0x20);
            let frames = 120;
            let start = std::time::Instant::now();
            let mut bytes = 0;
            let mut last_x = 0;
            for i in 0..frames {
                // A 120x120 block moving across a static background.
                let x0 = (i * 8) % (w as usize - 120);
                for y in 300..420 {
                    let row = y * image.stride;
                    image.data[row..row + image.stride].iter_mut().for_each(|b| *b = 0x20);
                    image.data[row + x0 * 4..row + (x0 + 120) * 4].iter_mut().for_each(|b| *b = 0xc0);
                }
                let lo = x0.min(last_x) as i32;
                let hi = (x0.max(last_x) + 120) as i32;
                let rects = [Rect::new(lo, 300, hi - lo, 120)];
                last_x = x0;
                let p = enc.encode(Input::Cpu(&image), i == 0, damaged.then_some(&rects[..])).unwrap();
                bytes += p.data.len();
            }
            let total = start.elapsed();
            println!(
                "720p moving block, {label}: {:.2} ms/frame, {} bytes/frame",
                total.as_secs_f64() * 1000.0 / frames as f64,
                bytes / frames
            );
        }
    }

    /// Typing one glyph, then scrolling by a line, on a picture of synthetic text, without
    /// sharpening (which would fold the keyframe's into one of the typed pictures).
    /// `cargo test -p caboose-display bench_ -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn bench_text_typing_and_scrolling() {
        ff::init().unwrap();
        for (w, h) in [(1920u32, 1080u32), (1280, 720), (1180, 2556), (3840, 2160)] {
            let settings = Settings { threads: 1, refine_qp: 0, ..Settings::default() };
            let mut enc = LavcEncoder::new(Family::Software, Codec::H264, w, h, &settings).unwrap();
            let mut image = CpuImage::new(w, h);
            for y in 0..h as usize {
                for x in 0..w as usize {
                    let ink = (x % 9 < 2 && y % 18 < 12) || (y % 18 == 5 && x % 9 < 6) || (x * 7 + y * 13) % 97 < 3;
                    let v = if ink { 0x20 } else { 0xf4 };
                    image.data[y * image.stride + x * 4..][..4].copy_from_slice(&[v, v, v, 0]);
                }
            }
            enc.encode(Input::Cpu(&image), true, None).unwrap();
            let (mut typing, mut typed) = (std::time::Duration::ZERO, 0);
            for i in 0..100 {
                let (x0, y0) = (64 + i * 16, 200);
                for y in y0..y0 + 16 {
                    image.data[y * image.stride + x0 * 4..][..40].fill(0x30);
                }
                let t = std::time::Instant::now();
                typed += enc
                    .encode(Input::Cpu(&image), false, Some(&[Rect::new(x0 as i32, y0 as i32, 16, 16)]))
                    .unwrap()
                    .data
                    .len();
                typing += t.elapsed();
            }
            let (mut scrolling, mut scrolled) = (std::time::Duration::ZERO, 0);
            let all = [Rect::new(0, 0, w as i32, h as i32)];
            for _ in 0..20 {
                image.data.rotate_left(image.stride * 18);
                let t = std::time::Instant::now();
                scrolled += enc.encode(Input::Cpu(&image), false, Some(&all)).unwrap().data.len();
                scrolling += t.elapsed();
            }
            println!(
                "{w}x{h} text: typing {:.2} ms, {} B per glyph; scrolling a line {:.2} ms, {} kB per picture",
                typing.as_secs_f64() * 10.0,
                typed / 100,
                scrolling.as_secs_f64() * 50.0,
                scrolled / 20 / 1000
            );
        }
    }
}
