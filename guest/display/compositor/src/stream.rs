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
//!   slows to what the link and the client can show.

use crate::encode::{Backend, CpuImage, EncodeError, Encoder, Input, Settings, ShmPicture};
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
    /// What changed since the previous picture; `None` for everything.
    pub damage: Option<Vec<Rect>>,
    pub rect: Rect,
    pub crop: Rect,
    pub backend: Backend,
    pub settings: Settings,
}

/// The worker's answer: the encoded picture (or why not) and the image back for reuse.
pub struct Done {
    /// Markers found in the picture (when the job asked), picture pixels.
    pub hits: Option<Vec<crate::video::marker::Hit>>,
    pub window: u64,
    pub generation: u64,
    pub pts_us: u64,
    pub image: CpuImage,
    pub result: Result<Encoded, String>,
    pub rect: Rect,
    pub crop: Rect,
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

impl Worker {
    fn spawn(window: u64, done: Sender<Done>) -> Self {
        let (tx, rx) = std::sync::mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name(format!("encode-{window}"))
            .spawn(move || {
                let mut encoder: Option<(Backend, Box<dyn Encoder>)> = None;
                while let Ok(job) = rx.recv() {
                    let cpu0 = thread_cpu_us();
                    let start = Instant::now();
                    let size = (job.image.width, job.image.height);
                    let reuse = encoder.as_ref().is_some_and(|(b, e)| *b == job.backend && e.coded_size() == size);
                    let mut fresh = false;
                    if !reuse {
                        encoder = match job.backend.create(size.0, size.1, &job.settings) {
                            Ok(e) => Some((job.backend.clone(), e)),
                            Err(e) => {
                                let _ = done.send(Done {
                                    hits: None,
                                    window: job.window,
                                    generation: job.generation,
                                    pts_us: job.pts_us,
                                    image: job.image,
                                    result: Err(format!("cannot open {}: {e}", job.backend.describe())),
                                    rect: job.rect,
                                    crop: job.crop,
                                });
                                continue;
                            }
                        };
                        fresh = true;
                    }
                    let (_, enc) = encoder.as_mut().unwrap();
                    let damage = if fresh { None } else { job.damage.as_deref() };
                    let hits = job.detect.then(|| detect(&job));
                    let input = match &job.shm {
                        Some(shm) => Input::Shm(shm),
                        None => Input::Cpu(&job.image),
                    };
                    let result: Result<_, EncodeError> = enc.encode(input, job.keyframe || fresh, damage);
                    let result = result
                        .map(|p| Encoded {
                            codec: enc.codec(),
                            keyframe: p.keyframe,
                            data: p.data,
                            encode_us: start.elapsed().as_micros() as u64,
                            cpu_us: thread_cpu_us().saturating_sub(cpu0),
                        })
                        .map_err(|e| e.to_string());
                    if result.is_err() {
                        encoder = None; // start clean (and with a keyframe) next time
                    }
                    let sent = done.send(Done {
                        hits,
                        window: job.window,
                        generation: job.generation,
                        pts_us: job.pts_us,
                        image: job.image,
                        result,
                        rect: job.rect,
                        crop: job.crop,
                    });
                    if sent.is_err() {
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

    /// Room for another picture under the flow-control limit.
    pub fn can_send(&self) -> bool {
        !self.encoding && self.in_flight.len() < MAX_UNACKED
    }

    /// Whether frame callbacks may be released now.
    pub fn can_release_callbacks(&self) -> bool {
        self.in_flight.len() + (self.encoding as usize) < MAX_UNACKED
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
        self.dirty = false;
        self.need_keyframe = false;
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
    fn pts_follow_the_newest_commit_and_never_repeat() {
        let mut s = Stream::default();
        s.mark_dirty(100);
        s.mark_dirty(200);
        assert_eq!(s.next_pts(), 200);
        s.mark_dirty(200);
        assert_eq!(s.next_pts(), 201);
    }
}
