//! One window's stream: when to render, when to encode, and what is in flight.
//!
//! The rules (docs/display.md, "Pacing and flow control"):
//! - a window is rendered only after it committed something (`dirty`), and a render
//!   with no damage costs nothing further;
//! - one picture per window is at the encoder at a time, and the newest content wins:
//!   commits that arrive meanwhile only leave the window dirty, so stale pictures are
//!   never queued or encoded;
//! - at most [`MAX_UNACKED`] encoded frames per window wait for the client's `ack`, and
//!   frame callbacks are held while the window is at that limit, so the application
//!   slows to what the link and the client can show;
//! - an encoder that refines says when its quiet areas are due (`refine_at_us`); a
//!   window that has not changed by then gets one more picture of the same content,
//!   sharper, under the same limits (a change first sharpens along the way);
//! - a scroll goes as a copy within the client's picture and tiles for what it does not
//!   reproduce, but only while the client shows exactly what the encoder last had: a
//!   window's `base` counts every event that could break that, and a copy needs the
//!   last picture sent to be of the current base and acknowledged.

use crate::encode::{Backend, CpuImage, Encoder, Input, Settings, ShmPicture};
use crate::motion;
use crate::render::Canvas;
use caboose_display_protocol::{Codec, Rect};
use smithay::reexports::calloop::channel::Sender;
use std::collections::VecDeque;
use std::time::Instant;

pub const MAX_UNACKED: usize = 2;

/// A picture for the worker to encode.
pub struct Job {
    pub window: u64,
    pub generation: u64,
    pub pts_us: u64,
    pub image: CpuImage,
    /// Read the picture from this client buffer instead of `image`.
    pub shm: Option<ShmPicture>,
    /// Look for passthrough video markers in the picture.
    pub detect: bool,
    pub keyframe: bool,
    /// Sharpen the previous picture instead of encoding `image` (which only travels
    /// back with the answer).
    pub refine: bool,
    /// What changed since the previous picture; `None` for everything.
    pub damage: Option<Vec<Rect>>,
    pub rect: Rect,
    pub crop: Rect,
    pub backend: Backend,
    pub settings: Settings,
    /// The window's motion region, encoded as its own stream and left out of the window
    /// picture.
    pub motion: Option<MotionJob>,
    /// This picture puts the region of the motion stream with this id back into the
    /// window picture (its damage covers the region); the stream ends with it.
    pub ends_motion: Option<u64>,
    /// The window's [`Stream::base`] when the job was made.
    pub base: u64,
    /// Try the update as a copy within the client's picture first; `None` when the client
    /// may not show what the encoder last had, or does not apply copies.
    pub copy: Option<CopyJob>,
}

pub struct CopyJob {
    /// Shifts the window was just scrolled by: picture pixels, as the content moves.
    pub hints: Vec<(i32, i32)>,
}

pub struct MotionJob {
    pub id: u64,
    /// Picture pixels, even.
    pub rect: Rect,
    pub keyframe: bool,
    pub scaled: bool,
}

/// Box-filter a motion crop to half resolution. Damage remains in source coordinates;
/// the small picture is rebuilt on each motion update so edge blocks cannot go stale.
fn half_motion(src: &[u8], stride: usize, width: usize, height: usize) -> Result<CpuImage, String> {
    if width == 0
        || height == 0
        || width % 4 != 0
        || height % 4 != 0
        || stride < width * 4
        || src.len() < (height - 1) * stride + width * 4
    {
        return Err("invalid motion crop".into());
    }
    let mut out = CpuImage::new((width / 2) as u32, (height / 2) as u32);
    for y in 0..height / 2 {
        for x in 0..width / 2 {
            for c in 0..4 {
                let i = y * 2 * stride + x * 8 + c;
                let sum = src[i] as u32 + src[i + 4] as u32 + src[i + stride] as u32 + src[i + stride + 4] as u32;
                out.data[y * out.stride + x * 4 + c] = ((sum + 2) / 4) as u8;
            }
        }
    }
    Ok(out)
}

fn scaled_motion(job: &Job, rect: Rect) -> Result<CpuImage, String> {
    let (x, y, w, h) = (rect.x as usize, rect.y as usize, rect.w as usize, rect.h as usize);
    if rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0 {
        return Err("invalid motion crop".into());
    }
    match &job.shm {
        None => {
            if x + w > job.image.width as usize || y + h > job.image.height as usize {
                return Err("motion crop outside image".into());
            }
            half_motion(&job.image.data[y * job.image.stride + x * 4..], job.image.stride, w, h)
        }
        Some(shm) => smithay::wayland::shm::with_buffer_contents(&shm.buffer, |ptr, len, data| {
            let sx = shm.x as i64 + rect.x as i64;
            let sy = shm.y as i64 + rect.y as i64;
            if sx < 0
                || sy < 0
                || sx + rect.w as i64 > data.width as i64
                || sy + rect.h as i64 > data.height as i64
                || data.stride <= 0
                || data.offset < 0
            {
                return Err("motion crop outside shm".into());
            }
            let start = data.offset as usize + sy as usize * data.stride as usize + sx as usize * 4;
            if start > len {
                return Err("motion crop outside shm pool".into());
            }
            // SAFETY: Smithay maps the pool for the duration of this closure.
            let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
            half_motion(&bytes[start..], data.stride as usize, w, h)
        })
        .map_err(|e| format!("shm buffer: {e:?}"))?,
    }
}

/// The worker's answer: the encoded pictures (or why not) and the image back for reuse.
pub struct Done {
    /// Markers found in the picture (when the job asked), picture pixels.
    pub hits: Option<Vec<crate::video::marker::Hit>>,
    pub window: u64,
    pub generation: u64,
    pub pts_us: u64,
    pub image: CpuImage,
    /// The window picture; `None` when nothing changed outside the motion region.
    pub result: Option<Result<Encoded, String>>,
    pub rect: Rect,
    pub crop: Rect,
    /// What really changed, window and motion region together (picture pixels).
    pub changed: Vec<Rect>,
    /// The motion region's picture, when it changed.
    pub motion: Option<(u64, Result<Encoded, String>)>,
    pub ends_motion: Option<u64>,
    /// Small changes sent as lossless tiles instead of a window picture.
    pub tiles: Option<TilesDone>,
    /// A scroll sent as a copy and tiles instead of a window picture.
    pub copy: Option<CopyDone>,
    /// As in [`Job`].
    pub base: u64,
}

pub struct CopyDone {
    /// Picture pixels to copy, and where their top-left pixel lands.
    pub src: Rect,
    pub dst: [i32; 2],
    /// The tiles that follow the copy: picture pixels, and the PNG.
    pub tiles: Vec<(Rect, Vec<u8>)>,
    pub refine_in_ms: Option<u64>,
    pub cpu_us: u64,
}

pub struct TilesDone {
    /// Picture pixels, and the PNG.
    pub tiles: Vec<(Rect, Vec<u8>)>,
    pub refine_in_ms: Option<u64>,
    pub cpu_us: u64,
}

/// An RGB rectangle as a PNG, compressed for speed.
pub(crate) fn png(w: u32, h: u32, rgb: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(rgb.len() / 4 + 64);
    let mut encoder = png::Encoder::new(&mut out, w, h);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    encoder.write_header().and_then(|mut w| w.write_image_data(rgb)).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Markers in a job's picture, wherever its pixels are.
fn detect(job: &Job) -> Vec<crate::video::marker::Hit> {
    use crate::video::marker::detect_bgrx;
    let (w, h) = (job.crop.w.max(0) as usize, job.crop.h.max(0) as usize);
    match &job.shm {
        None => detect_bgrx(&job.image.data, job.image.stride, w, h, 8),
        Some(shm) => smithay::wayland::shm::with_buffer_contents(&shm.buffer, |ptr, len, data| {
            let stride = data.stride as usize;
            let start = data.offset as usize + shm.y as usize * stride + shm.x as usize * 4;
            if start + (h.saturating_sub(1)) * stride + w * 4 > len {
                return Vec::new();
            }
            // SAFETY: with_buffer_contents maps `len` bytes of the pool for this closure.
            let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
            detect_bgrx(&pool[start..], stride, w, h, 8)
        })
        .unwrap_or_default(),
    }
}

pub struct Encoded {
    pub codec: Codec,
    pub keyframe: bool,
    pub data: Vec<u8>,
    /// Time in the encoder, microseconds.
    pub encode_us: u64,
    /// Thread CPU time spent on this picture, microseconds.
    pub cpu_us: u64,
    /// When to sharpen next if nothing changes, in milliseconds from now.
    pub refine_in_ms: Option<u64>,
    /// The picture sharpened the previous one.
    pub refined: bool,
}

struct Worker {
    tx: std::sync::mpsc::Sender<Job>,
}

fn thread_cpu_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes the timespec it is given.
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000
}

/// What a worker keeps between jobs.
#[derive(Default)]
struct Encoders {
    window: Option<(Backend, Box<dyn Encoder>)>,
    /// For the motion stream with this id, at this rectangle.
    motion: Option<(u64, Rect, Box<dyn Encoder>)>,
}

/// Encodes with `enc`, timing it.
fn encode_with(
    enc: &mut dyn Encoder,
    input: Input<'_>,
    keyframe: bool,
    damage: Option<&[Rect]>,
    refine: bool,
) -> (Result<Encoded, String>, Option<Vec<Rect>>) {
    let cpu0 = thread_cpu_us();
    let start = Instant::now();
    let result = if refine { enc.refine() } else { enc.encode(input, keyframe, damage) };
    match result {
        Ok(p) => (
            Ok(Encoded {
                codec: enc.codec(),
                keyframe: p.keyframe,
                data: p.data,
                encode_us: start.elapsed().as_micros() as u64,
                cpu_us: thread_cpu_us().saturating_sub(cpu0),
                refine_in_ms: p.refine_in_ms,
                refined: refine,
            }),
            p.changed,
        ),
        Err(e) => (Err(e.to_string()), None),
    }
}

fn work(job: Job, encoders: &mut Encoders) -> Done {
    let size = (job.image.width, job.image.height);
    let reuse = encoders.window.as_ref().is_some_and(|(b, e)| *b == job.backend && e.coded_size() == size);
    let mut done = Done {
        hits: None,
        window: job.window,
        generation: job.generation,
        pts_us: job.pts_us,
        image: CpuImage::new(0, 0),
        result: None,
        rect: job.rect,
        crop: job.crop,
        changed: Vec::new(),
        motion: None,
        ends_motion: job.ends_motion,
        tiles: None,
        copy: None,
        base: job.base,
    };
    if job.refine && !reuse {
        // The encoder whose picture this sharpens is gone; the window starts over with
        // a keyframe.
        done.result = Some(Err("no picture to refine".into()));
        done.image = job.image;
        return done;
    }
    let mut fresh = false;
    if !reuse {
        match job.backend.create(size.0, size.1, &job.settings) {
            Ok(e) => encoders.window = Some((job.backend.clone(), e)),
            Err(e) => {
                encoders.window = None;
                done.result = Some(Err(format!("cannot open {}: {e}", job.backend.describe())));
                done.image = job.image;
                return done;
            }
        }
        fresh = true;
    }
    done.hits = job.detect.then(|| detect(&job));
    if !job.refine {
        encoders.window.as_mut().unwrap().1.exclude(job.motion.as_ref().map(|m| m.rect));
    }
    let keyframe = job.keyframe || fresh;
    let damage = if fresh { None } else { job.damage.clone() };
    let full = Rect::new(0, 0, size.0 as i32, size.1 as i32);
    // With a motion region, the window picture leaves it out, and the region is its own
    // picture (in its own coordinates).
    let (window_damage, motion_damage) = match &job.motion {
        None => (damage, None),
        Some(m) => {
            let all = damage.unwrap_or_else(|| vec![full]);
            let window = all.iter().flat_map(|r| motion::subtract(*r, m.rect)).collect();
            let region = all
                .iter()
                .filter_map(|r| motion::intersect(*r, m.rect))
                .map(|r| Rect::new(r.x - m.rect.x, r.y - m.rect.y, r.w, r.h))
                .collect::<Vec<_>>();
            (Some(window), Some(region))
        }
    };
    let mut window_needed = job.refine || keyframe || window_damage.as_ref().is_none_or(|d| !d.is_empty());
    let mut tiles_allowed = true;
    // A scroll goes as a copy within the client's picture and tiles for what the copy does
    // not reproduce. Not with a motion region: the encoder's record holds frozen pixels
    // under it that the client does not show.
    if let (Some(copy), true, false, false, None, None, Some(d)) =
        (&job.copy, window_needed, job.refine, keyframe, job.ends_motion, &job.motion, window_damage.as_ref())
    {
        let cpu0 = thread_cpu_us();
        let (_, enc) = encoders.window.as_mut().unwrap();
        let input = match &job.shm {
            Some(shm) => Input::Shm(shm),
            None => Input::Cpu(&job.image),
        };
        match enc.copy(input, d, &copy.hints) {
            Ok(Some(c)) => {
                let tiles: Result<Vec<_>, String> =
                    c.tiles.iter().map(|(r, rgb)| png(r.w as u32, r.h as u32, rgb).map(|p| (*r, p))).collect();
                match tiles {
                    Ok(tiles) => {
                        done.changed = c.changed;
                        done.copy = Some(CopyDone {
                            src: c.src,
                            dst: c.dst,
                            tiles,
                            refine_in_ms: c.refine_in_ms,
                            cpu_us: thread_cpu_us().saturating_sub(cpu0),
                        });
                        window_needed = false;
                    }
                    // The new pixels are in the shadow and marked for the next picture, which
                    // goes now; tiles would find nothing left to send.
                    Err(e) => {
                        tracing::warn!("window {}: copy tile: {e}; sending a picture", job.window);
                        tiles_allowed = false;
                    }
                }
            }
            Ok(None) => {}
            Err(e) => tracing::warn!("window {}: copy: {e}", job.window),
        }
    }
    // A small change goes as tiles: a few lossless PNGs cost far less than coding the
    // whole picture. Not for a picture that ends a motion stream: the client keeps the
    // stream until a frame repaints its region.
    let tile_max_px = job.settings.tile_max_px;
    if let (true, false, false, None, Some(d)) = (
        window_needed && tiles_allowed && tile_max_px > 0,
        job.refine,
        keyframe,
        job.ends_motion,
        window_damage.as_ref(),
    ) {
        let cpu0 = thread_cpu_us();
        let (_, enc) = encoders.window.as_mut().unwrap();
        let input = match &job.shm {
            Some(shm) => Input::Shm(shm),
            None => Input::Cpu(&job.image),
        };
        match enc.tiles(input, d, tile_max_px) {
            Ok(Some(t)) => {
                let tiles: Result<Vec<_>, String> =
                    t.tiles.iter().map(|(r, rgb)| png(r.w as u32, r.h as u32, rgb).map(|p| (*r, p))).collect();
                match tiles {
                    Ok(tiles) => {
                        done.changed = tiles.iter().map(|(r, _)| *r).collect();
                        done.tiles = Some(TilesDone {
                            tiles,
                            refine_in_ms: t.refine_in_ms,
                            cpu_us: thread_cpu_us().saturating_sub(cpu0),
                        });
                        window_needed = false;
                    }
                    // The pixels are in the shadow and marked for the next picture.
                    Err(e) => tracing::warn!("window {}: tile: {e}; sending a picture", job.window),
                }
            }
            Ok(None) => {}
            Err(e) => tracing::warn!("window {}: tiles: {e}", job.window),
        }
    }
    if window_needed {
        let (_, enc) = encoders.window.as_mut().unwrap();
        let input = match &job.shm {
            Some(shm) => Input::Shm(shm),
            None => Input::Cpu(&job.image),
        };
        let (result, changed) = encode_with(enc.as_mut(), input, keyframe, window_damage.as_deref(), job.refine);
        if result.is_err() {
            encoders.window = None; // start clean (and with a keyframe) next time
        } else if !job.refine {
            done.changed = changed.or(window_damage).unwrap_or_else(|| vec![full]);
        }
        done.result = Some(result);
    }
    match &job.motion {
        None if !job.refine => encoders.motion = None,
        None => {}
        Some(m) => {
            let matches = encoders.motion.as_ref().is_some_and(|(id, r, _)| *id == m.id && *r == m.rect);
            let mut motion_fresh = false;
            if !matches {
                // Sharpening is for still pictures; video is never still long enough.
                let settings = Settings { refine_qp: 0, ..job.settings.clone() };
                let divisor = if m.scaled { 2 } else { 1 };
                encoders.motion =
                    match job.backend.create(m.rect.w as u32 / divisor, m.rect.h as u32 / divisor, &settings) {
                        Ok(e) => Some((m.id, m.rect, e)),
                        Err(e) => {
                            done.motion = Some((m.id, Err(format!("cannot open {}: {e}", job.backend.describe()))));
                            None
                        }
                    };
                motion_fresh = true;
            }
            let motion_key = m.keyframe || motion_fresh;
            let region_damage = motion_damage.unwrap_or_default();
            if let Some((_, _, enc)) = encoders.motion.as_mut().filter(|_| motion_key || !region_damage.is_empty()) {
                let shm = job.shm.as_ref().map(|s| ShmPicture {
                    buffer: s.buffer.clone(),
                    x: s.x + m.rect.x,
                    y: s.y + m.rect.y,
                });
                let scaled = if m.scaled {
                    match scaled_motion(&job, m.rect) {
                        Ok(image) => Some(image),
                        Err(e) => {
                            done.motion = Some((m.id, Err(e)));
                            encoders.motion = None;
                            done.image = job.image;
                            return done;
                        }
                    }
                } else {
                    None
                };
                let input = match (&scaled, &shm) {
                    (Some(image), _) => Input::Cpu(image),
                    (None, Some(shm)) => Input::Shm(shm),
                    (None, None) => Input::CpuAt(&job.image, m.rect.x as u32, m.rect.y as u32),
                };
                let damage = (!motion_key && !m.scaled).then_some(region_damage.as_slice());
                let (result, changed) = encode_with(enc.as_mut(), input, motion_key, damage, false);
                if result.is_err() {
                    encoders.motion = None;
                } else {
                    let changed = if m.scaled {
                        region_damage.clone()
                    } else {
                        changed.unwrap_or_else(|| {
                            damage.map_or_else(|| vec![Rect::new(0, 0, m.rect.w, m.rect.h)], <[Rect]>::to_vec)
                        })
                    };
                    done.changed.extend(changed.iter().map(|r| Rect::new(r.x + m.rect.x, r.y + m.rect.y, r.w, r.h)));
                }
                done.motion = Some((m.id, result));
            }
        }
    }
    done.image = job.image;
    done
}

impl Worker {
    fn spawn(window: u64, done: Sender<Done>) -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name(format!("encode-{window}"))
            .spawn(move || {
                let mut encoders = Encoders::default();
                let mut refining = false;
                loop {
                    let job = match rx.recv_timeout(std::time::Duration::from_secs(10)) {
                        Ok(job) => job,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            if !refining {
                                encoders = Encoders::default();
                            }
                            continue;
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let result = work(job, &mut encoders);
                    if let Some(ref tiles) = result.tiles {
                        refining = tiles.refine_in_ms.is_some();
                    } else if let Some(ref copy) = result.copy {
                        refining = copy.refine_in_ms.is_some();
                    } else if let Some(ref picture) = result.result {
                        refining = picture.as_ref().ok().is_some_and(|p| p.refine_in_ms.is_some());
                    }
                    if done.send(result).is_err() {
                        break;
                    }
                }
            })
            .expect("spawn encoder thread");
        Self { tx }
    }
}

#[derive(Default)]
pub struct Stream {
    pub canvas: Option<Canvas>,
    /// Set while the window is streamed straight from its shm buffer (render::direct).
    pub direct: Option<crate::render::DirectState>,
    /// The picture buffer; `None` while the worker has it.
    pub image: Option<CpuImage>,
    image_id: u64,
    /// The window committed since its last picture.
    pub dirty: bool,
    /// Monotonic microseconds of the newest unrendered commit.
    pub commit_us: u64,
    /// The last pts sent; pts strictly increase per window.
    pub last_pts: u64,
    pub need_keyframe: bool,
    /// A picture is at the encoder.
    pub encoding: bool,
    /// pts of frames sent and not yet acknowledged.
    pub in_flight: VecDeque<u64>,
    worker: Option<Worker>,
    /// Frame callbacks are waiting for the next vsync.
    pub callbacks_pending: bool,
    /// Monotonic microseconds when the encoder has quiet areas to sharpen.
    pub refine_at_us: Option<u64>,
    /// The visible part of the last picture submitted.
    pub crop: Rect,
    /// Window-pixel placement of the last submitted picture.
    pub rect: Rect,
    /// The window's motion region and its stream, while it has one.
    pub motion: Option<MotionStream>,
    /// Watches for a motion region, at the picture size it was made for.
    pub tracker: Option<motion::Tracker>,
    /// Counts the bases of the client's picture: bumped by everything after which the
    /// client may not show what the encoder last had (a dropped or failed picture, a decode
    /// failure or keyframe request, a keyframe, a new client, a change of size, crop or
    /// scale, a motion stream starting or ending).
    pub base: u64,
    /// The base of the last picture sent; copies need it to be the current one.
    pub shown_base: Option<u64>,
    /// Pointer scrolls delivered to the window: monotonic µs, and the content's movement
    /// in window pixels.
    pub scrolls: VecDeque<(u64, f64, f64)>,
    /// Monotonic µs of the last input that can scroll the window (a pointer scroll or a
    /// touch drag).
    pub scrolled_us: u64,
    /// The last update went as a copy: a scroll is under way, kinetic or not.
    pub copying: bool,
}

/// Scroll hints and scroll input count for this long.
pub const SCROLL_WINDOW_US: u64 = 1_000_000;

/// A `motion` video stream: a region of the window sent as its own video.
pub struct MotionStream {
    pub id: u64,
    /// Picture pixels.
    pub rect: Rect,
    pub next_seq: u64,
    /// seq of frames sent and not yet acknowledged (`video.ack`).
    pub in_flight: VecDeque<u64>,
    pub need_keyframe: bool,
    /// The next picture puts the region back into the window picture.
    pub ending: bool,
    pub scaled: bool,
}

impl Stream {
    /// Retire only after a successful base frame has restored the region. Keeping
    /// the stream here also keeps failed repaint attempts retryable.
    pub fn end_motion(&mut self) {
        if let Some(m) = self.motion.as_mut() {
            m.ending = true;
            self.dirty = true;
            self.new_base();
        }
    }

    /// The client may stop showing what the encoder last had: no copies until a picture
    /// made after this is sent.
    pub fn new_base(&mut self) {
        self.base += 1;
    }

    /// A picture made on `base` was sent.
    pub fn shown(&mut self, base: u64) {
        if base == self.base {
            self.shown_base = Some(base);
        }
    }

    /// Whether the client shows exactly what the encoder last had, so an update can be a
    /// copy of it: the last picture sent was made on the current base, every picture sent
    /// has been acknowledged as decoded, and there is no motion region (the encoder keeps
    /// frozen pixels under it) and no keyframe due.
    pub fn copy_ready(&self) -> bool {
        self.shown_base == Some(self.base) && self.in_flight.is_empty() && self.motion.is_none() && !self.need_keyframe
    }

    /// A pointer scroll was delivered: `dx`, `dy` as the content moves, in window pixels.
    pub fn scrolled(&mut self, now_us: u64, dx: f64, dy: f64) {
        self.scrolled_us = now_us;
        while self.scrolls.front().is_some_and(|s| now_us.saturating_sub(s.0) > SCROLL_WINDOW_US)
            || self.scrolls.len() >= 8
        {
            self.scrolls.pop_front();
        }
        self.scrolls.push_back((now_us, dx, dy));
    }

    /// Whether to look for a copy: the window was just scrolled or touched, or its last
    /// update was a copy.
    pub fn scrolling(&self, now_us: u64) -> bool {
        self.copying || now_us.saturating_sub(self.scrolled_us) < SCROLL_WINDOW_US
    }

    /// Shifts to try, in picture pixels (`scale` = picture pixels per window pixel): the
    /// latest recent scroll and all of them together.
    pub fn scroll_hints(&self, now_us: u64, scale: (f64, f64)) -> Vec<(i32, i32)> {
        let recent: Vec<_> = self.scrolls.iter().filter(|s| now_us.saturating_sub(s.0) <= SCROLL_WINDOW_US).collect();
        let shift = |dx: f64, dy: f64| ((dx * scale.0).round() as i32, (dy * scale.1).round() as i32);
        let mut hints = Vec::new();
        if let Some(last) = recent.last() {
            hints.push(shift(last.1, last.2));
        }
        let sum = recent.iter().fold((0.0, 0.0), |a, s| (a.0 + s.1, a.1 + s.2));
        let sum = shift(sum.0, sum.1);
        if !hints.contains(&sum) {
            hints.push(sum);
        }
        hints.retain(|&h| h != (0, 0));
        hints
    }

    pub fn motion_repainted(&mut self, id: u64, sent: bool) -> bool {
        if !self.motion.as_ref().is_some_and(|m| m.id == id && m.ending) {
            return false;
        }
        if sent {
            self.motion = None;
            true
        } else {
            self.dirty = true;
            self.need_keyframe = true;
            false
        }
    }

    pub fn mark_dirty(&mut self, now_us: u64) {
        self.commit_us = now_us;
        self.dirty = true;
        self.callbacks_pending = true;
    }

    /// The pts for the picture rendered now: the newest commit's time, kept strictly
    /// increasing.
    pub fn next_pts(&mut self) -> u64 {
        let pts = self.commit_us.max(self.last_pts + 1);
        self.last_pts = pts;
        pts
    }

    /// A sharper picture of unchanged content is due: the window is quiet, the encoder
    /// said so, and flow control has room.
    pub fn refine_due(&self, now_us: u64) -> bool {
        !self.dirty && self.can_send() && self.image.is_some() && self.refine_at_us.is_some_and(|t| t <= now_us)
    }

    /// The pts for a sharpened picture: its content is from earlier, its pixels now.
    pub fn refine_pts(&mut self, now_us: u64) -> u64 {
        let pts = now_us.max(self.last_pts + 1);
        self.last_pts = pts;
        pts
    }

    /// Room for another picture under the flow-control limit (of the window stream and
    /// of its motion stream).
    pub fn can_send(&self) -> bool {
        !self.encoding && self.in_flight.len() < MAX_UNACKED && self.motion_in_flight() < MAX_UNACKED
    }

    /// Whether frame callbacks may be released now.
    pub fn can_release_callbacks(&self) -> bool {
        self.in_flight.len().max(self.motion_in_flight()) + (self.encoding as usize) < MAX_UNACKED
    }

    fn motion_in_flight(&self) -> usize {
        self.motion.as_ref().map_or(0, |m| m.in_flight.len())
    }

    /// A `video.ack` for the motion stream `id`.
    pub fn ack_motion(&mut self, id: u64, seq: u64) -> bool {
        let Some(m) = self.motion.as_mut().filter(|m| m.id == id) else { return false };
        match m.in_flight.iter().position(|s| *s == seq) {
            Some(i) => {
                m.in_flight.drain(..=i);
                true
            }
            None => false,
        }
    }

    pub fn ack(&mut self, pts_us: u64) -> bool {
        if let Some(i) = self.in_flight.iter().position(|p| *p == pts_us) {
            // Frames are acknowledged in order; an ack also covers anything older.
            self.in_flight.drain(..=i);
            true
        } else {
            false
        }
    }

    /// Forgets everything about the current client: in-flight frames, the encoder.
    pub fn reset_for_client(&mut self) {
        self.in_flight.clear();
        self.need_keyframe = true;
        self.dirty = true;
        // A picture still at the old worker is dropped when it comes back (its
        // generation is stale); the new client gets a new worker and image.
        self.encoding = false;
        self.worker = None;
        self.refine_at_us = None;
        // That client's motion stream is gone with it; the next one finds its own.
        self.motion = None;
        self.tracker = None;
        self.new_base();
        self.shown_base = None;
        self.copying = false;
    }

    /// Takes (or makes) a picture buffer of the coded size. A new buffer has no history,
    /// so the canvas redraws it fully.
    pub fn take_image(&mut self, width: u32, height: u32) -> (CpuImage, u64) {
        match self.image.take() {
            Some(img) if img.width == width && img.height == height => (img, self.image_id),
            _ => {
                self.image_id += 1;
                (CpuImage::new(width, height), self.image_id)
            }
        }
    }

    pub fn return_image(&mut self, image: CpuImage) {
        self.image = Some(image);
    }

    pub fn submit(&mut self, job: Job, done: &Sender<Done>) {
        let window = job.window;
        let worker = self.worker.get_or_insert_with(|| Worker::spawn(window, done.clone()));
        self.encoding = true;
        if !job.refine {
            self.dirty = false;
            self.need_keyframe = false;
        }
        if let Some(m) = self.motion.as_mut().filter(|_| job.motion.is_some()) {
            m.need_keyframe = false;
        }
        // The answer says when to sharpen next.
        self.refine_at_us = None;
        self.crop = job.crop;
        self.rect = job.rect;
        if let Err(e) = worker.tx.send(job) {
            // The worker exited; recover the image and try again on the next tick.
            self.worker = None;
            self.encoding = false;
            self.dirty = true;
            self.image = Some(e.0.image);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_motion_averages_two_by_two_with_padded_rows() {
        let mut pixels = vec![0; 24 * 4];
        for y in 0..4 {
            for x in 0..4 {
                pixels[y * 24 + x * 4] = (y * 10 + x) as u8;
            }
        }
        let out = half_motion(&pixels, 24, 4, 4).unwrap();
        assert_eq!((out.width, out.height), (2, 2));
        assert_eq!([out.data[0], out.data[4], out.data[8], out.data[12]], [6, 8, 26, 28]);
        assert!(half_motion(&pixels[..20], 24, 4, 4).is_err());
        assert!(half_motion(&pixels, 24, 3, 4).is_err());
    }

    #[test]
    fn motion_retirement_waits_for_a_successful_repaint() {
        let mut s = Stream {
            motion: Some(MotionStream {
                id: 7,
                rect: Rect::new(0, 0, 16, 16),
                next_seq: 0,
                in_flight: Default::default(),
                need_keyframe: false,
                ending: false,
                scaled: false,
            }),
            ..Default::default()
        };
        s.end_motion();
        assert!(s.dirty && s.motion.as_ref().unwrap().ending);
        assert!(!s.motion_repainted(8, true), "another stream cannot retire this one");
        s.dirty = false;
        assert!(!s.motion_repainted(7, false));
        assert!(s.motion.is_some() && s.dirty && s.need_keyframe, "failed repaint must retry");
        assert!(s.motion_repainted(7, true));
        assert!(s.motion.is_none());
    }

    #[test]
    fn refining_the_base_preserves_the_motion_encoder_and_its_reference_frames() {
        ffmpeg_next::init().unwrap();
        let mut encoders = Encoders::default();
        let job = |image, motion, refine| Job {
            window: 1,
            generation: 1,
            pts_us: 1,
            image,
            shm: None,
            detect: false,
            keyframe: false,
            refine,
            damage: None,
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_after_ms: 0, tile_max_px: 0, ..Settings::default() },
            motion,
            ends_motion: None,
            base: 0,
            copy: None,
        };
        let motion = || Some(MotionJob { id: 7, rect: Rect::new(32, 16, 64, 64), keyframe: false, scaled: false });
        let first = work(job(CpuImage::new(128, 96), motion(), false), &mut encoders);
        assert!(first.motion.unwrap().1.unwrap().keyframe);
        let sharp = work(job(first.image, None, true), &mut encoders);
        assert!(sharp.result.unwrap().is_ok());
        assert!(sharp.motion.is_none());
        assert!(encoders.motion.is_some(), "refinement is not stream cessation");
        let next = work(job(sharp.image, motion(), false), &mut encoders);
        assert!(!next.motion.unwrap().1.unwrap().keyframe, "motion references survive base refinement");
    }

    #[test]
    fn recreated_encoders_start_both_streams_with_keyframes() {
        ffmpeg_next::init().unwrap();
        let mut encoders = Encoders::default();
        let job = |image| Job {
            window: 1,
            generation: 1,
            pts_us: 1,
            image,
            shm: None,
            detect: false,
            keyframe: false,
            refine: false,
            damage: Some(vec![Rect::new(0, 0, 16, 16)]),
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_qp: 0, tile_max_px: 0, ..Settings::default() },
            motion: Some(MotionJob { id: 7, rect: Rect::new(32, 16, 64, 64), keyframe: false, scaled: false }),
            ends_motion: None,
            base: 0,
            copy: None,
        };
        let first = work(job(CpuImage::new(128, 96)), &mut encoders);
        assert!(first.result.unwrap().unwrap().keyframe);
        assert!(first.motion.unwrap().1.unwrap().keyframe);
        encoders = Encoders::default(); // idle eviction
        let next = work(job(first.image), &mut encoders);
        assert!(next.result.unwrap().unwrap().keyframe);
        assert!(next.motion.unwrap().1.unwrap().keyframe);
    }

    #[test]
    fn scaled_motion_encodes_half_size_and_keeps_damage_in_window_coordinates() {
        ffmpeg_next::init().unwrap();
        let mut encoders = Encoders::default();
        let job = |image, damage| Job {
            window: 1,
            generation: 1,
            pts_us: 1,
            image,
            shm: None,
            detect: false,
            keyframe: false,
            refine: false,
            damage,
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_qp: 0, tile_max_px: 0, ..Settings::default() },
            motion: Some(MotionJob { id: 7, rect: Rect::new(32, 16, 64, 64), keyframe: false, scaled: true }),
            ends_motion: None,
            base: 0,
            copy: None,
        };
        let done = work(job(CpuImage::new(128, 96), None), &mut encoders);
        let picture = done.motion.unwrap().1.unwrap();
        assert!(picture.keyframe);
        let codec = ffmpeg_next::decoder::find(ffmpeg_next::codec::Id::H264).unwrap();
        let mut decoder = ffmpeg_next::codec::context::Context::new_with_codec(codec).decoder().video().unwrap();
        decoder.send_packet(&ffmpeg_next::Packet::copy(&picture.data)).unwrap();
        let mut frame = ffmpeg_next::frame::Video::empty();
        decoder.receive_frame(&mut frame).unwrap();
        assert_eq!((frame.width(), frame.height()), (32, 32));
        assert!(done.changed.contains(&Rect::new(32, 16, 64, 64)));
        let mut image = done.image;
        for y in 20..24 {
            for x in 36..40 {
                image.data[y * image.stride + x * 4] = 255;
            }
        }
        let next = work(job(image, Some(vec![Rect::new(36, 20, 4, 4)])), &mut encoders);
        assert!(next.changed.contains(&Rect::new(36, 20, 4, 4)));
        let picture = next.motion.unwrap().1.unwrap();
        assert!(!picture.keyframe);
        decoder.send_packet(&ffmpeg_next::Packet::copy(&picture.data)).unwrap();
        let mut frame = ffmpeg_next::frame::Video::empty();
        decoder.receive_frame(&mut frame).unwrap();
        assert_eq!((frame.width(), frame.height()), (32, 32));
    }

    #[test]
    fn a_scroll_goes_as_a_copy_only_when_the_job_allows_it() {
        ffmpeg_next::init().unwrap();
        let mut encoders = Encoders::default();
        let (w, h) = (256i32, 512i32);
        let job = |image, keyframe, copy: bool| Job {
            window: 1,
            generation: 1,
            pts_us: 1,
            image,
            shm: None,
            detect: false,
            keyframe,
            refine: false,
            damage: Some(vec![Rect::new(0, 0, w, h)]),
            rect: Rect::new(0, 0, w, h),
            crop: Rect::new(0, 0, w, h),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_qp: 0, ..Settings::default() },
            motion: None,
            ends_motion: None,
            base: 1,
            copy: copy.then(|| CopyJob { hints: Vec::new() }),
        };
        // Noise: every row is its own.
        let mut image = CpuImage::new(w as u32, h as u32);
        for y in 0..h as usize {
            for x in 0..w as usize {
                let z = ((y as u64) << 32 | x as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
                let z = z ^ (z >> 29);
                image.data[y * image.stride + x * 4..][..4].copy_from_slice(&[
                    z as u8,
                    (z >> 8) as u8,
                    (z >> 16) as u8,
                    0,
                ]);
            }
        }
        let first = work(job(image, true, true), &mut encoders);
        assert!(first.copy.is_none() && first.result.unwrap().unwrap().keyframe, "a keyframe is never a copy");
        let mut image = first.image;
        image.data.rotate_left(image.stride * 18);
        let done = work(job(image, false, true), &mut encoders);
        assert!(done.result.is_none() && done.tiles.is_none());
        let copy = done.copy.expect("a copy");
        assert_eq!((copy.src, copy.dst), (Rect::new(0, 18, w, h - 18), [0, 0]));
        assert!(!copy.tiles.is_empty() && copy.tiles.iter().all(|(_, png)| png.starts_with(b"\x89PNG")));
        assert!(done.changed.contains(&Rect::new(0, 0, w, 496)));
        // Without the job's leave, the same kind of scroll is a picture.
        let mut image = done.image;
        image.data.rotate_left(image.stride * 18);
        let done = work(job(image, false, false), &mut encoders);
        assert!(done.copy.is_none() && done.result.unwrap().is_ok());
    }

    #[test]
    fn copies_wait_for_a_shown_and_acknowledged_base() {
        let mut s = Stream::default();
        assert!(!s.copy_ready(), "nothing shown yet");
        // A keyframe starts a base; its picture is sent, then acknowledged.
        s.new_base();
        let keyframe = s.base;
        s.in_flight.push_back(10);
        s.shown(keyframe);
        assert!(!s.copy_ready(), "the picture is not acknowledged yet");
        assert!(s.ack(10));
        assert!(s.copy_ready());
        // A decode failure (or anything else that starts a base): a picture made before it
        // does not restore copies, one made after it does.
        s.new_base();
        s.shown(keyframe);
        assert!(!s.copy_ready());
        s.shown(s.base);
        assert!(s.copy_ready());
        s.need_keyframe = true;
        assert!(!s.copy_ready());
        s.need_keyframe = false;
        s.motion = Some(MotionStream {
            id: 7,
            rect: Rect::new(0, 0, 16, 16),
            next_seq: 0,
            in_flight: Default::default(),
            need_keyframe: false,
            ending: false,
            scaled: false,
        });
        assert!(!s.copy_ready(), "the encoder keeps frozen pixels under a motion region");
        s.end_motion();
        s.motion = None;
        assert!(!s.copy_ready(), "the repaint that ends a motion stream starts a base");
        s.shown(s.base);
        assert!(s.copy_ready());
        s.reset_for_client();
        s.need_keyframe = false;
        assert!(!s.copy_ready(), "a new client has been shown nothing");
    }

    #[test]
    fn scroll_hints_are_the_latest_scroll_and_the_sum_in_picture_pixels() {
        let mut s = Stream::default();
        assert!(!s.scrolling(5_000_000));
        s.scrolled(1_000_000, 0.0, -10.0);
        s.scrolled(1_100_000, 0.0, -8.0);
        assert!(s.scrolling(1_500_000));
        assert_eq!(s.scroll_hints(1_200_000, (1.0, 1.0)), vec![(0, -8), (0, -18)]);
        assert_eq!(s.scroll_hints(1_200_000, (2.0, 2.0)), vec![(0, -16), (0, -36)]);
        assert!(s.scroll_hints(3_000_000, (1.0, 1.0)).is_empty());
        assert!(!s.scrolling(3_000_000));
        s.copying = true;
        assert!(s.scrolling(3_000_000), "a scroll that goes on after the input");
    }

    #[test]
    fn acks_release_in_order_and_ignore_unknown_pts() {
        let mut s = Stream::default();
        s.in_flight.extend([10, 20]);
        assert!(!s.can_send());
        assert!(!s.ack(15));
        assert!(s.ack(20));
        assert!(s.in_flight.is_empty() && s.can_send());
    }

    #[test]
    fn callbacks_wait_while_at_the_limit() {
        let mut s = Stream { encoding: true, ..Default::default() };
        s.in_flight.push_back(1);
        assert!(!s.can_release_callbacks());
        s.encoding = false;
        assert!(s.can_release_callbacks());
    }

    #[test]
    fn refinement_waits_for_its_time_a_quiet_window_and_room() {
        let mut s = Stream { image: Some(CpuImage::new(2, 2)), refine_at_us: Some(1000), ..Default::default() };
        assert!(!s.refine_due(999));
        assert!(s.refine_due(1000));
        s.mark_dirty(1000);
        assert!(!s.refine_due(2000));
        s.dirty = false;
        s.in_flight.extend([1, 2]);
        assert!(!s.refine_due(2000));
        s.in_flight.clear();
        s.reset_for_client();
        assert!(!s.refine_due(2000));
    }

    #[test]
    fn a_motion_stream_shares_the_flow_control() {
        let mut s = Stream {
            motion: Some(MotionStream {
                id: 7,
                rect: Rect::new(0, 0, 16, 16),
                next_seq: 2,
                in_flight: [0, 1].into(),
                need_keyframe: false,
                ending: false,
                scaled: false,
            }),
            ..Default::default()
        };
        assert!(!s.can_send() && !s.can_release_callbacks());
        assert!(!s.ack_motion(8, 1), "another stream's ack");
        assert!(s.ack_motion(7, 0));
        assert!(s.can_send() && s.can_release_callbacks());
        s.reset_for_client();
        assert!(s.motion.is_none());
    }

    #[test]
    fn pts_follow_the_newest_commit_and_never_repeat() {
        let mut s = Stream::default();
        s.mark_dirty(100);
        s.mark_dirty(200);
        assert_eq!(s.next_pts(), 200);
        s.mark_dirty(200);
        assert_eq!(s.next_pts(), 201);
    }
}
