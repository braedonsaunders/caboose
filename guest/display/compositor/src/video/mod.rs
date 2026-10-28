//! Video streams layered into windows (docs/display.md, "Video, for every app").
//!
//! Layer 1, codec passthrough: the Caboose VA-API driver (guest/vaapi) does not decode.
//! It hands each access unit to the compositor over the video socket ([`ipc`]) and fills
//! the application's decode surfaces with a marker ([`marker`]) instead of pixels. The
//! compositor finds the marker in the window pictures the application composes, which
//! says where the video is in the window (`video.create`, `video.update`) and which
//! frame the application is showing (`video.present`). The client decodes the stream
//! itself and draws it there.
//!
//! The driver's exact path (a wl_buffer that *is* a decode surface, by its dmabuf device
//! and inode) needs a renderer that imports NV12 dmabufs; with the pixman renderer
//! those buffers are never offered, so every stream is bound through the marker.

pub mod ipc;
pub mod marker;
pub mod server;

use caboose_display_protocol::{self as proto, Codec, Rect};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

/// One access unit, kept so a stream can be replayed from its last keyframe.
#[derive(Clone)]
pub struct Unit {
    pub seq: u32,
    pub key: bool,
    pub data: Arc<Vec<u8>>,
}

/// Where a stream shows: a window and the stream's rectangle in it.
#[derive(Debug, Clone, PartialEq)]
pub struct Binding {
    pub window: u64,
    pub rect: Rect,
    pub clip: Rect,
    /// The current client was sent `video.create`.
    pub announced: bool,
}

pub struct VideoStream {
    pub id: u64,
    pub conn: u64,
    pub driver_stream: u32,
    pub codec: Codec,
    pub tag: u8,
    pub passthrough: bool,
    /// The decoding process and its ancestors.
    pub lineage: Vec<u32>,
    /// Units since the last keyframe (decode order).
    pub gop: Vec<Unit>,
    /// Recent sequence numbers, newest last, to resolve the marker's seq mod 64.
    pub recent: VecDeque<u32>,
    pub binding: Option<Binding>,
    pub misses: u32,
    pub presented: Option<u32>,
    /// The first frame the current client was sent; presents never name older ones.
    pub first_sent: Option<u32>,
    /// When the client last asked for keyframes (its decoder failed).
    pub keyframe_requests: VecDeque<std::time::Instant>,
}

/// Units kept between keyframes before the oldest are dropped (a stream with very long
/// GOPs replays from the driver instead).
const GOP_LIMIT: usize = 600;
/// Detection passes in a re-rendered window without the marker before a stream unbinds.
pub const MISSES_TO_UNBIND: u32 = 3;
/// A client decoder that fails this often within [`KEYFRAME_WINDOW`] gets the stream
/// decoded on the server instead.
pub const KEYFRAMES_TO_GIVE_UP: usize = 3;
pub const KEYFRAME_WINDOW: std::time::Duration = std::time::Duration::from_secs(10);

impl VideoStream {
    pub fn push(&mut self, unit: Unit) {
        if unit.key {
            self.gop.clear();
        }
        if self.gop.len() >= GOP_LIMIT {
            self.gop.clear();
        }
        self.recent.push_back(unit.seq);
        while self.recent.len() > 128 {
            self.recent.pop_front();
        }
        self.gop.push(unit);
    }

    /// Records a client decode failure; true when the stream should be decoded locally.
    pub fn client_failed(&mut self, now: std::time::Instant) -> bool {
        self.keyframe_requests.push_back(now);
        while self.keyframe_requests.front().is_some_and(|t| now.duration_since(*t) > KEYFRAME_WINDOW) {
            self.keyframe_requests.pop_front();
        }
        self.keyframe_requests.len() >= KEYFRAMES_TO_GIVE_UP
    }

    /// The newest frame the client has whose seq mod 64 is `seq64`.
    pub fn resolve(&self, seq64: u32) -> Option<u32> {
        let first = self.first_sent?;
        self.recent.iter().rev().copied().take_while(|s| *s >= first).find(|s| s % 64 == seq64)
    }
}

/// The parent of a process, from /proc.
fn parent(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 2..];
    rest.split_whitespace().nth(1)?.parse().ok()
}

/// A process and its ancestors up to (not including) init.
pub fn lineage(pid: u32) -> Vec<u32> {
    let mut out = vec![pid];
    let mut p = pid;
    while let Some(pp) = parent(p) {
        if pp <= 1 || out.contains(&pp) || out.len() > 64 {
            break;
        }
        out.push(pp);
        p = pp;
    }
    out
}

/// Whether a window's process and a decoding process belong together: one is the other
/// or its ancestor (Chromium decodes in a child of the browser that owns the window; a
/// launcher can start both).
pub fn related(window_lineage: &[u32], stream_lineage: &[u32]) -> bool {
    match (window_lineage.first(), stream_lineage.first()) {
        (Some(w), Some(s)) => stream_lineage.contains(w) || window_lineage.contains(s),
        _ => false,
    }
}

/// The marker's rectangle (picture pixels) in window-local display pixels.
pub fn to_window(hit: &marker::Hit, scale_x: f64, scale_y: f64) -> (Rect, Rect) {
    let r = |x: f64, y: f64, w: f64, h: f64| {
        Rect::new(
            (x * scale_x).round() as i32,
            (y * scale_y).round() as i32,
            (w * scale_x).round() as i32,
            (h * scale_y).round() as i32,
        )
    };
    let (x0, y0, x1, y1) = hit.clip;
    (r(hit.x, hit.y, hit.w, hit.h), r(x0 as f64, y0 as f64, (x1 - x0) as f64, (y1 - y0) as f64))
}

pub fn codec_of(ipc_codec: u8) -> Option<Codec> {
    Some(match ipc_codec {
        ipc::codec::H264 => Codec::H264,
        ipc::codec::HEVC => Codec::Hevc,
        ipc::codec::VP9 => Codec::Vp9,
        ipc::codec::AV1 => Codec::Av1,
        _ => return None,
    })
}

/// All open streams and their marker tags.
pub struct Streams {
    pub by_id: HashMap<u64, VideoStream>,
    next_id: u64,
    tags: [Option<u64>; 64],
}

impl Default for Streams {
    fn default() -> Self {
        Self { by_id: HashMap::new(), next_id: 0, tags: [None; 64] }
    }
}

impl Streams {
    /// Opens a stream; `None` if every marker tag is taken.
    pub fn open(&mut self, conn: u64, driver_stream: u32, codec: Codec, lineage: Vec<u32>) -> Option<&mut VideoStream> {
        let tag = self.tags.iter().position(Option::is_none)?;
        self.next_id += 1;
        let id = self.next_id;
        self.tags[tag] = Some(id);
        let stream = VideoStream {
            id,
            conn,
            driver_stream,
            codec,
            tag: tag as u8,
            passthrough: true,
            lineage,
            gop: Vec::new(),
            recent: VecDeque::new(),
            binding: None,
            misses: 0,
            presented: None,
            first_sent: None,
            keyframe_requests: VecDeque::new(),
        };
        Some(self.by_id.entry(id).or_insert(stream))
    }

    pub fn close(&mut self, id: u64) -> Option<VideoStream> {
        let s = self.by_id.remove(&id)?;
        self.tags[s.tag as usize] = None;
        Some(s)
    }

    pub fn by_driver(&mut self, conn: u64, driver_stream: u32) -> Option<&mut VideoStream> {
        self.by_id.values_mut().find(|s| s.conn == conn && s.driver_stream == driver_stream)
    }

    pub fn by_tag(&mut self, tag: u32) -> Option<&mut VideoStream> {
        let id = (*self.tags.get(tag as usize)?)?;
        self.by_id.get_mut(&id)
    }

    pub fn ids(&self) -> Vec<u64> {
        self.by_id.keys().copied().collect()
    }

    /// An id for a video stream the compositor makes itself (a `motion` stream), from
    /// the same namespace as passthrough streams.
    pub fn allocate_id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Whether any passthrough stream could be playing in a window of this lineage.
    pub fn wants_detection(&self, window_lineage: &[u32]) -> bool {
        self.by_id.values().any(|s| s.passthrough && related(window_lineage, &s.lineage))
    }
}

/// The `video.create` for a bound stream.
pub fn create_message(s: &VideoStream, b: &Binding) -> proto::Message {
    proto::Message::VideoCreate(proto::VideoCreate {
        id: s.id,
        window: b.window,
        rect: b.rect,
        clip: (b.clip != b.rect).then_some(b.clip),
        z: None,
        codec: s.codec,
        source: proto::VideoSource::Passthrough,
        color: None,
        extradata: None,
    })
}

pub fn frame_message(id: u64, u: &Unit) -> proto::Message {
    proto::Message::VideoFrame(proto::VideoFrame {
        id,
        seq: u.seq as u64,
        keyframe: u.key,
        pts_us: None,
        data: (*u.data).clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(seq: u32, key: bool) -> Unit {
        Unit { seq, key, data: Arc::new(vec![seq as u8]) }
    }

    #[test]
    fn a_keyframe_starts_a_new_gop() {
        let mut streams = Streams::default();
        let s = streams.open(1, 7, Codec::H264, vec![100]).unwrap();
        for (seq, key) in [(0, true), (1, false), (2, false), (3, true), (4, false)] {
            s.push(unit(seq, key));
        }
        assert_eq!(s.gop.iter().map(|u| u.seq).collect::<Vec<_>>(), vec![3, 4]);
    }

    #[test]
    fn marker_seq_resolves_to_the_newest_match() {
        let mut streams = Streams::default();
        let s = streams.open(1, 7, Codec::H264, vec![100]).unwrap();
        for seq in 0..130 {
            s.push(unit(seq, seq % 60 == 0));
        }
        assert_eq!(s.resolve(1), None, "nothing was sent to a client yet");
        s.first_sent = Some(60);
        assert_eq!(s.resolve(1), Some(129));
        assert_eq!(s.resolve(63), Some(127));
        assert_eq!(s.resolve(2), Some(66));
        assert_eq!(s.resolve(59), Some(123));
        // Frames before the client's first are never named.
        s.first_sent = Some(125);
        assert_eq!(s.resolve(59), None);
        assert_eq!(s.resolve(61), Some(125));
    }

    #[test]
    fn repeated_client_failures_give_the_stream_up() {
        let mut streams = Streams::default();
        let s = streams.open(1, 7, Codec::Hevc, vec![]).unwrap();
        let t = std::time::Instant::now();
        assert!(!s.client_failed(t));
        assert!(!s.client_failed(t + std::time::Duration::from_secs(11)), "the first failure aged out");
        assert!(!s.client_failed(t + std::time::Duration::from_secs(12)));
        assert!(s.client_failed(t + std::time::Duration::from_secs(13)));
    }

    #[test]
    fn tags_are_unique_and_reused_after_close() {
        let mut streams = Streams::default();
        let a = streams.open(1, 1, Codec::H264, vec![]).unwrap().id;
        let tag_b = streams.open(1, 2, Codec::H264, vec![]).unwrap().tag;
        assert_eq!(tag_b, 1);
        streams.close(a);
        assert_eq!(streams.open(1, 3, Codec::Hevc, vec![]).unwrap().tag, 0);
        for i in 0..62 {
            assert!(streams.open(2, i, Codec::H264, vec![]).is_some());
        }
        assert!(streams.open(3, 0, Codec::H264, vec![]).is_none(), "64 tags at most");
    }

    #[test]
    fn processes_relate_through_ancestry_either_way() {
        // Chromium: the browser (window) is the GPU process's (decoder's) parent.
        assert!(related(&[200, 1], &[300, 200, 1]));
        // A launcher (window owner's child decodes) or the same process.
        assert!(related(&[300, 200], &[200]));
        assert!(related(&[42], &[42]));
        assert!(!related(&[300, 200], &[400, 150]));
    }

    #[test]
    fn hits_scale_into_display_pixels() {
        let hit = marker::Hit {
            tag: 0,
            seq: 0,
            tags_found: 64,
            x: 10.0,
            y: 20.0,
            w: 100.0,
            h: 50.0,
            clip: (10, 20, 110, 60),
        };
        let (rect, clip) = to_window(&hit, 2.0, 2.0);
        assert_eq!(rect, Rect::new(20, 40, 200, 100));
        assert_eq!(clip, Rect::new(20, 40, 200, 80));
    }
}
