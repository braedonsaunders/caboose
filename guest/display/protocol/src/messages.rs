//! Every Caboose Display Protocol v0 message, both directions. Field names, types and
//! type ids are the contract in docs/display.md.

use crate::cbor::Value;
use crate::fields::{self, Fields, MapBuilder};
use crate::ProtocolError;

/// `[x, y, w, h]` in pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }
}

impl From<Rect> for Value {
    fn from(r: Rect) -> Self {
        Value::Array(vec![r.x.into(), r.y.into(), r.w.into(), r.h.into()])
    }
}

/// `[w, h]` in pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Size {
    pub w: i32,
    pub h: i32,
}

impl From<Size> for Value {
    fn from(s: Size) -> Self {
        Value::Array(vec![s.w.into(), s.h.into()])
    }
}

macro_rules! string_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident => $text:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum $name { $($variant),+ }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];
            pub fn as_str(self) -> &'static str {
                match self { $($name::$variant => $text),+ }
            }
            pub fn parse(text: &str) -> Option<Self> {
                match text { $($text => Some($name::$variant),)+ _ => None }
            }
        }
        impl From<$name> for Value {
            fn from(v: $name) -> Self { Value::Text(v.as_str().to_owned()) }
        }
    };
}

string_enum!(
    /// A window's role. Popups and dialogs have a parent.
    WindowKind { Toplevel => "toplevel", Popup => "popup", Dialog => "dialog" }
);
string_enum!(Codec { Hevc => "hevc", Av1 => "av1", H264 => "h264", Vp9 => "vp9" });
string_enum!(
    /// Where a video stream comes from (docs/display.md, "Video, for every app").
    VideoSource { Passthrough => "passthrough", Surface => "surface", Motion => "motion" }
);
string_enum!(TileFormat { Png => "png", WebpLossless => "webp-lossless" });
string_enum!(TouchPhase { Down => "down", Motion => "motion", Up => "up", Cancel => "cancel" });
string_enum!(PencilPhase {
    Down => "down", Motion => "motion", Up => "up", Cancel => "cancel", Hover => "hover", Leave => "leave"
});
string_enum!(ByeReason { Auth => "auth", Version => "version", Shutdown => "shutdown", Protocol => "protocol" });

fn enum_field<T>(f: &Fields<'_>, key: &'static str, parse: fn(&str) -> Option<T>) -> Result<T, ProtocolError> {
    f.req(key, |v| match v {
        Value::Text(s) => parse(s),
        _ => None,
    })
}

/// One of the client's displays (a phone screen, an iPad, a TV).
#[derive(Debug, Clone, PartialEq)]
pub struct Display {
    pub id: u32,
    /// Pixels.
    pub width: i32,
    pub height: i32,
    pub scale: f64,
    pub refresh_hz: f64,
    pub hdr: bool,
}

impl Display {
    fn to_value(&self) -> Value {
        MapBuilder::new()
            .put("id", self.id)
            .put("width", self.width)
            .put("height", self.height)
            .put("scale", self.scale)
            .put("refresh_hz", self.refresh_hz)
            .put("hdr", self.hdr)
            .build()
    }
    fn from_value(v: &Value) -> Result<Self, ProtocolError> {
        let f = Fields::new("display", v)?;
        Ok(Self {
            id: f.u32("id")?,
            width: f.req("width", fields::as_i32)?,
            height: f.req("height", fields::as_i32)?,
            scale: f.f64("scale")?,
            refresh_hz: f.f64("refresh_hz")?,
            hdr: f.bool("hdr")?,
        })
    }
}

fn displays_from(f: &Fields<'_>) -> Result<Vec<Display>, ProtocolError> {
    f.array("displays")?.iter().map(Display::from_value).collect()
}

fn displays_value(displays: &[Display]) -> Value {
    Value::Array(displays.iter().map(Display::to_value).collect())
}

/// Server → client `hello` (0x01).
#[derive(Debug, Clone, PartialEq)]
pub struct ServerHello {
    pub version: u32,
    /// The client display ids the server accepted.
    pub displays: Vec<u32>,
    /// The server's encoders that the client can decode, in preference order.
    pub encoders: Vec<Codec>,
    pub features: Vec<String>,
}

/// `window.create` (0x02).
#[derive(Debug, Clone, PartialEq)]
pub struct WindowCreate {
    pub id: u64,
    pub parent: Option<u64>,
    pub kind: WindowKind,
    pub title: String,
    pub app_id: String,
    /// PNG.
    pub icon: Option<Vec<u8>>,
    /// Display pixels; toplevels relative to the display, others to the parent's geometry.
    pub geometry: Rect,
    pub min: Option<Size>,
    pub max: Option<Size>,
    pub fullscreen: bool,
    pub display: Option<u32>,
    pub xwayland: bool,
    pub alpha: bool,
}

/// `window.update` (0x03): the id plus whichever fields changed.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct WindowUpdate {
    pub id: u64,
    pub parent: Option<u64>,
    pub kind: Option<WindowKind>,
    pub title: Option<String>,
    pub app_id: Option<String>,
    pub icon: Option<Vec<u8>>,
    pub geometry: Option<Rect>,
    pub min: Option<Size>,
    pub max: Option<Size>,
    pub fullscreen: Option<bool>,
    pub display: Option<u32>,
    pub xwayland: Option<bool>,
    pub alpha: Option<bool>,
}

impl WindowUpdate {
    pub fn is_empty(&self) -> bool {
        *self == WindowUpdate { id: self.id, ..Default::default() }
    }
}

/// `frame` (0x10): one encoded picture of one window.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub id: u64,
    pub codec: Codec,
    pub keyframe: bool,
    /// Server CLOCK_MONOTONIC at the surface commit, microseconds.
    pub pts_us: u64,
    /// Where the picture lands, window-local display pixels.
    pub rect: Rect,
    /// The visible part of the decoded picture, picture pixels.
    pub crop: Rect,
    /// Annex-B for h264/hevc; one temporal unit of low-overhead OBUs for av1.
    pub data: Vec<u8>,
}

/// `tile` (0x11): a lossless refresh of static content.
#[derive(Debug, Clone, PartialEq)]
pub struct Tile {
    pub id: u64,
    pub rect: Rect,
    pub format: TileFormat,
    pub data: Vec<u8>,
}

/// `cursor` (0x20).
#[derive(Debug, Clone, PartialEq)]
pub struct Cursor {
    pub id: Option<u64>,
    /// PNG.
    pub image: Vec<u8>,
    pub hotspot: [i32; 2],
}

/// `text_input` (0x22): text-input-v3 enabled or disabled on the focused window.
#[derive(Debug, Clone, PartialEq)]
pub struct TextInputState {
    pub id: u64,
    pub enabled: bool,
    pub purpose: Option<String>,
}

/// `clipboard` (0x30 server → client, 0xA0 client → server).
#[derive(Debug, Clone, PartialEq)]
pub struct Clipboard {
    pub mime: String,
    pub data: Vec<u8>,
}

/// `notification` (0x31).
#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub id: u64,
    pub app: String,
    pub summary: String,
    pub body: String,
}

/// `audio` (0x40).
#[derive(Debug, Clone, PartialEq)]
pub struct Audio {
    pub codec: String,
    pub pts_us: u64,
    pub data: Vec<u8>,
}

/// Client → server `hello` (0x81). The client speaks first.
#[derive(Debug, Clone, PartialEq)]
pub struct ClientHello {
    pub version: u32,
    pub token: String,
    pub decoders: Vec<Codec>,
    pub displays: Vec<Display>,
    /// Codecs the client can play as `video.*` streams; absent means none.
    pub video_decoders: Option<Vec<Codec>>,
}

/// Colour description of a video stream, as ITU-T H.273 code points.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoColor {
    pub primaries: u32,
    pub transfer: u32,
    pub matrix: u32,
    pub full_range: bool,
}

/// `video.create` (0x12): a video stream layered into a window.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoCreate {
    pub id: u64,
    pub window: u64,
    /// Where the whole picture goes, window-local display pixels.
    pub rect: Rect,
    /// The visible part of `rect`; absent means all of it.
    pub clip: Option<Rect>,
    /// Order among the window's video streams, higher on top; all are above the window.
    pub z: Option<i32>,
    pub codec: Codec,
    pub source: VideoSource,
    pub color: Option<VideoColor>,
    /// Out-of-band codec configuration, only for a codec whose parameters cannot travel
    /// in band.
    pub extradata: Option<Vec<u8>>,
}

/// `video.frame` (0x13): one access unit, in decode order.
#[derive(Debug, Clone, PartialEq)]
pub struct VideoFrame {
    pub id: u64,
    /// Decode order, starting at 0 for each stream and increasing by one.
    pub seq: u64,
    pub keyframe: bool,
    /// When to show it (server CLOCK_MONOTONIC). Present for `surface` and `motion`
    /// streams, whose frames are shown as decoded; absent for `passthrough`, whose
    /// frames are shown when `video.present` names them.
    pub pts_us: Option<u64>,
    /// Annex-B for h264/hevc (parameter sets on keyframes), a temporal unit of OBUs for
    /// av1, a frame or superframe for vp9.
    pub data: Vec<u8>,
}

/// `video.update` (0x14): the stream moved, was clipped, or restacked.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VideoUpdate {
    pub id: u64,
    pub rect: Option<Rect>,
    pub clip: Option<Rect>,
    pub z: Option<i32>,
}

/// `configure` (0x84).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Configure {
    pub id: u64,
    pub geometry: Option<Rect>,
    pub display: Option<u32>,
    pub fullscreen: Option<bool>,
    pub maximized: Option<bool>,
    pub activated: Option<bool>,
}

/// One contact in a `touch` message.
#[derive(Debug, Clone, PartialEq)]
pub struct TouchPoint {
    pub slot: u32,
    pub phase: TouchPhase,
    pub x: f64,
    pub y: f64,
    pub force: Option<f64>,
    pub radius: Option<f64>,
}

/// `touch` (0x90): one `wl_touch.frame` worth of contacts.
#[derive(Debug, Clone, PartialEq)]
pub struct Touch {
    pub id: u64,
    pub points: Vec<TouchPoint>,
}

/// `pencil` (0x91).
#[derive(Debug, Clone, PartialEq)]
pub struct Pencil {
    pub id: u64,
    pub phase: PencilPhase,
    pub x: f64,
    pub y: f64,
    /// 0..1.
    pub pressure: f64,
    /// Degrees, `[x, y]`.
    pub tilt: [f64; 2],
    pub azimuth_deg: f64,
}

/// Scroll in a `pointer` message: pixels when `precise`, wheel clicks otherwise.
#[derive(Debug, Clone, PartialEq)]
pub struct Scroll {
    pub dx: f64,
    pub dy: f64,
    pub precise: bool,
}

pub mod buttons {
    pub const LEFT: u32 = 1;
    pub const MIDDLE: u32 = 2;
    pub const RIGHT: u32 = 4;
    pub const BACK: u32 = 8;
    pub const FORWARD: u32 = 16;
}

/// `pointer` (0x92). `buttons` is the full pressed set, not a delta.
#[derive(Debug, Clone, PartialEq)]
pub struct Pointer {
    pub id: u64,
    pub x: f64,
    pub y: f64,
    pub buttons: u32,
    pub scroll: Option<Scroll>,
}

/// `key` (0x93).
#[derive(Debug, Clone, PartialEq)]
pub struct Key {
    pub keysym: u32,
    pub pressed: bool,
    /// Any of "shift", "control", "mod1", "mod4".
    pub mods: Vec<String>,
}

/// `text` (0x94): text-input-v3 from the client's keyboard.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Text {
    pub commit: Option<String>,
    pub preedit: Option<String>,
    /// Byte offsets into `preedit`, `[begin, end]`.
    pub cursor: Option<[u32; 2]>,
    /// Extended grapheme clusters before the cursor.
    pub delete_before: Option<u32>,
    pub delete_after: Option<u32>,
}

/// Every message. The variant fixes the direction and the type id.
#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    // Server → client.
    ServerHello(ServerHello),
    WindowCreate(WindowCreate),
    WindowUpdate(WindowUpdate),
    WindowDestroy {
        id: u64,
    },
    Frame(Frame),
    Tile(Tile),
    Cursor(Cursor),
    CursorNamed {
        name: String,
    },
    TextInput(TextInputState),
    ServerClipboard(Clipboard),
    Notification(Notification),
    Audio(Audio),
    VideoCreate(VideoCreate),
    VideoFrame(VideoFrame),
    VideoUpdate(VideoUpdate),
    VideoDestroy {
        id: u64,
    },
    /// The application is showing the frame `seq` of a passthrough stream now.
    VideoPresent {
        id: u64,
        seq: u64,
        pts_us: u64,
    },
    Pong {
        t_us: u64,
    },
    Bye {
        reason: ByeReason,
    },
    // Client → server.
    ClientHello(ClientHello),
    Vsync {
        display: u32,
        t_us: u64,
    },
    Ack {
        id: u64,
        pts_us: u64,
        decoded_us: i64,
    },
    Configure(Configure),
    Close {
        id: u64,
    },
    RequestKeyframe {
        id: u64,
    },
    Displays {
        displays: Vec<Display>,
    },
    Touch(Touch),
    Pencil(Pencil),
    Pointer(Pointer),
    Key(Key),
    Text(Text),
    ClientClipboard(Clipboard),
    /// The client has the video frame `seq` queued for display.
    VideoAck {
        id: u64,
        seq: u64,
    },
    /// The client's decoder failed; it drops the stream's frames until a keyframe.
    VideoKeyframe {
        id: u64,
    },
    Ping {
        t_us: u64,
    },
}

pub mod type_id {
    pub const HELLO: u8 = 0x01;
    pub const WINDOW_CREATE: u8 = 0x02;
    pub const WINDOW_UPDATE: u8 = 0x03;
    pub const WINDOW_DESTROY: u8 = 0x04;
    pub const FRAME: u8 = 0x10;
    pub const TILE: u8 = 0x11;
    pub const VIDEO_CREATE: u8 = 0x12;
    pub const VIDEO_FRAME: u8 = 0x13;
    pub const VIDEO_UPDATE: u8 = 0x14;
    pub const VIDEO_DESTROY: u8 = 0x15;
    pub const VIDEO_PRESENT: u8 = 0x16;
    pub const CURSOR: u8 = 0x20;
    pub const CURSOR_NAMED: u8 = 0x21;
    pub const TEXT_INPUT: u8 = 0x22;
    pub const CLIPBOARD: u8 = 0x30;
    pub const NOTIFICATION: u8 = 0x31;
    pub const AUDIO: u8 = 0x40;
    pub const PONG: u8 = 0x7E;
    pub const BYE: u8 = 0x7F;
    pub const CLIENT_HELLO: u8 = 0x81;
    pub const VSYNC: u8 = 0x82;
    pub const ACK: u8 = 0x83;
    pub const CONFIGURE: u8 = 0x84;
    pub const CLOSE: u8 = 0x85;
    pub const REQUEST_KEYFRAME: u8 = 0x86;
    pub const DISPLAYS: u8 = 0x87;
    pub const VIDEO_ACK: u8 = 0x88;
    pub const VIDEO_KEYFRAME: u8 = 0x89;
    pub const TOUCH: u8 = 0x90;
    pub const PENCIL: u8 = 0x91;
    pub const POINTER: u8 = 0x92;
    pub const KEY: u8 = 0x93;
    pub const TEXT: u8 = 0x94;
    pub const CLIENT_CLIPBOARD: u8 = 0xA0;
    pub const PING: u8 = 0xFE;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    ServerToClient,
    ClientToServer,
}

impl Direction {
    pub fn of(type_id: u8) -> Self {
        if type_id & 0x80 == 0 {
            Direction::ServerToClient
        } else {
            Direction::ClientToServer
        }
    }
}

fn codecs_value(codecs: &[Codec]) -> Value {
    Value::Array(codecs.iter().map(|c| Value::from(*c)).collect())
}

/// Codec lists skip names this build does not know, so a newer peer's list still parses.
fn codecs_from(f: &Fields<'_>, key: &'static str) -> Result<Vec<Codec>, ProtocolError> {
    Ok(f.strings(key)?.iter().filter_map(|s| Codec::parse(s)).collect())
}

fn clipboard_value(c: &Clipboard) -> Value {
    MapBuilder::new().put("mime", c.mime.as_str()).put("data", c.data.clone()).build()
}

fn clipboard_from(f: &Fields<'_>) -> Result<Clipboard, ProtocolError> {
    Ok(Clipboard { mime: f.string("mime")?, data: f.bytes("data")? })
}

impl Message {
    pub fn type_id(&self) -> u8 {
        use type_id::*;
        match self {
            Message::ServerHello(_) => HELLO,
            Message::WindowCreate(_) => WINDOW_CREATE,
            Message::WindowUpdate(_) => WINDOW_UPDATE,
            Message::WindowDestroy { .. } => WINDOW_DESTROY,
            Message::Frame(_) => FRAME,
            Message::Tile(_) => TILE,
            Message::Cursor(_) => CURSOR,
            Message::CursorNamed { .. } => CURSOR_NAMED,
            Message::TextInput(_) => TEXT_INPUT,
            Message::ServerClipboard(_) => CLIPBOARD,
            Message::Notification(_) => NOTIFICATION,
            Message::Audio(_) => AUDIO,
            Message::VideoCreate(_) => VIDEO_CREATE,
            Message::VideoFrame(_) => VIDEO_FRAME,
            Message::VideoUpdate(_) => VIDEO_UPDATE,
            Message::VideoDestroy { .. } => VIDEO_DESTROY,
            Message::VideoPresent { .. } => VIDEO_PRESENT,
            Message::Pong { .. } => PONG,
            Message::Bye { .. } => BYE,
            Message::ClientHello(_) => CLIENT_HELLO,
            Message::Vsync { .. } => VSYNC,
            Message::Ack { .. } => ACK,
            Message::Configure(_) => CONFIGURE,
            Message::Close { .. } => CLOSE,
            Message::RequestKeyframe { .. } => REQUEST_KEYFRAME,
            Message::Displays { .. } => DISPLAYS,
            Message::Touch(_) => TOUCH,
            Message::Pencil(_) => PENCIL,
            Message::Pointer(_) => POINTER,
            Message::Key(_) => KEY,
            Message::Text(_) => TEXT,
            Message::ClientClipboard(_) => CLIENT_CLIPBOARD,
            Message::VideoAck { .. } => VIDEO_ACK,
            Message::VideoKeyframe { .. } => VIDEO_KEYFRAME,
            Message::Ping { .. } => PING,
        }
    }

    /// The contract's name for the message, e.g. `window.create`.
    pub fn name(&self) -> &'static str {
        type_name(self.type_id()).expect("every variant has a name")
    }

    pub fn to_value(&self) -> Value {
        match self {
            Message::ServerHello(m) => MapBuilder::new()
                .put("version", m.version)
                .put("displays", Value::Array(m.displays.iter().map(|d| Value::from(*d)).collect()))
                .put("encoders", codecs_value(&m.encoders))
                .put("features", m.features.clone())
                .build(),
            Message::WindowCreate(m) => MapBuilder::new()
                .put("id", m.id)
                .opt("parent", m.parent)
                .put("kind", m.kind)
                .put("title", m.title.as_str())
                .put("app_id", m.app_id.as_str())
                .opt("icon", m.icon.clone())
                .put("geometry", m.geometry)
                .opt("min", m.min)
                .opt("max", m.max)
                .put("fullscreen", m.fullscreen)
                .opt("display", m.display)
                .put("xwayland", m.xwayland)
                .put("alpha", m.alpha)
                .build(),
            Message::WindowUpdate(m) => MapBuilder::new()
                .put("id", m.id)
                .opt("parent", m.parent)
                .opt("kind", m.kind)
                .opt("title", m.title.clone())
                .opt("app_id", m.app_id.clone())
                .opt("icon", m.icon.clone())
                .opt("geometry", m.geometry)
                .opt("min", m.min)
                .opt("max", m.max)
                .opt("fullscreen", m.fullscreen)
                .opt("display", m.display)
                .opt("xwayland", m.xwayland)
                .opt("alpha", m.alpha)
                .build(),
            Message::WindowDestroy { id }
            | Message::Close { id }
            | Message::RequestKeyframe { id }
            | Message::VideoDestroy { id }
            | Message::VideoKeyframe { id } => MapBuilder::new().put("id", *id).build(),
            Message::VideoCreate(m) => MapBuilder::new()
                .put("id", m.id)
                .put("window", m.window)
                .put("rect", m.rect)
                .opt("clip", m.clip)
                .opt("z", m.z)
                .put("codec", m.codec)
                .put("source", m.source)
                .opt(
                    "color",
                    m.color.as_ref().map(|c| {
                        MapBuilder::new()
                            .put("primaries", c.primaries)
                            .put("transfer", c.transfer)
                            .put("matrix", c.matrix)
                            .put("full_range", c.full_range)
                            .build()
                    }),
                )
                .opt("extradata", m.extradata.clone())
                .build(),
            Message::VideoFrame(m) => MapBuilder::new()
                .put("id", m.id)
                .put("seq", m.seq)
                .put("keyframe", m.keyframe)
                .opt("pts_us", m.pts_us)
                .put("data", m.data.clone())
                .build(),
            Message::VideoUpdate(m) => {
                MapBuilder::new().put("id", m.id).opt("rect", m.rect).opt("clip", m.clip).opt("z", m.z).build()
            }
            Message::VideoPresent { id, seq, pts_us } => {
                MapBuilder::new().put("id", *id).put("seq", *seq).put("pts_us", *pts_us).build()
            }
            Message::VideoAck { id, seq } => MapBuilder::new().put("id", *id).put("seq", *seq).build(),
            Message::Frame(m) => MapBuilder::new()
                .put("id", m.id)
                .put("codec", m.codec)
                .put("keyframe", m.keyframe)
                .put("pts_us", m.pts_us)
                .put("rect", m.rect)
                .put("crop", m.crop)
                .put("data", m.data.clone())
                .build(),
            Message::Tile(m) => MapBuilder::new()
                .put("id", m.id)
                .put("rect", m.rect)
                .put("format", m.format)
                .put("data", m.data.clone())
                .build(),
            Message::Cursor(m) => MapBuilder::new()
                .opt("id", m.id)
                .put("image", m.image.clone())
                .put("hotspot", Value::Array(vec![m.hotspot[0].into(), m.hotspot[1].into()]))
                .build(),
            Message::CursorNamed { name } => MapBuilder::new().put("name", name.as_str()).build(),
            Message::TextInput(m) => {
                MapBuilder::new().put("id", m.id).put("enabled", m.enabled).opt("purpose", m.purpose.clone()).build()
            }
            Message::ServerClipboard(c) | Message::ClientClipboard(c) => clipboard_value(c),
            Message::Notification(m) => MapBuilder::new()
                .put("id", m.id)
                .put("app", m.app.as_str())
                .put("summary", m.summary.as_str())
                .put("body", m.body.as_str())
                .build(),
            Message::Audio(m) => MapBuilder::new()
                .put("codec", m.codec.as_str())
                .put("pts_us", m.pts_us)
                .put("data", m.data.clone())
                .build(),
            Message::Pong { t_us } | Message::Ping { t_us } => MapBuilder::new().put("t_us", *t_us).build(),
            Message::Bye { reason } => MapBuilder::new().put("reason", *reason).build(),
            Message::ClientHello(m) => MapBuilder::new()
                .put("version", m.version)
                .put("token", m.token.as_str())
                .put("decoders", codecs_value(&m.decoders))
                .put("displays", displays_value(&m.displays))
                .opt("video_decoders", m.video_decoders.as_deref().map(codecs_value))
                .build(),
            Message::Vsync { display, t_us } => MapBuilder::new().put("display", *display).put("t_us", *t_us).build(),
            Message::Ack { id, pts_us, decoded_us } => {
                MapBuilder::new().put("id", *id).put("pts_us", *pts_us).put("decoded_us", *decoded_us).build()
            }
            Message::Configure(m) => MapBuilder::new()
                .put("id", m.id)
                .opt("geometry", m.geometry)
                .opt("display", m.display)
                .opt("fullscreen", m.fullscreen)
                .opt("maximized", m.maximized)
                .opt("activated", m.activated)
                .build(),
            Message::Displays { displays } => MapBuilder::new().put("displays", displays_value(displays)).build(),
            Message::Touch(m) => MapBuilder::new()
                .put("id", m.id)
                .put(
                    "points",
                    Value::Array(
                        m.points
                            .iter()
                            .map(|p| {
                                MapBuilder::new()
                                    .put("slot", p.slot)
                                    .put("phase", p.phase)
                                    .put("x", p.x)
                                    .put("y", p.y)
                                    .opt("force", p.force)
                                    .opt("radius", p.radius)
                                    .build()
                            })
                            .collect(),
                    ),
                )
                .build(),
            Message::Pencil(m) => MapBuilder::new()
                .put("id", m.id)
                .put("phase", m.phase)
                .put("x", m.x)
                .put("y", m.y)
                .put("pressure", m.pressure)
                .put("tilt", Value::Array(vec![m.tilt[0].into(), m.tilt[1].into()]))
                .put("azimuth_deg", m.azimuth_deg)
                .build(),
            Message::Pointer(m) => MapBuilder::new()
                .put("id", m.id)
                .put("x", m.x)
                .put("y", m.y)
                .put("buttons", m.buttons)
                .opt(
                    "scroll",
                    m.scroll
                        .as_ref()
                        .map(|s| MapBuilder::new().put("dx", s.dx).put("dy", s.dy).put("precise", s.precise).build()),
                )
                .build(),
            Message::Key(m) => {
                MapBuilder::new().put("keysym", m.keysym).put("pressed", m.pressed).put("mods", m.mods.clone()).build()
            }
            Message::Text(m) => MapBuilder::new()
                .opt("commit", m.commit.clone())
                .opt("preedit", m.preedit.clone())
                .opt("cursor", m.cursor.map(|c| Value::Array(vec![c[0].into(), c[1].into()])))
                .opt("delete_before", m.delete_before)
                .opt("delete_after", m.delete_after)
                .build(),
        }
    }

    /// Decodes a known type id; `Ok(None)` for an id this build does not know, which
    /// the caller skips.
    pub fn from_value(type_id: u8, value: &Value) -> Result<Option<Message>, ProtocolError> {
        use type_id::*;
        let Some(name) = type_name(type_id) else { return Ok(None) };
        let f = Fields::new(name, value)?;
        let message = match type_id {
            HELLO => Message::ServerHello(ServerHello {
                version: f.u32("version")?,
                displays: f.req("displays", |v| fields::as_array(v)?.iter().map(fields::as_u32).collect())?,
                encoders: codecs_from(&f, "encoders")?,
                features: f.strings("features")?,
            }),
            WINDOW_CREATE => Message::WindowCreate(WindowCreate {
                id: f.u64("id")?,
                parent: f.opt_u64("parent")?,
                kind: enum_field(&f, "kind", WindowKind::parse)?,
                title: f.string("title")?,
                app_id: f.string("app_id")?,
                icon: f.opt_bytes("icon")?,
                geometry: f.rect("geometry")?,
                min: f.opt_size("min")?,
                max: f.opt_size("max")?,
                fullscreen: f.bool("fullscreen")?,
                display: f.opt_u32("display")?,
                xwayland: f.opt_bool("xwayland")?.unwrap_or(false),
                alpha: f.opt_bool("alpha")?.unwrap_or(false),
            }),
            WINDOW_UPDATE => Message::WindowUpdate(WindowUpdate {
                id: f.u64("id")?,
                parent: f.opt_u64("parent")?,
                kind: f.opt("kind", |v| match v {
                    Value::Text(s) => WindowKind::parse(s),
                    _ => None,
                })?,
                title: f.opt_string("title")?,
                app_id: f.opt_string("app_id")?,
                icon: f.opt_bytes("icon")?,
                geometry: f.opt_rect("geometry")?,
                min: f.opt_size("min")?,
                max: f.opt_size("max")?,
                fullscreen: f.opt_bool("fullscreen")?,
                display: f.opt_u32("display")?,
                xwayland: f.opt_bool("xwayland")?,
                alpha: f.opt_bool("alpha")?,
            }),
            WINDOW_DESTROY => Message::WindowDestroy { id: f.u64("id")? },
            FRAME => Message::Frame(Frame {
                id: f.u64("id")?,
                codec: enum_field(&f, "codec", Codec::parse)?,
                keyframe: f.bool("keyframe")?,
                pts_us: f.u64("pts_us")?,
                rect: f.rect("rect")?,
                crop: f.rect("crop")?,
                data: f.bytes("data")?,
            }),
            TILE => Message::Tile(Tile {
                id: f.u64("id")?,
                rect: f.rect("rect")?,
                format: enum_field(&f, "format", TileFormat::parse)?,
                data: f.bytes("data")?,
            }),
            CURSOR => Message::Cursor(Cursor {
                id: f.opt_u64("id")?,
                image: f.bytes("image")?,
                hotspot: f.req("hotspot", fields::as_i32_pair)?,
            }),
            CURSOR_NAMED => Message::CursorNamed { name: f.string("name")? },
            TEXT_INPUT => Message::TextInput(TextInputState {
                id: f.u64("id")?,
                enabled: f.bool("enabled")?,
                purpose: f.opt_string("purpose")?,
            }),
            CLIPBOARD => Message::ServerClipboard(clipboard_from(&f)?),
            NOTIFICATION => Message::Notification(Notification {
                id: f.u64("id")?,
                app: f.string("app")?,
                summary: f.string("summary")?,
                body: f.string("body")?,
            }),
            AUDIO => {
                Message::Audio(Audio { codec: f.string("codec")?, pts_us: f.u64("pts_us")?, data: f.bytes("data")? })
            }
            VIDEO_CREATE => Message::VideoCreate(VideoCreate {
                id: f.u64("id")?,
                window: f.u64("window")?,
                rect: f.rect("rect")?,
                clip: f.opt_rect("clip")?,
                z: f.opt("z", fields::as_i32)?,
                codec: enum_field(&f, "codec", Codec::parse)?,
                source: enum_field(&f, "source", VideoSource::parse)?,
                color: match f.opt("color", Some)? {
                    None => None,
                    Some(v) => {
                        let c = Fields::new("video.create.color", v)?;
                        Some(VideoColor {
                            primaries: c.u32("primaries")?,
                            transfer: c.u32("transfer")?,
                            matrix: c.u32("matrix")?,
                            full_range: c.bool("full_range")?,
                        })
                    }
                },
                extradata: f.opt_bytes("extradata")?,
            }),
            VIDEO_FRAME => Message::VideoFrame(VideoFrame {
                id: f.u64("id")?,
                seq: f.u64("seq")?,
                keyframe: f.bool("keyframe")?,
                pts_us: f.opt_u64("pts_us")?,
                data: f.bytes("data")?,
            }),
            VIDEO_UPDATE => Message::VideoUpdate(VideoUpdate {
                id: f.u64("id")?,
                rect: f.opt_rect("rect")?,
                clip: f.opt_rect("clip")?,
                z: f.opt("z", fields::as_i32)?,
            }),
            VIDEO_DESTROY => Message::VideoDestroy { id: f.u64("id")? },
            VIDEO_PRESENT => Message::VideoPresent { id: f.u64("id")?, seq: f.u64("seq")?, pts_us: f.u64("pts_us")? },
            VIDEO_ACK => Message::VideoAck { id: f.u64("id")?, seq: f.u64("seq")? },
            VIDEO_KEYFRAME => Message::VideoKeyframe { id: f.u64("id")? },
            PONG => Message::Pong { t_us: f.u64("t_us")? },
            BYE => Message::Bye { reason: enum_field(&f, "reason", ByeReason::parse)? },
            CLIENT_HELLO => Message::ClientHello(ClientHello {
                version: f.u32("version")?,
                token: f.string("token")?,
                decoders: codecs_from(&f, "decoders")?,
                displays: displays_from(&f)?,
                video_decoders: match f.opt("video_decoders", fields::as_array)? {
                    None => None,
                    Some(_) => Some(codecs_from(&f, "video_decoders")?),
                },
            }),
            VSYNC => Message::Vsync { display: f.u32("display")?, t_us: f.u64("t_us")? },
            ACK => Message::Ack { id: f.u64("id")?, pts_us: f.u64("pts_us")?, decoded_us: f.i64("decoded_us")? },
            CONFIGURE => Message::Configure(Configure {
                id: f.u64("id")?,
                geometry: f.opt_rect("geometry")?,
                display: f.opt_u32("display")?,
                fullscreen: f.opt_bool("fullscreen")?,
                maximized: f.opt_bool("maximized")?,
                activated: f.opt_bool("activated")?,
            }),
            CLOSE => Message::Close { id: f.u64("id")? },
            REQUEST_KEYFRAME => Message::RequestKeyframe { id: f.u64("id")? },
            DISPLAYS => Message::Displays { displays: displays_from(&f)? },
            TOUCH => Message::Touch(Touch {
                id: f.u64("id")?,
                points: f
                    .array("points")?
                    .iter()
                    .map(|p| {
                        let p = Fields::new("touch.points", p)?;
                        Ok(TouchPoint {
                            slot: p.u32("slot")?,
                            phase: enum_field(&p, "phase", TouchPhase::parse)?,
                            x: p.f64("x")?,
                            y: p.f64("y")?,
                            force: p.opt_f64("force")?,
                            radius: p.opt_f64("radius")?,
                        })
                    })
                    .collect::<Result<_, ProtocolError>>()?,
            }),
            PENCIL => Message::Pencil(Pencil {
                id: f.u64("id")?,
                phase: enum_field(&f, "phase", PencilPhase::parse)?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                pressure: f.f64("pressure")?,
                tilt: f.req("tilt", fields::as_f64_pair)?,
                azimuth_deg: f.f64("azimuth_deg")?,
            }),
            POINTER => Message::Pointer(Pointer {
                id: f.u64("id")?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                buttons: f.u32("buttons")?,
                scroll: match f.opt("scroll", Some)? {
                    None => None,
                    Some(v) => {
                        let s = Fields::new("pointer.scroll", v)?;
                        Some(Scroll { dx: s.f64("dx")?, dy: s.f64("dy")?, precise: s.bool("precise")? })
                    }
                },
            }),
            KEY => {
                Message::Key(Key { keysym: f.u32("keysym")?, pressed: f.bool("pressed")?, mods: f.strings("mods")? })
            }
            TEXT => Message::Text(Text {
                commit: f.opt_string("commit")?,
                preedit: f.opt_string("preedit")?,
                cursor: f.opt("cursor", fields::as_u32_pair)?,
                delete_before: f.opt_u32("delete_before")?,
                delete_after: f.opt_u32("delete_after")?,
            }),
            CLIENT_CLIPBOARD => Message::ClientClipboard(clipboard_from(&f)?),
            PING => Message::Ping { t_us: f.u64("t_us")? },
            _ => unreachable!("type_name covers exactly these ids"),
        };
        Ok(Some(message))
    }
}

/// The contract name for a type id, or None if unknown.
pub fn type_name(type_id: u8) -> Option<&'static str> {
    use type_id::*;
    Some(match type_id {
        HELLO | CLIENT_HELLO => "hello",
        WINDOW_CREATE => "window.create",
        WINDOW_UPDATE => "window.update",
        WINDOW_DESTROY => "window.destroy",
        FRAME => "frame",
        TILE => "tile",
        VIDEO_CREATE => "video.create",
        VIDEO_FRAME => "video.frame",
        VIDEO_UPDATE => "video.update",
        VIDEO_DESTROY => "video.destroy",
        VIDEO_PRESENT => "video.present",
        VIDEO_ACK => "video.ack",
        VIDEO_KEYFRAME => "video.keyframe",
        CURSOR => "cursor",
        CURSOR_NAMED => "cursor.named",
        TEXT_INPUT => "text_input",
        CLIPBOARD | CLIENT_CLIPBOARD => "clipboard",
        NOTIFICATION => "notification",
        AUDIO => "audio",
        PONG => "pong",
        BYE => "bye",
        VSYNC => "vsync",
        ACK => "ack",
        CONFIGURE => "configure",
        CLOSE => "close",
        REQUEST_KEYFRAME => "request_keyframe",
        DISPLAYS => "displays",
        TOUCH => "touch",
        PENCIL => "pencil",
        POINTER => "pointer",
        KEY => "key",
        TEXT => "text",
        PING => "ping",
        _ => return None,
    })
}
