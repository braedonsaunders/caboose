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
//!   sharper, under the same limits (a change first sharpens along the way).

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
}

pub struct MotionJob {
    pub id: u64,
    /// Picture pixels, even.
    pub rect: Rect,
    pub keyframe: bool,
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
}

pub struct TilesDone {
    /// Picture pixels, and the PNG.
    pub tiles: Vec<(Rect, Vec<u8>)>,
    pub refine_in_ms: Option<u64>,
    pub cpu_us: u64,
}

/// An RGB rectangle as a PNG, compressed for speed.
fn png(w: u32, h: u32, rgb: &[u8]) -> Result<Vec<u8>, String> {
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
        None => encoders.motion = None,
        Some(m) => {
            let matches = encoders.motion.as_ref().is_some_and(|(id, r, _)| *id == m.id && *r == m.rect);
            let mut motion_fresh = false;
            if !matches {
                // Sharpening is for still pictures; video is never still long enough.
                let settings = Settings { refine_qp: 0, ..job.settings.clone() };
                encoders.motion = match job.backend.create(m.rect.w as u32, m.rect.h as u32, &settings) {
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
                let input = match &shm {
                    Some(shm) => Input::Shm(shm),
                    None => Input::CpuAt(&job.image, m.rect.x as u32, m.rect.y as u32),
                };
                let damage = (!motion_key).then_some(region_damage.as_slice());
                let (result, changed) = encode_with(enc.as_mut(), input, motion_key, damage, false);
                if result.is_err() {
                    encoders.motion = None;
                } else {
                    let changed = changed.unwrap_or_else(|| {
                        damage.map_or_else(|| vec![Rect::new(0, 0, m.rect.w, m.rect.h)], <[Rect]>::to_vec)
                    });
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
                while let Ok(job) = rx.recv() {
                    if done.send(work(job, &mut encoders)).is_err() {
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
}

impl Stream {
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
        if job.ends_motion.is_some() {
            self.motion = None;
        }
        // The answer says when to sharpen next.
        self.refine_at_us = None;
        self.crop = job.crop;
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
