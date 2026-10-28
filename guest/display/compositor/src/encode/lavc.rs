//! Encoders through libavcodec that take pixels in system memory (wl_shm buffers, or GPU
//! buffers read back):
//!
//! - software: libx264 (H.264) and libx265 (HEVC), after a BGRX → I420 conversion with
//!   libswscale;
//! - NVENC: h264_nvenc, hevc_nvenc and av1_nvenc. NVENC takes BGRX as is and converts on
//!   the GPU, so the CPU only copies the picture into NVENC's input buffer. This is the
//!   path on WSL2, where clients hand over wl_shm buffers and CUDA reaches the GPU
//!   through /dev/dxg.

use super::{CpuImage, EncodeError, Encoder, Input, InputKind, Picture, Settings};
use caboose_display_protocol::Codec;
use ffmpeg_next as ff;
use ff::format::Pixel;

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
    let picture = encoder.encode(Input::Cpu(&image), true)?;
    if picture.data.is_empty() || !picture.keyframe {
        return Err(EncodeError("probe produced no keyframe".into()));
    }
    Ok(())
}

pub struct LavcEncoder {
    family: Family,
    codec: Codec,
    encoder: ff::encoder::Video,
    /// Software only: BGRX → I420. NVENC takes BGRX directly.
    scaler: Option<ff::software::scaling::Context>,
    /// The picture handed to the encoder: I420 for software, BGRX for NVENC.
    picture: ff::frame::Video,
    width: u32,
    height: u32,
    pts: i64,
}

// SAFETY: the libavcodec and libswscale contexts are owned exclusively by this value
// and are used from one thread at a time; libx264/libx265 contexts are not tied to the
// thread that created them.
unsafe impl Send for LavcEncoder {}

impl LavcEncoder {
    pub fn new(family: Family, codec: Codec, width: u32, height: u32, settings: &Settings) -> Result<Self, EncodeError> {
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
                options.set("crf", &settings.crf.to_string());
                options.set("preset", &settings.preset);
                options.set("profile", "high");
                options.set("threads", &settings.threads.to_string());
                // Keyframes only on request: a new client, request_keyframe, a resize.
                options.set("x264-params", "keyint=infinite:scenecut=0:repeat-headers=1:aud=0");
            }
            (Family::Software, Codec::Hevc) => {
                options.set("tune", "zerolatency");
                options.set("crf", &settings.crf.to_string());
                options.set("preset", "ultrafast");
                options.set(
                    "x265-params",
                    &format!(
                        "keyint=-1:scenecut=0:repeat-headers=1:log-level=error:pools={}:frame-threads=1",
                        settings.threads
                    ),
                );
            }
            (Family::Software, Codec::Av1) => return Err(EncodeError("AV1 software encoding is not offered".into())),
        }
        let encoder = video.open_with(options)?;
        let scaler = match family {
            Family::Software => Some(ff::software::scaling::Context::get(
                Pixel::BGRZ,
                width,
                height,
                Pixel::YUV420P,
                width,
                height,
                ff::software::scaling::Flags::POINT,
            )?),
            Family::Nvenc => None,
        };
        let picture = ff::frame::Video::new(format, width, height);
        Ok(Self { family, codec, encoder, scaler, picture, width, height, pts: 0 })
    }

    fn convert(&mut self, image: &CpuImage) -> Result<(), EncodeError> {
        if image.width != self.width || image.height != self.height {
            return Err(EncodeError(format!(
                "input {}x{} does not match the encoder's {}x{}",
                image.width, image.height, self.width, self.height
            )));
        }
        // The encoder may still hold a reference to the last picture.
        unsafe {
            if ff::ffi::av_frame_make_writable(self.picture.as_mut_ptr()) < 0 {
                return Err(EncodeError("could not make the picture writable".into()));
            }
        }
        let Some(scaler) = self.scaler.as_mut() else {
            // NVENC: copy rows into the encoder's frame.
            let stride = self.picture.stride(0);
            let row = self.width as usize * 4;
            let dst = self.picture.data_mut(0);
            for y in 0..self.height as usize {
                dst[y * stride..y * stride + row].copy_from_slice(&image.data[y * image.stride..y * image.stride + row]);
            }
            return Ok(());
        };
        // A frame header that borrows `image` for the duration of sws_scale. It owns no
        // buffer (buf[0] is null), so dropping it frees nothing of `image`'s.
        let mut src = ff::frame::Video::empty();
        unsafe {
            let f = src.as_mut_ptr();
            (*f).format = ff::ffi::AVPixelFormat::AV_PIX_FMT_BGR0 as i32;
            (*f).width = image.width as i32;
            (*f).height = image.height as i32;
            (*f).data[0] = image.data.as_ptr() as *mut u8;
            (*f).linesize[0] = image.stride as i32;
        }
        let result = scaler.run(&src, &mut self.picture);
        unsafe {
            (*src.as_mut_ptr()).data[0] = std::ptr::null_mut();
        }
        result.map_err(EncodeError::from)
    }
}

impl Encoder for LavcEncoder {
    fn codec(&self) -> Codec {
        self.codec
    }

    fn name(&self) -> &'static str {
        encoder_name(self.family, self.codec)
    }

    fn input_kind(&self) -> InputKind {
        InputKind::Cpu
    }

    fn coded_size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    fn encode(&mut self, input: Input<'_>, keyframe: bool) -> Result<Picture, EncodeError> {
        let Input::Cpu(image) = input else {
            return Err(EncodeError(format!("{} takes system-memory pixels", self.name())));
        };
        self.convert(image)?;
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
        let first = enc.encode(Input::Cpu(&gradient(128, 96, 0)), true).unwrap();
        assert!(first.keyframe);
        let types = nal_types(Codec::H264, &first.data);
        assert!(types.contains(&7) && types.contains(&8) && types.contains(&5), "{types:?}");
        let second = enc.encode(Input::Cpu(&gradient(128, 96, 3)), false).unwrap();
        assert!(!second.keyframe);
        assert!(!nal_types(Codec::H264, &second.data).contains(&7));
        let forced = enc.encode(Input::Cpu(&gradient(128, 96, 6)), true).unwrap();
        assert!(forced.keyframe);
        assert!(nal_types(Codec::H264, &forced.data).contains(&5));
    }

    #[test]
    fn hevc_keyframes_carry_vps_sps_pps() {
        ff::init().unwrap();
        let mut enc = LavcEncoder::new(Family::Software, Codec::Hevc, 64, 64, &Settings::default()).unwrap();
        let first = enc.encode(Input::Cpu(&gradient(64, 64, 0)), true).unwrap();
        assert!(first.keyframe);
        let types = nal_types(Codec::Hevc, &first.data);
        assert!(types.contains(&32) && types.contains(&33) && types.contains(&34), "{types:?}");
        let second = enc.encode(Input::Cpu(&gradient(64, 64, 2)), false).unwrap();
        assert!(!second.keyframe);
    }

    #[test]
    fn odd_sizes_are_rejected() {
        assert!(LavcEncoder::new(Family::Software, Codec::H264, 99, 64, &Settings::default()).is_err());
    }
}
