//! Encoders: one per window stream, each producing Annex-B pictures.
//!
//! Every encoder implements [`Encoder`]. Which ones a stream can get is decided once at
//! start-up by [`Encoders::probe`], which opens each candidate and encodes a test
//! picture: NVENC (h264/hevc/av1_nvenc through libavcodec, from system memory), the
//! zero-copy VA-API encoder (dmabuf in, when the render node has an encode entrypoint),
//! and the software encoders (libx264, libx265), which always work.

pub mod convert;
pub mod lavc;
#[cfg(feature = "vaapi")]
pub mod vaapi;

use caboose_display_protocol::{Codec, Rect};
use smithay::backend::allocator::dmabuf::Dmabuf;
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
    /// A GPU buffer, encoded without leaving GPU memory.
    Dmabuf(&'a Dmabuf),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputKind {
    Cpu,
    Dmabuf,
}

/// One encoded picture in Annex-B.
pub struct Picture {
    pub data: Vec<u8>,
    pub keyframe: bool,
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
    fn codec(&self) -> Codec;
    /// Short name for logs and `--list-encoders`, e.g. `libx264`.
    fn name(&self) -> &'static str;
    fn input_kind(&self) -> InputKind;
    /// Coded size; the input must be exactly this size.
    fn coded_size(&self) -> (u32, u32);
    /// Encodes one picture. `keyframe` forces an IDR with parameter sets. `damage`
    /// lists what changed since the previous picture (in picture pixels); `None`
    /// means everything.
    fn encode(&mut self, input: Input<'_>, keyframe: bool, damage: Option<&[Rect]>) -> Result<Picture, EncodeError>;
}

/// Encoder settings shared by every stream.
#[derive(Debug, Clone)]
pub struct Settings {
    /// Constant rate factor for the software encoders, constant quality for NVENC
    /// (lower is better quality).
    pub crf: u32,
    /// Worker threads per software encoder.
    pub threads: u32,
    /// x264 preset. `ultrafast` keeps the CPU cost per update lowest.
    pub preset: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self { crf: 23, threads: 2, preset: "ultrafast".into() }
    }
}

/// One way of making encoders for a codec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Backend {
    Software(Codec),
    Nvenc(Codec),
    #[cfg(feature = "vaapi")]
    Vaapi { codec: Codec, device: std::path::PathBuf },
}

impl Backend {
    pub fn codec(&self) -> Codec {
        match self {
            Backend::Software(c) | Backend::Nvenc(c) => *c,
            #[cfg(feature = "vaapi")]
            Backend::Vaapi { codec, .. } => *codec,
        }
    }

    pub fn input_kind(&self) -> InputKind {
        match self {
            Backend::Software(_) | Backend::Nvenc(_) => InputKind::Cpu,
            #[cfg(feature = "vaapi")]
            Backend::Vaapi { .. } => InputKind::Dmabuf,
        }
    }

    pub fn describe(&self) -> String {
        match self {
            Backend::Software(c) => format!("{} ({})", c.as_str(), lavc::encoder_name(lavc::Family::Software, *c)),
            Backend::Nvenc(c) => format!("{} ({})", c.as_str(), lavc::encoder_name(lavc::Family::Nvenc, *c)),
            #[cfg(feature = "vaapi")]
            Backend::Vaapi { codec, device } => format!("{} (VA-API on {})", codec.as_str(), device.display()),
        }
    }

    /// Size alignment of the coded picture.
    pub fn alignment(&self) -> u32 {
        match self {
            Backend::Software(_) | Backend::Nvenc(_) => 2,
            #[cfg(feature = "vaapi")]
            Backend::Vaapi { .. } => 16,
        }
    }

    pub fn create(&self, width: u32, height: u32, settings: &Settings) -> Result<Box<dyn Encoder>, EncodeError> {
        match self {
            Backend::Software(c) => {
                Ok(Box::new(lavc::LavcEncoder::new(lavc::Family::Software, *c, width, height, settings)?))
            }
            Backend::Nvenc(c) => Ok(Box::new(lavc::LavcEncoder::new(lavc::Family::Nvenc, *c, width, height, settings)?)),
            #[cfg(feature = "vaapi")]
            Backend::Vaapi { codec, device } => Ok(Box::new(vaapi::VaapiEncoder::new(*codec, device, width, height)?)),
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
    #[cfg(feature = "vaapi")]
    Vaapi,
}

impl Encoders {
    /// Finds the usable encoders. Hardware ones come first (HEVC, then AV1, then
    /// H.264); the software ones prefer H.264, because x265 costs several times the CPU
    /// of x264.
    pub fn probe(choice: Choice, render_node: Option<&std::path::Path>, settings: Settings) -> Self {
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
        #[cfg(feature = "vaapi")]
        if matches!(choice, Choice::Auto | Choice::Vaapi) {
            if let Some(node) = render_node {
                for codec in [Codec::Hevc, Codec::H264] {
                    match vaapi::probe(codec, node) {
                        Ok(()) => backends.push(Backend::Vaapi { codec, device: node.to_owned() }),
                        Err(e) => tracing::info!("VA-API {} unavailable on {}: {e}", codec.as_str(), node.display()),
                    }
                }
            }
        }
        #[cfg(not(feature = "vaapi"))]
        let _ = render_node;
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
}
