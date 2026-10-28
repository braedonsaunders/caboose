//! Encoders through libavcodec that take pixels in system memory (wl_shm buffers, or GPU
//! buffers read back):
//!
//! - software: libx264 (H.264) and libx265 (HEVC), after a BGRX → I420 conversion with
//!   BGRX → I420 conversion of only the damaged rectangles ([`super::convert`]), and
//!   for H.264 a hint to libx264 that the rest of the picture is unchanged;
//! - NVENC: h264_nvenc, hevc_nvenc and av1_nvenc. NVENC takes BGRX as is and converts on
//!   the GPU, so the CPU only copies the picture into NVENC's input buffer. This is the
//!   path on WSL2, where clients hand over wl_shm buffers and CUDA reaches the GPU
//!   through /dev/dxg.

use super::{convert, CpuImage, EncodeError, Encoder, Input, Picture, Settings};
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
    }
}

/// Opens a small encoder and encodes one picture, so a codec is offered only if it
/// actually works in this build of libavcodec.
pub fn probe(family: Family, codec: Codec) -> Result<(), EncodeError> {
    if family == Family::Software && codec == Codec::Av1 {
        return Err(EncodeError("AV1 software encoding is not offered".into()));
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
    width: u32,
    height: u32,
    pts: i64,
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
                // Constant QP rather than CRF: x264 skips a macroblock hinted constant only
                // when its reference was coded at no higher a QP, which a floating
                // per-frame QP keeps breaking.
                options.set("qp", &settings.crf.to_string());
                options.set("preset", &settings.preset);
                options.set("profile", "high");
                options.set("threads", &settings.threads_for(width, height).to_string());
                // Keyframes only on request: a new client, request_keyframe, a resize.
                options.set("x264-params", "keyint=infinite:scenecut=0:repeat-headers=1:aud=0");
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
            (Family::Software, Codec::Av1) => return Err(EncodeError("AV1 software encoding is not offered".into())),
        }
        let encoder = video.open_with(options)?;
        let picture = ff::frame::Video::new(format, width, height);
        Ok(Self { family, codec, encoder, picture, shadow: Vec::new(), width, height, pts: 0 })
    }

    /// Brings the encoder's picture up to date with `image`: only the damaged
    /// rectangles, or all of it. Returns the macroblocks that really changed when that
    /// is known (software encoders with damage).
    fn convert(&mut self, image: &CpuImage, damage: Option<&[Rect]>) -> Result<Option<Vec<Rect>>, EncodeError> {
        if image.width != self.width || image.height != self.height {
            return Err(EncodeError(format!(
                "input {}x{} does not match the encoder's {}x{}",
                image.width, image.height, self.width, self.height
            )));
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
                            .copy_from_slice(&image.data[y * image.stride + x0 * 4..y * image.stride + x1 * 4]);
                    }
                }
                Ok(None)
            }
            Family::Software => {
                let (ys, us, vs) = (self.picture.stride(0), self.picture.stride(1), self.picture.stride(2));
                let h = self.height as usize;
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
                let damage = damage.filter(|_| self.shadow.len() == image.data.len());
                Ok(match damage {
                    Some(d) => {
                        let changed = convert::changed_blocks(
                            &image.data,
                            &mut self.shadow,
                            image.stride,
                            self.width,
                            self.height,
                            d,
                        );
                        convert::bgrx_to_i420(
                            &image.data,
                            image.stride,
                            self.width,
                            self.height,
                            Some(&changed),
                            planes,
                        );
                        Some(changed)
                    }
                    None => {
                        convert::bgrx_to_i420(&image.data, image.stride, self.width, self.height, None, planes);
                        self.shadow.clear();
                        self.shadow.extend_from_slice(&image.data);
                        None
                    }
                })
            }
        }
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
}

impl Encoder for LavcEncoder {
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
        let Input::Cpu(image) = input;
        let damage = if keyframe { None } else { damage };
        let t0 = std::time::Instant::now();
        let changed = self.convert(image, damage)?;
        let convert_us = t0.elapsed().as_micros();
        unsafe {
            ff::ffi::av_frame_remove_side_data(
                self.picture.as_mut_ptr(),
                ff::ffi::AVFrameSideDataType::AV_FRAME_DATA_VIDEO_HINT,
            )
        };
        if let (Some(changed), Codec::H264) = (&changed, self.codec) {
            tracing::trace!(
                "{} of {} macroblock rows-runs changed, {} px",
                changed.len(),
                self.height.div_ceil(16),
                changed.iter().map(|r| (r.w * r.h) as u64).sum::<u64>()
            );
            self.hint_changes(changed);
        }
        self.picture.set_pts(Some(self.pts));
        self.pts += 1;
        self.picture.set_kind(if keyframe { ff::picture::Type::I } else { ff::picture::Type::None });
        self.encoder.send_frame(&self.picture)?;
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
        tracing::trace!("convert {convert_us} µs, encode {} µs", t0.elapsed().as_micros() - convert_us);
        Ok(Picture { data, keyframe: key })
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
    fn odd_sizes_are_rejected() {
        assert!(LavcEncoder::new(Family::Software, Codec::H264, 99, 64, &Settings::default()).is_err());
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
}
