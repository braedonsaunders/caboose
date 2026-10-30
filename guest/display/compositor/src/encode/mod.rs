//! Encoders: one per window stream, each producing Annex-B pictures.
//!
//! Every encoder implements [`Encoder`]. Which ones a stream can get is decided once at
//! start-up by [`Encoders::probe`], which opens each candidate and encodes a test
//! picture: NVENC (h264/hevc/av1_nvenc through libavcodec, from system memory) and the
//! software encoders (libx264, libx265), which always work. Alpha windows (popups) have
//! no encoder: [`alpha::AlphaTiler`] sends them as RGBA tiles.

pub mod alpha;
pub mod convert;
pub mod lavc;
pub mod refine;

use caboose_display_protocol::{Codec, Rect};
use std::fmt;

/// Pixels in system memory, 4 bytes per pixel, little-endian XRGB8888/ARGB8888
/// (B, G, R, X in memory). `width`/`height` are the coded (padded) size; the content
/// occupies the top-left `visible` region and the padding repeats its edge.
pub struct CpuImage {
    pub data: Vec<u8>,
    pub stride: usize,
    pub width: u32,
    pub height: u32,
}

impl CpuImage {
    pub fn new(width: u32, height: u32) -> Self {
        let stride = width as usize * 4;
        Self { data: vec![0; stride * height as usize], stride, width, height }
    }
}

/// What an encoder consumes.
pub enum Input<'a> {
    Cpu(&'a CpuImage),
    /// The coded size at (`x`, `y`) of a larger image (a window's motion region).
    CpuAt(&'a CpuImage, u32, u32),
    /// A client's wl_shm buffer, read in place: the picture is the coded size at
    /// (`x`, `y`) of the buffer. The buffer is not released to the client until the
    /// encoder is done with it.
    Shm(&'a ShmPicture),
}

pub struct ShmPicture {
    pub buffer: smithay::backend::renderer::utils::Buffer,
    pub x: i32,
    pub y: i32,
}

/// Pixels to read: `data` starts at the picture's top-left pixel, rows `stride` apart.
pub struct Pixels<'a> {
    pub data: &'a [u8],
    pub stride: usize,
}

/// One encoded picture in Annex-B.
pub struct Picture {
    pub data: Vec<u8>,
    pub keyframe: bool,
    /// Milliseconds until [`Encoder::refine`] has something to sharpen if nothing
    /// changes meanwhile; `None` when everything is as sharp as it gets.
    pub refine_in_ms: Option<u64>,
    /// What really changed in the picture, when the encoder knows (picture pixels):
    /// the damaged blocks whose pixels differ.
    pub changed: Option<Vec<Rect>>,
}

#[derive(Debug)]
pub struct EncodeError(pub String);

impl fmt::Display for EncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EncodeError {}

impl From<ffmpeg_next::Error> for EncodeError {
    fn from(e: ffmpeg_next::Error) -> Self {
        EncodeError(e.to_string())
    }
}

/// A video encoder for one stream at one size. A size change makes a new encoder.
pub trait Encoder: Send {
    /// Keep this region at its last base-picture pixels, even when an encode reads
    /// the complete input (a keyframe or a replaced backing buffer). The original
    /// input remains available to the region's independent video encoder.
    fn exclude(&mut self, region: Option<Rect>);
    fn codec(&self) -> Codec;
    /// Short name for logs and `--list-encoders`, e.g. `libx264`.
    fn name(&self) -> &'static str;
    /// Coded size; the input must be exactly this size.
    fn coded_size(&self) -> (u32, u32);
    /// Encodes one picture. `keyframe` forces an IDR with parameter sets. `damage`
    /// lists what changed since the previous picture (in picture pixels); `None`
    /// means everything.
    fn encode(&mut self, input: Input<'_>, keyframe: bool, damage: Option<&[Rect]>) -> Result<Picture, EncodeError>;
    /// Encodes the previous picture again, sharpening what has been quiet long enough
    /// (see [`refine`]). Called when a picture said so in `refine_in_ms` and nothing
    /// changed since; `encode` sharpens along the way when there is a change.
    fn refine(&mut self) -> Result<Picture, EncodeError> {
        Err(EncodeError(format!("{} does not refine", self.name())))
    }
    /// Small changes as lossless tiles instead of a picture. When what really changed
    /// in `damage` is at most `max_px` pixels in a few rectangles, returns those pixels;
    /// the client then shows them, and the next `encode` codes them into the stream.
    /// `None`: encode a picture as usual (software encoders only tile).
    fn tiles(&mut self, input: Input<'_>, damage: &[Rect], max_px: u64) -> Result<Option<Tiles>, EncodeError> {
        let _ = (input, damage, max_px);
        Ok(None)
    }
}

/// Changed areas sent as tiles: each rectangle (picture pixels) with its RGB pixels
/// (RGBA from an [`alpha::AlphaTiler`]), rows packed.
pub struct Tiles {
    pub tiles: Vec<(Rect, Vec<u8>)>,
    /// As in [`Picture`].
    pub refine_in_ms: Option<u64>,
}

/// Encoder settings shared by every stream.
#[derive(Debug, Clone)]
pub struct Settings {
    /// Constant rate factor for the software encoders, constant quality for NVENC
    /// (lower is better quality).
    pub crf: u32,
    /// Worker threads per software encoder; 0 picks by picture size: one up to
    /// 2560×1600 (a phone's 1179×2556 included), two above. Each extra thread costs CPU:
    /// at 3840×2160, Chromium took 18% of a core to type with one thread, 22% with two
    /// and 25% with four (scrolling: 26%, 34%, 38%); two halve the time per picture.
    pub threads: u32,
    /// x264 preset. `ultrafast` keeps the CPU cost per update lowest.
    pub preset: String,
    /// QP that areas quiet for `refine_after_ms` are coded at once more (libx264);
    /// 0, or not below `crf`, turns refinement off.
    pub refine_qp: u32,
    pub refine_after_ms: u32,
    /// Changes of at most this many pixels go as lossless tiles instead of a picture;
    /// 0 turns tiles off.
    pub tile_max_px: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            crf: 23,
            threads: 0,
            preset: "ultrafast".into(),
            refine_qp: 12,
            refine_after_ms: 300,
            tile_max_px: 65536,
        }
    }
}

impl Settings {
    pub fn threads_for(&self, width: u32, height: u32) -> u32 {
        match self.threads {
            0 if width as u64 * height as u64 > 2560 * 1600 => 2,
            0 => 1,
            n => n,
        }
    }
}

/// One way of making encoders for a codec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Backend {
    Software(Codec),
    Nvenc(Codec),
}

impl Backend {
    pub fn codec(&self) -> Codec {
        match self {
            Backend::Software(c) | Backend::Nvenc(c) => *c,
        }
    }

    pub fn describe(&self) -> String {
        match self {
            Backend::Software(c) => format!("{} ({})", c.as_str(), lavc::encoder_name(lavc::Family::Software, *c)),
            Backend::Nvenc(c) => format!("{} ({})", c.as_str(), lavc::encoder_name(lavc::Family::Nvenc, *c)),
        }
    }

    /// Size alignment of the coded picture.
    pub fn alignment(&self) -> u32 {
        match self {
            Backend::Software(_) | Backend::Nvenc(_) => 2,
        }
    }

    pub fn create(&self, width: u32, height: u32, settings: &Settings) -> Result<Box<dyn Encoder>, EncodeError> {
        match self {
            Backend::Software(c) => {
                Ok(Box::new(lavc::LavcEncoder::new(lavc::Family::Software, *c, width, height, settings)?))
            }
            Backend::Nvenc(c) => {
                Ok(Box::new(lavc::LavcEncoder::new(lavc::Family::Nvenc, *c, width, height, settings)?))
            }
        }
    }
}

/// The encoders this machine can run, in preference order.
#[derive(Debug, Clone)]
pub struct Encoders {
    pub backends: Vec<Backend>,
    pub settings: Settings,
}

/// Which encoders to consider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    Auto,
    Software,
    Nvenc,
}

impl Encoders {
    /// Finds the usable encoders. Hardware ones come first (HEVC, then AV1, then
    /// H.264); the software ones prefer H.264, because x265 costs several times the CPU
    /// of x264.
    pub fn probe(choice: Choice, settings: Settings) -> Self {
        ffmpeg_next::init().ok();
        // libavcodec logs every failed probe at error level; the outcome is logged below.
        ffmpeg_next::util::log::set_level(ffmpeg_next::util::log::Level::Fatal);
        let mut backends = Vec::new();
        if matches!(choice, Choice::Auto | Choice::Nvenc) {
            for codec in [Codec::Hevc, Codec::Av1, Codec::H264] {
                match lavc::probe(lavc::Family::Nvenc, codec) {
                    Ok(()) => backends.push(Backend::Nvenc(codec)),
                    Err(e) => tracing::info!("NVENC {} unavailable: {e}", codec.as_str()),
                }
            }
        }
        if matches!(choice, Choice::Auto | Choice::Software) {
            for codec in [Codec::H264, Codec::Hevc] {
                match lavc::probe(lavc::Family::Software, codec) {
                    Ok(()) => backends.push(Backend::Software(codec)),
                    Err(e) => tracing::info!("software {} unavailable: {e}", codec.as_str()),
                }
            }
        }
        Self { backends, settings }
    }

    /// Codecs offered in `hello`, in preference order, without repeats.
    pub fn codecs(&self) -> Vec<Codec> {
        let mut out = Vec::new();
        for b in &self.backends {
            if !out.contains(&b.codec()) {
                out.push(b.codec());
            }
        }
        out
    }

    /// The preferred backend for a codec.
    pub fn backend_for(&self, codec: Codec) -> Option<&Backend> {
        self.backends.iter().find(|b| b.codec() == codec)
    }
}

/// Rounds up to a multiple of `align`.
pub fn align_up(v: u32, align: u32) -> u32 {
    v.div_ceil(align) * align
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alignment_rounds_up() {
        assert_eq!(align_up(1179, 2), 1180);
        assert_eq!(align_up(2161, 16), 2176);
        assert_eq!(align_up(64, 16), 64);
    }

    #[test]
    fn one_encoder_thread_up_to_2560x1600() {
        let auto = Settings::default();
        assert_eq!(auto.threads_for(1180, 2556), 1);
        assert_eq!(auto.threads_for(2560, 1600), 1);
        assert_eq!(auto.threads_for(3840, 2160), 2);
        assert_eq!(Settings { threads: 4, ..Settings::default() }.threads_for(640, 480), 4);
    }
}
