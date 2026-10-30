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
//! - an alpha window (a popup) is sent only as RGBA tiles, under the same flow control,
//!   and has no encoder, sharpening, motion stream or marker detection.

use crate::atlas::{AtlasCacheTracker, AtlasWindowEncoder};
use crate::encode::alpha::AlphaTiler;
use crate::encode::{Backend, CpuImage, Encoder, Input, Pixels, Settings, ShmPicture};
use crate::motion;
use crate::render::Canvas;
use caboose_display_protocol::{Codec, Rect, SurfaceBatch};
use smithay::reexports::calloop::channel::Sender;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub const MAX_UNACKED: usize = 2;
/// Surface Atlas (`surface.batch`) encodes in sub-millisecond deltas and CopyRects;
/// a deeper in-flight window prevents network RTT from capping 120 Hz scroll/playback at ~30 fps.
pub const MAX_ATLAS_UNACKED: usize = 12;

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
    /// The picture keeps the window's alpha: it goes as RGBA tiles, never as a frame.
    pub alpha: bool,
    /// Encode as a lossless `SurfaceBatch` (Surface Atlas Engine) rather than video/PNG.
    pub atlas: bool,
    pub atlas_cache: Option<Arc<Mutex<AtlasCacheTracker>>>,
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
    /// Atomic lossless `SurfaceBatch` produced when `job.atlas` is true, with `(batch, cpu_us, cache_epoch)`.
    pub surface_batch: Option<(SurfaceBatch, u64, u64)>,
}

pub struct TilesDone {
    /// Picture pixels, and the PNG.
    pub tiles: Vec<(Rect, Vec<u8>)>,
    pub refine_in_ms: Option<u64>,
    pub cpu_us: u64,
}

/// An RGB (or, with `alpha`, straight RGBA) rectangle as a PNG, compressed for speed.
pub(crate) fn png(w: u32, h: u32, pixels: &[u8], alpha: bool) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(pixels.len() / 4 + 64);
    let mut encoder = png::Encoder::new(&mut out, w, h);
    encoder.set_color(if alpha { png::ColorType::Rgba } else { png::ColorType::Rgb });
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    encoder.write_header().and_then(|mut w| w.write_image_data(pixels)).map_err(|e| e.to_string())?;
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
    /// An alpha window's shadow of what the client shows, at the picture size.
    alpha: Option<AlphaTiler>,
    /// Surface Atlas encoder for `job.atlas` mode.
    atlas: Option<AtlasWindowEncoder>,
}

/// Encodes a window picture into a `SurfaceBatch` (and optional motion stream + marker detection)
/// without ever opening a base video encoder (`libx264`/`libx265`/`nvenc`).
fn work_atlas(job: Job, encoders: &mut Encoders) -> Done {
    let mut done = Done {
        hits: job.detect.then(|| detect(&job)),
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
        surface_batch: None,
    };
    encoders.window = None;
    encoders.alpha = None;
    let enc = encoders.atlas.get_or_insert_with(AtlasWindowEncoder::new);
    let cpu0 = thread_cpu_us();
    let width = job.crop.w.max(0) as u32;
    let height = job.crop.h.max(0) as u32;
    let excluded = job.motion.as_ref().map(|m| m.rect);
    let input = match &job.shm {
        Some(shm) => Input::Shm(shm),
        None => Input::Cpu(&job.image),
    };
    let fallback_cache = AtlasCacheTracker::new();
    let (atlas_epoch, batch_res) = match &job.atlas_cache {
        Some(shared) => {
            let guard = shared.lock().unwrap();
            let epoch = guard.epoch;
            let res = enc.encode_input(
                job.window,
                job.pts_us,
                job.rect,
                width,
                height,
                input,
                job.alpha,
                job.keyframe,
                job.damage.as_deref(),
                excluded,
                &guard,
            );
            (epoch, res)
        }
        None => (
            fallback_cache.epoch,
            enc.encode_input(
                job.window,
                job.pts_us,
                job.rect,
                width,
                height,
                input,
                job.alpha,
                job.keyframe,
                job.damage.as_deref(),
                excluded,
                &fallback_cache,
            ),
        ),
    };
    match batch_res {
        Ok((Some(batch), changed)) => {
            done.changed = changed;
            done.surface_batch = Some((batch, thread_cpu_us().saturating_sub(cpu0), atlas_epoch));
        }
        Ok((None, changed)) => {
            done.changed = changed;
        }
        Err(e) => {
            encoders.atlas = None;
            done.result = Some(Err(e));
        }
    }
    done.image = job.image;
    done
}

/// The tiles for an alpha window's picture; its answer never carries a frame.
fn work_alpha(job: Job, encoders: &mut Encoders) -> Done {
    let size = (job.image.width, job.image.height);
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
        ends_motion: None,
        tiles: None,
        surface_batch: None,
    };
    encoders.window = None;
    encoders.motion = None;
    encoders.atlas = None;
    if encoders.alpha.as_ref().is_none_or(|t| t.size() != size) {
        encoders.alpha = Some(AlphaTiler::new(size.0, size.1));
    }
    let cpu0 = thread_cpu_us();
    let damage = if job.keyframe { None } else { job.damage.as_deref() };
    let pixels = Pixels { data: &job.image.data, stride: job.image.stride };
    let tiles: Result<Vec<(Rect, Vec<u8>)>, String> =
        encoders.alpha.as_mut().unwrap().tiles(&pixels, damage).map_err(|e| e.to_string()).and_then(|t| {
            t.tiles.iter().map(|(r, rgba)| png(r.w as u32, r.h as u32, rgba, true).map(|p| (*r, p))).collect()
        });
    match tiles {
        Ok(tiles) => {
            done.changed = tiles.iter().map(|(r, _)| *r).collect();
            done.tiles = Some(TilesDone { tiles, refine_in_ms: None, cpu_us: thread_cpu_us().saturating_sub(cpu0) });
        }
        Err(e) => {
            // What the client shows is unknown now; the next picture is a whole one.
            encoders.alpha = None;
            done.result = Some(Err(e));
        }
    }
    done.image = job.image;
    done
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
    if job.atlas {
        return work_atlas(job, encoders);
    }
    encoders.atlas = None;
    if job.alpha {
        return work_alpha(job, encoders);
    }
    encoders.alpha = None;
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
        surface_batch: None,
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
    // A small change goes as tiles: a few lossless PNGs cost far less than coding the
    // whole picture. Not for a picture that ends a motion stream: the client keeps the
    // stream until a frame repaints its region.
    let tile_max_px = job.settings.tile_max_px;
    if let (true, false, false, None, Some(d)) =
        (window_needed && tile_max_px > 0, job.refine, keyframe, job.ends_motion, window_damage.as_ref())
    {
        let cpu0 = thread_cpu_us();
        let (_, enc) = encoders.window.as_mut().unwrap();
        let input = match &job.shm {
            Some(shm) => Input::Shm(shm),
            None => Input::Cpu(&job.image),
        };
        match enc.tiles(input, d, tile_max_px) {
            Ok(Some(t)) => {
                let tiles: Result<Vec<_>, String> =
                    t.tiles.iter().map(|(r, rgb)| png(r.w as u32, r.h as u32, rgb, false).map(|p| (*r, p))).collect();
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
                                encoders.window = None;
                                encoders.motion = None;
                                encoders.alpha = None;
                            }
                            continue;
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let result = work(job, &mut encoders);
                    if let Some(ref tiles) = result.tiles {
                        refining = tiles.refine_in_ms.is_some();
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
}

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
        }
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
        self.can_send_for(false)
    }

    pub fn can_send_for(&self, atlas: bool) -> bool {
        let limit = if atlas { MAX_ATLAS_UNACKED } else { MAX_UNACKED };
        !self.encoding && self.in_flight.len() < limit && self.motion_in_flight() < limit
    }

    /// Whether frame callbacks may be released now.
    pub fn can_release_callbacks(&self) -> bool {
        self.can_release_callbacks_for(false)
    }

    pub fn can_release_callbacks_for(&self, atlas: bool) -> bool {
        let limit = if atlas { MAX_ATLAS_UNACKED } else { MAX_UNACKED };
        self.in_flight.len().max(self.motion_in_flight()) + (self.encoding as usize) < limit
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
            alpha: false,
            atlas: false,
            atlas_cache: None,
            keyframe: false,
            refine,
            damage: None,
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_after_ms: 0, tile_max_px: 0, ..Settings::default() },
            motion,
            ends_motion: None,
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
            alpha: false,
            atlas: false,
            atlas_cache: None,
            keyframe: false,
            refine: false,
            damage: Some(vec![Rect::new(0, 0, 16, 16)]),
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_qp: 0, tile_max_px: 0, ..Settings::default() },
            motion: Some(MotionJob { id: 7, rect: Rect::new(32, 16, 64, 64), keyframe: false, scaled: false }),
            ends_motion: None,
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
            alpha: false,
            atlas: false,
            atlas_cache: None,
            keyframe: false,
            refine: false,
            damage,
            rect: Rect::new(0, 0, 128, 96),
            crop: Rect::new(0, 0, 128, 96),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings { threads: 1, refine_qp: 0, tile_max_px: 0, ..Settings::default() },
            motion: Some(MotionJob { id: 7, rect: Rect::new(32, 16, 64, 64), keyframe: false, scaled: true }),
            ends_motion: None,
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
    fn an_alpha_window_gets_rgba_tiles_and_never_a_frame() {
        let mut encoders = Encoders::default();
        let job = |image, keyframe, damage| Job {
            window: 1,
            generation: 1,
            pts_us: 1,
            image,
            shm: None,
            detect: true,
            alpha: true,
            atlas: false,
            atlas_cache: None,
            keyframe,
            refine: false,
            damage,
            rect: Rect::new(0, 0, 32, 16),
            crop: Rect::new(0, 0, 32, 16),
            backend: Backend::Software(caboose_display_protocol::Codec::H264),
            settings: Settings::default(),
            motion: Some(MotionJob { id: 7, rect: Rect::new(0, 0, 16, 16), keyframe: true, scaled: false }),
            ends_motion: None,
        };
        let first = work(job(CpuImage::new(32, 16), true, None), &mut encoders);
        assert!(first.result.is_none() && first.motion.is_none() && first.hits.is_none());
        let tiles = first.tiles.unwrap().tiles;
        assert_eq!(tiles.len(), 1);
        assert_eq!(tiles[0].0, Rect::new(0, 0, 32, 16));
        let reader = png::Decoder::new(std::io::Cursor::new(&tiles[0].1)).read_info().unwrap();
        assert_eq!((reader.info().color_type, reader.info().bit_depth), (png::ColorType::Rgba, png::BitDepth::Eight));
        assert!(encoders.window.is_none() && encoders.motion.is_none());
        // Unchanged pixels send nothing; a keyframe request is the whole picture again.
        let image = first.image;
        let quiet = work(job(image, false, Some(vec![Rect::new(0, 0, 32, 16)])), &mut encoders);
        assert!(quiet.result.is_none() && quiet.tiles.unwrap().tiles.is_empty());
        let key = work(job(quiet.image, true, None), &mut encoders);
        assert_eq!(key.tiles.unwrap().tiles.len(), 1);
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
