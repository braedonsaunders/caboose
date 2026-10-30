//! The phone's cameras and depth sensor as v4l2loopback devices (docs/devices.md,
//! "Cameras and depth"). The hub adds and removes the devices and watches who streams
//! from them; a worker thread per device decodes the phone's H.264 and writes pictures.

use super::sys::*;
use caboose_display_protocol::{Message, Size};
use ffmpeg_next as ff;
use smithay::reexports::calloop::channel::Sender;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub const CONTROL: &str = "/dev/v4l2loopback";

/// What a loopback device carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    /// YUYV 4:2:2, from the phone's H.264.
    Yuyv,
    /// 16-bit depth in millimetres.
    Z16,
}

impl Format {
    fn fourcc(self) -> u32 {
        match self {
            Format::Yuyv => V4L2_PIX_FMT_YUYV,
            Format::Z16 => V4L2_PIX_FMT_Z16,
        }
    }
    /// The bytes of one picture.
    pub fn picture_len(self, size: Size) -> usize {
        size.w as usize * size.h as usize * 2
    }
    /// A picture of nothing: black, or no depth readings.
    pub fn blank(self, size: Size) -> Vec<u8> {
        match self {
            Format::Yuyv => [16u8, 128].repeat(size.w as usize * size.h as usize),
            Format::Z16 => vec![0; self.picture_len(size)],
        }
    }
}

/// Adds a loopback device; returns its number (`/dev/videoN`).
pub fn add(label: &str, size: Size) -> io::Result<u32> {
    let control = open_rw(Path::new(CONTROL), false)?;
    let mut config = LoopbackConfig {
        output_nr: -1,
        unused: -1,
        card_label: c_field(label),
        min_width: 0,
        max_width: size.w as u32,
        min_height: 0,
        max_height: size.h as u32,
        max_buffers: 0,
        max_openers: 0,
        debug: 0,
        // Exclusive capabilities: a capture device once the computer writes, which is how
        // Chromium and Firefox list it as a camera.
        announce_all_caps: 0,
    };
    let nr = ioctl_ptr(&control, V4L2LOOPBACK_CTL_ADD, &mut config)?;
    Ok(nr as u32)
}

/// Removes a loopback device; fails with `EBUSY` while it is open.
pub fn remove(nr: u32) -> io::Result<()> {
    let control = open_rw(Path::new(CONTROL), false)?;
    ioctl_int(&control, V4L2LOOPBACK_CTL_REMOVE, nr as libc::c_ulong).map(|_| ())
}

pub fn node(nr: u32) -> PathBuf {
    PathBuf::from(format!("/dev/video{nr}"))
}

/// The output side of a loopback device, kept open with its format set.
pub struct Output {
    fd: OwnedFd,
}

impl Output {
    pub fn open(nr: u32, format: Format, size: Size, fps: u32) -> io::Result<Self> {
        // A node made a moment ago may not have its permissions from udev yet.
        let deadline = Instant::now() + Duration::from_secs(2);
        let fd = loop {
            match open_rw(&node(nr), true) {
                Ok(fd) => break fd,
                Err(e) if Instant::now() < deadline && matches!(e.raw_os_error(), Some(libc::EACCES | libc::ENOENT)) => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                Err(e) => return Err(e),
            }
        };
        let (w, h) = (size.w as u32, size.h as u32);
        let mut fmt = V4l2Format::output(V4l2PixFormat {
            width: w,
            height: h,
            pixelformat: format.fourcc(),
            field: V4L2_FIELD_NONE,
            bytesperline: w * 2,
            sizeimage: w * h * 2,
            colorspace: match format {
                Format::Yuyv => V4L2_COLORSPACE_SRGB,
                Format::Z16 => V4L2_COLORSPACE_RAW,
            },
            ..Default::default()
        });
        ioctl_ptr(&fd, VIDIOC_S_FMT, &mut fmt)?;
        let mut parm = V4l2StreamParm::output(fps.max(1));
        // Not every version takes a frame rate; the format is what matters.
        let _ = ioctl_ptr(&fd, VIDIOC_S_PARM, &mut parm);
        let mut sub = V4l2EventSubscription { kind: V4L2_EVENT_PRI_CLIENT_USAGE, ..Default::default() };
        ioctl_ptr(&fd, VIDIOC_SUBSCRIBE_EVENT, &mut sub)?;
        Ok(Self { fd })
    }

    pub fn raw_fd(&self) -> i32 {
        self.fd.as_raw_fd()
    }

    pub fn try_clone(&self) -> io::Result<OwnedFd> {
        self.fd.try_clone()
    }

    /// Reads queued usage events; returns the last reader count, if any arrived.
    pub fn usage(&self) -> Option<u32> {
        let mut last = None;
        loop {
            let mut ev = V4l2Event::default();
            if ioctl_ptr(&self.fd, VIDIOC_DQEVENT, &mut ev).is_err() {
                return last;
            }
            if ev.kind == V4L2_EVENT_PRI_CLIENT_USAGE {
                last = Some(ev.data[0] as u32);
            }
        }
    }
}

/// YUV 4:2:0 planes of a decoded picture.
pub struct Planes<'a> {
    pub width: usize,
    pub height: usize,
    pub y: &'a [u8],
    pub y_stride: usize,
    /// Cb and Cr: separate planes, or one interleaved plane (NV12) given twice with
    /// `interleaved`.
    pub u: &'a [u8],
    pub v: &'a [u8],
    pub c_stride: usize,
    pub interleaved: bool,
    /// JPEG (full) range, converted to the video range YUYV consumers expect.
    pub full_range: bool,
}

/// Converts 4:2:0 to YUYV at `out`'s size, scaling by nearest neighbour when the sizes
/// differ.
pub fn to_yuyv(p: &Planes<'_>, out_size: Size, out: &mut Vec<u8>) {
    let (ow, oh) = (out_size.w as usize, out_size.h as usize);
    out.clear();
    out.reserve(ow * oh * 2);
    let luma = |y: u8| if p.full_range { (16 + (y as u32 * 219 + 127) / 255) as u8 } else { y };
    let chroma = |c: u8| if p.full_range { (128 + ((c as i32 - 128) * 224) / 255) as u8 } else { c };
    for oy in 0..oh {
        let sy = oy * p.height / oh;
        let y_row = &p.y[sy * p.y_stride..];
        let c_row = (sy / 2) * p.c_stride;
        for ox in (0..ow).step_by(2) {
            let sx0 = ox * p.width / ow;
            let sx1 = ((ox + 1) * p.width / ow).min(p.width - 1);
            let (u, v) = if p.interleaved {
                let i = c_row + (sx0 / 2) * 2;
                (p.u[i], p.u[i + 1])
            } else {
                (p.u[c_row + sx0 / 2], p.v[c_row + sx0 / 2])
            };
            out.extend_from_slice(&[luma(y_row[sx0]), chroma(u), luma(y_row[sx1]), chroma(v)]);
        }
    }
}

/// Scales a depth picture to `out`'s size by nearest neighbour.
pub fn scale_depth(data: &[u8], size: Size, out_size: Size) -> Vec<u8> {
    if size == out_size {
        return data.to_vec();
    }
    let (w, h, ow, oh) = (size.w as usize, size.h as usize, out_size.w as usize, out_size.h as usize);
    let mut out = Vec::with_capacity(ow * oh * 2);
    for oy in 0..oh {
        let sy = oy * h / oh;
        for ox in 0..ow {
            let i = (sy * w + ox * w / ow) * 2;
            out.extend_from_slice(&data[i..i + 2]);
        }
    }
    out
}

/// What the hub tells a camera's worker.
pub enum Input {
    /// An H.264 access unit.
    Unit { data: Vec<u8>, keyframe: bool },
    /// A depth picture of `size`.
    Depth { size: Size, data: Vec<u8> },
    /// The phone is gone (or the device withdrawn): show black until it returns.
    Detach,
    /// The phone is back.
    Attach,
    /// Whether a reader streams.
    Streaming(bool),
}

/// A camera's worker: decodes and writes pictures until its channel closes.
pub struct Worker {
    pub tx: mpsc::Sender<Input>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Worker {
    pub fn spawn(
        device: String,
        fd: OwnedFd,
        format: Format,
        size: Size,
        fps: u32,
        out: Sender<Message>,
    ) -> io::Result<Self> {
        let (tx, rx) = mpsc::channel();
        let thread = std::thread::Builder::new()
            .name(format!("camera {device}"))
            .spawn(move || run(device, fd, format, size, fps, rx, out))?;
        Ok(Self { tx, thread: Some(thread) })
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // Closing the channel ends the worker.
        let (dead, _) = mpsc::channel();
        self.tx = dead;
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

struct Decoder {
    decoder: ff::decoder::Video,
    frame: ff::frame::Video,
}

// SAFETY: the libavcodec context is used only by the worker that owns it.
unsafe impl Send for Decoder {}

impl Decoder {
    fn new() -> Result<Self, String> {
        ff::init().map_err(|e| e.to_string())?;
        let codec = ff::decoder::find(ff::codec::Id::H264).ok_or("libavcodec has no H.264 decoder")?;
        let mut ctx = ff::codec::context::Context::new_with_codec(codec);
        ctx.set_flags(ff::codec::Flags::LOW_DELAY);
        let decoder = ctx.decoder().video().map_err(|e| e.to_string())?;
        Ok(Self { decoder, frame: ff::frame::Video::empty() })
    }

    /// Decodes one access unit into YUYV at `size`; `Ok(false)` when no picture came out.
    fn decode(&mut self, data: &[u8], size: Size, out: &mut Vec<u8>) -> Result<bool, String> {
        self.decoder.send_packet(&ff::Packet::copy(data)).map_err(|e| e.to_string())?;
        let mut got = false;
        while self.decoder.receive_frame(&mut self.frame).is_ok() {
            use ff::format::Pixel;
            let f = &self.frame;
            let (interleaved, full_range) = match f.format() {
                Pixel::YUV420P => (false, false),
                Pixel::YUVJ420P => (false, true),
                Pixel::NV12 => (true, false),
                other => return Err(format!("unexpected picture format {other:?}")),
            };
            let planes = Planes {
                width: f.width() as usize,
                height: f.height() as usize,
                y: f.data(0),
                y_stride: f.stride(0),
                u: f.data(1),
                v: if interleaved { f.data(1) } else { f.data(2) },
                c_stride: f.stride(1),
                interleaved,
                full_range: full_range || f.color_range() == ff::color::Range::JPEG,
            };
            to_yuyv(&planes, size, out);
            got = true;
        }
        Ok(got)
    }
}

fn run(device: String, fd: OwnedFd, format: Format, size: Size, fps: u32, rx: mpsc::Receiver<Input>, out: Sender<Message>) {
    let blank = format.blank(size);
    let frame_time = Duration::from_secs_f64(1.0 / fps.max(1) as f64);
    let mut picture = blank.clone();
    let mut decoder = None;
    let mut waiting_for_keyframe = true;
    let mut attached = true;
    let mut streaming = false;
    let mut last_new = Instant::now();
    let mut last_written = Instant::now();
    let write = |data: &[u8]| {
        if let Err(e) = write_all(&fd, data) {
            if e.raw_os_error() != Some(libc::EAGAIN) {
                tracing::debug!("camera {device}: write: {e}");
            }
        }
    };
    // The first picture makes the device a capture device that applications list.
    write(&blank);
    loop {
        let input = match rx.recv_timeout(frame_time) {
            Ok(i) => Some(i),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
        };
        match input {
            Some(Input::Unit { data, keyframe }) if attached => {
                if waiting_for_keyframe && !keyframe {
                    continue;
                }
                if decoder.is_none() {
                    match Decoder::new() {
                        Ok(d) => decoder = Some(d),
                        Err(e) => {
                            tracing::warn!("camera {device}: {e}");
                            return;
                        }
                    }
                }
                let mut yuyv = Vec::new();
                match decoder.as_mut().unwrap().decode(&data, size, &mut yuyv) {
                    Ok(true) => {
                        waiting_for_keyframe = false;
                        picture = yuyv;
                        write(&picture);
                        last_new = Instant::now();
                        last_written = last_new;
                    }
                    Ok(false) => {}
                    Err(e) => {
                        tracing::debug!("camera {device}: decode: {e}");
                        decoder = None;
                        waiting_for_keyframe = true;
                        let _ = out.send(Message::DeviceKeyframe { device: device.clone() });
                    }
                }
            }
            Some(Input::Depth { size: got, data }) if attached => {
                if data.len() == format.picture_len(got) && got.w > 0 && got.h > 0 {
                    picture = scale_depth(&data, got, size);
                    write(&picture);
                    last_new = Instant::now();
                    last_written = last_new;
                }
            }
            Some(Input::Unit { .. } | Input::Depth { .. }) => {}
            Some(Input::Detach) => {
                attached = false;
                picture = blank.clone();
                decoder = None;
                waiting_for_keyframe = true;
                write(&picture);
            }
            Some(Input::Attach) => {
                attached = true;
                if streaming {
                    let _ = out.send(Message::DeviceKeyframe { device: device.clone() });
                }
            }
            Some(Input::Streaming(on)) => {
                streaming = on;
                if on {
                    waiting_for_keyframe = true;
                }
            }
            None => {}
        }
        // A reader keeps getting pictures at the device's rate when the phone pauses
        // (switching cameras, detached): the last one, or black.
        let quiet = last_new.elapsed() >= Duration::from_secs(1) || !attached;
        if streaming && quiet && last_written.elapsed() >= frame_time {
            write(&picture);
            last_written = Instant::now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn planar_420_converts_to_yuyv() {
        // 4x2 luma, 2x1 chroma.
        let y = [10, 20, 30, 40, 50, 60, 70, 80];
        let (u, v) = ([100, 110], [200, 210]);
        let p = Planes {
            width: 4,
            height: 2,
            y: &y,
            y_stride: 4,
            u: &u,
            v: &v,
            c_stride: 2,
            interleaved: false,
            full_range: false,
        };
        let mut out = Vec::new();
        to_yuyv(&p, Size { w: 4, h: 2 }, &mut out);
        assert_eq!(out, vec![10, 100, 20, 200, 30, 110, 40, 210, 50, 100, 60, 200, 70, 110, 80, 210]);
    }

    #[test]
    fn nv12_and_full_range_convert() {
        let y = [0, 255];
        let uv = [128, 255];
        let p = Planes {
            width: 2,
            height: 1,
            y: &y,
            y_stride: 2,
            u: &uv,
            v: &uv,
            c_stride: 2,
            interleaved: true,
            full_range: true,
        };
        let mut out = Vec::new();
        to_yuyv(&p, Size { w: 2, h: 1 }, &mut out);
        assert_eq!(out, vec![16, 128, 235, 239]);
    }

    #[test]
    fn a_larger_picture_is_scaled_down() {
        let y: Vec<u8> = (0..16).collect();
        let c = [128u8; 4];
        let p = Planes {
            width: 4,
            height: 4,
            y: &y,
            y_stride: 4,
            u: &c,
            v: &c,
            c_stride: 2,
            interleaved: false,
            full_range: false,
        };
        let mut out = Vec::new();
        to_yuyv(&p, Size { w: 2, h: 2 }, &mut out);
        assert_eq!(out, vec![0, 128, 2, 128, 8, 128, 10, 128]);
    }

    #[test]
    fn depth_is_scaled_by_nearest_neighbour() {
        let data: Vec<u8> = [1000u16, 2000, 3000, 4000].iter().flat_map(|d| d.to_le_bytes()).collect();
        let out = scale_depth(&data, Size { w: 2, h: 2 }, Size { w: 4, h: 2 });
        let got: Vec<u16> = out.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        assert_eq!(got, vec![1000, 1000, 2000, 2000, 3000, 3000, 4000, 4000]);
    }

    #[test]
    fn blank_pictures_are_black_and_empty() {
        let s = Size { w: 2, h: 1 };
        assert_eq!(Format::Yuyv.blank(s), vec![16, 128, 16, 128]);
        assert_eq!(Format::Z16.blank(s), vec![0; 4]);
    }
}
