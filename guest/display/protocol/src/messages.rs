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
    WindowKind { Toplevel => "toplevel", Popup => "popup", Dialog => "dialog", Child => "child" }
);
string_enum!(
    /// What a window's application says it shows (`wp_content_type_v1`), which tells the
    /// client how fast to refresh it.
    ContentType { None => "none", Photo => "photo", Video => "video", Game => "game" }
);
string_enum!(TouchPhase { Down => "down", Motion => "motion", Up => "up", Cancel => "cancel" });
string_enum!(PencilPhase {
    Down => "down", Motion => "motion", Up => "up", Cancel => "cancel", Hover => "hover", Leave => "leave"
});
string_enum!(
    /// Why a drop from the client did not complete (`drop.result`).
    DropFailure {
        Rejected => "rejected",
        Cancelled => "cancelled",
        Timeout => "timeout",
        Invalid => "invalid",
    }
);
string_enum!(
    /// A pointer gesture's phase. `cancel` ends it without completing it.
    GesturePhase { Begin => "begin", Update => "update", End => "end", Cancel => "cancel" }
);
string_enum!(ByeReason {
    Auth => "auth",
    Version => "version",
    Shutdown => "shutdown",
    Protocol => "protocol",
    Replaced => "replaced",
});

fn enum_field<T>(f: &Fields<'_>, key: &'static str, parse: fn(&str) -> Option<T>) -> Result<T, ProtocolError> {
    f.req(key, |v| match v {
        Value::Text(s) => parse(s),
        _ => None,
    })
}

mod devices;
pub use devices::*;

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
    pub features: Vec<String>,
    /// Random for each server process. Window ids are unique within one epoch, so a client
    /// may keep a window's last picture across a reconnect only when the epoch matches.
    pub epoch: Option<String>,
    /// Private live GPU surface namespace; absent when the service is unavailable.
    pub gpu_live_epoch: Option<[u8; 16]>,
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
    /// The desktop entry whose launch started the window's process (`<id>.desktop`).
    pub desktop_id: Option<String>,
    /// The process that owns a toplevel (`_NET_WM_PID` or the Wayland client's), when known.
    pub pid: Option<u32>,
    /// A child's visible part, relative to the parent's geometry like `geometry`.
    pub clip: Option<Rect>,
    /// A child's order among its parent's children, lowest first.
    pub stack: Option<u32>,
    /// The application holds an idle inhibitor on the window: the screen stays awake while
    /// the window is shown.
    pub idle_inhibit: bool,
    /// What the application says the window shows.
    pub content_type: ContentType,
    /// The application holds the keyboard (keyboard-shortcuts-inhibit, xwayland-keyboard-grab):
    /// the client sends it the keys it would keep for itself.
    pub keys_grabbed: bool,
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
    pub desktop_id: Option<String>,
    pub pid: Option<u32>,
    pub clip: Option<Rect>,
    pub stack: Option<u32>,
    pub idle_inhibit: Option<bool>,
    pub content_type: Option<ContentType>,
    pub keys_grabbed: Option<bool>,
}

impl WindowUpdate {
    pub fn is_empty(&self) -> bool {
        *self == WindowUpdate { id: self.id, ..Default::default() }
    }
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
    /// The application's text around the caret, while enabled and when it reports it.
    pub surrounding: Option<Surrounding>,
}

/// text-input-v3 surrounding text: at most 4000 bytes of UTF-8 around the caret, with the
/// caret (`cursor`) and the selection's other end (`anchor`) as byte offsets into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Surrounding {
    pub text: String,
    pub cursor: u64,
    pub anchor: u64,
}

/// One representation of a copy: its MIME type and its bytes.
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardEntry {
    pub mime: String,
    pub data: Vec<u8>,
}

/// `clipboard` (0x30 server → client, 0xA0 client → server): one copy, in its first
/// representation (`mime`, `data`) and the same content in other types
/// (`alternatives`, absent when there are none).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Clipboard {
    pub mime: String,
    pub data: Vec<u8>,
    pub alternatives: Vec<ClipboardEntry>,
    /// Marked secret by its source (`x-kde-passwordManagerHint: secret`): it may be
    /// pasted, but is never kept in history and reaches the phone local-only and
    /// expiring. Absent on the wire when false.
    pub secret: bool,
}

impl Clipboard {
    /// Every representation, the first one first.
    pub fn entries(&self) -> impl Iterator<Item = (&str, &[u8])> {
        std::iter::once((self.mime.as_str(), self.data.as_slice()))
            .chain(self.alternatives.iter().map(|e| (e.mime.as_str(), e.data.as_slice())))
    }

    /// The bytes of every representation together.
    pub fn total_len(&self) -> usize {
        self.entries().map(|(_, d)| d.len()).sum()
    }
}

/// `drop.enter` (0xA1): the client drags something over window `id`, at a window-local
/// position, offering it in `mimes` (clipboard types).
#[derive(Debug, Clone, PartialEq)]
pub struct DropEnter {
    pub id: u64,
    pub x: f64,
    pub y: f64,
    pub mimes: Vec<String>,
}

/// `notification` (0x31).
#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub id: u64,
    pub app: String,
    pub summary: String,
    pub body: String,
}

/// `audio` (0x40): one 20 ms Opus packet at 48 kHz.
#[derive(Debug, Clone, PartialEq)]
pub struct Audio {
    pub codec: String,
    /// Server CLOCK_MONOTONIC of the packet's first sample (the clock the server stamps everything with).
    pub pts_us: u64,
    /// 1 or 2; absent means 2.
    pub channels: Option<u32>,
    pub data: Vec<u8>,
}

/// Client → server `hello` (0x81). The client speaks first.
#[derive(Debug, Clone, PartialEq)]
pub struct ClientHello {
    pub version: u32,
    pub token: String,
    pub displays: Vec<Display>,
    /// Audio codecs the client plays (`"opus"`); absent means no audio is sent.
    pub audio_decoders: Option<Vec<String>>,
    /// The client runs games handed off to it (docs/game-handoff.md). Sent only when true.
    pub wasm: bool,
    /// The client can host agent app web views.
    pub webview: bool,
    /// The client offers its hardware as devices (docs/devices.md). Sent only when true.
    pub devices: bool,
    /// The client aims touches at the controls `targets` lists. Sent only when true.
    pub targets: bool,
    /// The client shows `child` windows inside their parents. Sent only when true.
    pub children: bool,
    /// MIME types the client takes from the computer's clipboard besides text; absent
    /// means text only.
    pub clipboard_types: Option<Vec<String>>,
}

/// A directory a game persists through IDBFS: `mount` in the game's file system, `path` on
/// the computer, relative to the home.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameSave {
    pub mount: String,
    pub path: String,
}

/// `game.create` (0x17): the window's game runs on the client (docs/game-handoff.md).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameCreate {
    pub id: u64,
    pub window: u64,
    /// The directory the game's files are served from, relative to the home.
    pub root: String,
    /// The page the client loads, relative to `root`.
    pub entry: String,
    /// Absent when the game saves nothing.
    pub saves: Option<Vec<GameSave>>,
}

/// `webview.create`: an agent app handed to the client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebviewCreate {
    pub id: u64,
    pub window: u64,
    pub app: String,
    pub bridge: String,
    pub grant: String,
    pub root: String,
    pub entry: String,
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
    /// The window's input sequence number for this scroll: per window, strictly
    /// increasing from 1 for each display session.
    pub seq: Option<u64>,
    /// The finger lifted with this velocity `[vx, vy]`, window pixels per second: the
    /// last sample of a precise scroll (docs/input.md, "Kinetic scrolling").
    pub lift: Option<[f64; 2]>,
    /// A finger touched down: kinetic scrolling stops. `dx` and `dy` are zero.
    pub hold: bool,
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
    /// Relative motion `[dx, dy]` in display pixels, without moving the pointer: a stick
    /// looking around in a game that reads relative motion (docs/display.md).
    pub relative: Option<[f64; 2]>,
}

/// One control a finger may mean, in a `targets` message: window-local display pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    pub rect: Rect,
    /// The role class (1 button, 2 toggle, 3 link, 4 menu item, 5 tab, 6 text field,
    /// 7 item, 8 adjustable, 0 other), with 0x80 set for a disabled control.
    pub kind: u8,
}

/// `targets` (0x28): the controls of window `id` a finger may mean, as its
/// accessibility tree reads them. Replaces the window's previous list; empty clears it.
#[derive(Debug, Clone, PartialEq)]
pub struct Targets {
    pub id: u64,
    /// Increases with every list the server sends in a session.
    pub serial: u64,
    pub targets: Vec<Target>,
}

/// `pinch` (0x95): a pinch on window `id`, centred at window-local `x`, `y`.
/// `scale` is the magnification since `begin` (1 at `begin`); `rotation` is degrees
/// clockwise since the previous sample (0 at `begin`); `fingers` is the finger count.
#[derive(Debug, Clone, PartialEq)]
pub struct Pinch {
    pub id: u64,
    pub phase: GesturePhase,
    pub x: f64,
    pub y: f64,
    pub scale: f64,
    pub rotation: f64,
    pub fingers: u32,
}

/// `swipe` (0x96): a multi-finger swipe on window `id`, centred at `x`, `y`;
/// `dx`, `dy` are the centre's movement since the previous sample, in display pixels.
#[derive(Debug, Clone, PartialEq)]
pub struct Swipe {
    pub id: u64,
    pub phase: GesturePhase,
    pub x: f64,
    pub y: f64,
    pub dx: f64,
    pub dy: f64,
    pub fingers: u32,
}

/// `hold` (0x99): fingers resting on window `id` at `x`, `y` without moving.
/// Only `begin`, `end` and `cancel` occur.
#[derive(Debug, Clone, PartialEq)]
pub struct Hold {
    pub id: u64,
    pub phase: GesturePhase,
    pub x: f64,
    pub y: f64,
    pub fingers: u32,
}

/// `key` (0x93).
#[derive(Debug, Clone, PartialEq)]
pub struct Key {
    pub keysym: u32,
    /// USB HID keyboard page usage, when the source is a physical key.
    pub code: Option<u32>,
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
    /// An application asked for the window to be brought forward and focused
    /// (xdg-activation, with a valid token).
    WindowActivate {
        id: u64,
    },
    Cursor(Cursor),
    CursorNamed {
        name: String,
    },
    TextInput(TextInputState),
    Targets(Targets),
    /// `text_focus` (0x29): whether window `id`'s focus, as its accessibility tree reports
    /// it, is where typed text goes (a field, a cell being edited), or not (a button, a
    /// spreadsheet's grid), whatever its input method state says.
    TextFocus {
        id: u64,
        editing: bool,
    },
    ServerClipboard(Clipboard),
    Notification(Notification),
    Audio(Audio),
    /// What each offered device became in the computer.
    DeviceStatus {
        devices: Vec<DeviceState>,
    },
    /// A computer application started using a device; `rate_hz` for motion.
    DeviceOpen {
        device: String,
        rate_hz: Option<f64>,
    },
    /// The last application using a device stopped.
    DeviceClose {
        device: String,
    },
    DeviceRumble(DeviceRumble),
    /// Send a camera keyframe next.
    DeviceKeyframe {
        device: String,
    },
    WebviewCreate(WebviewCreate),
    WebviewDestroy {
        id: u64,
    },
    GameCreate(GameCreate),
    GameDestroy {
        id: u64,
    },
    /// Whether the application under a drop from the client accepts it; absent when it
    /// answers only once it has the content, on the drop.
    DropStatus {
        accepted: Option<bool>,
    },
    /// A drop from the client finished: the application took it, or why not.
    DropResult {
        ok: bool,
        reason: Option<DropFailure>,
    },
    /// An application started dragging something the client could take.
    DragStart {
        mimes: Vec<String>,
    },
    /// The application's drag ended; `taken` if the client took it.
    DragEnd {
        taken: bool,
    },
    /// What the client took from an application's drag.
    DragData(Clipboard),
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
    Configure(Configure),
    Close {
        id: u64,
    },
    Displays {
        displays: Vec<Display>,
    },
    Touch(Touch),
    Pencil(Pencil),
    Pinch(Pinch),
    Swipe(Swipe),
    Hold(Hold),
    Pointer(Pointer),
    Key(Key),
    Text(Text),
    ClientClipboard(Clipboard),
    /// The complete set of devices the phone offers now.
    Devices {
        devices: Vec<Device>,
    },
    DeviceCamera(DeviceCamera),
    DeviceDepth(DeviceDepth),
    DeviceAudio(DeviceAudio),
    DeviceMotion(DeviceMotion),
    DeviceGamepad(DeviceGamepad),
    DeviceButton {
        device: String,
        key: DeviceKey,
        pressed: bool,
    },
    DeviceBattery(DeviceBattery),
    /// The phone cannot run a device it was asked to open.
    DeviceError {
        device: String,
        reason: String,
    },
    DropEnter(DropEnter),
    DropMotion {
        id: u64,
        x: f64,
        y: f64,
    },
    /// The client's drag left the computer's windows, or was cancelled.
    DropLeave,
    /// The client dropped: the content, as a clipboard copy carries it.
    DropPerform(Clipboard),
    /// The client takes the application's drag in progress.
    DragTake,
    /// The client cannot run game `id` (docs/game-handoff.md, "Declining"); `reason` says
    /// why, for the computer's log.
    WebviewDecline {
        id: u64,
        reason: String,
    },
    GameDecline {
        id: u64,
        reason: String,
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
    pub const WINDOW_ACTIVATE: u8 = 0x05;
    pub const GAME_CREATE: u8 = 0x17;
    pub const GAME_DESTROY: u8 = 0x18;
    pub const WEBVIEW_CREATE: u8 = 0x1C;
    pub const WEBVIEW_DESTROY: u8 = 0x1D;
    pub const CURSOR: u8 = 0x20;
    pub const CURSOR_NAMED: u8 = 0x21;
    pub const TEXT_INPUT: u8 = 0x22;
    pub const TARGETS: u8 = 0x28;
    pub const TEXT_FOCUS: u8 = 0x29;
    pub const CLIPBOARD: u8 = 0x30;
    pub const NOTIFICATION: u8 = 0x31;
    pub const DROP_STATUS: u8 = 0x32;
    pub const DROP_RESULT: u8 = 0x33;
    pub const DRAG_START: u8 = 0x34;
    pub const DRAG_END: u8 = 0x35;
    pub const DRAG_DATA: u8 = 0x36;
    pub const AUDIO: u8 = 0x40;
    pub const DEVICE_STATUS: u8 = 0x60;
    pub const DEVICE_OPEN: u8 = 0x61;
    pub const DEVICE_CLOSE: u8 = 0x62;
    pub const DEVICE_RUMBLE: u8 = 0x63;
    pub const DEVICE_KEYFRAME: u8 = 0x64;
    pub const PONG: u8 = 0x7E;
    pub const BYE: u8 = 0x7F;
    pub const CLIENT_HELLO: u8 = 0x81;
    pub const VSYNC: u8 = 0x82;
    pub const CONFIGURE: u8 = 0x84;
    pub const CLOSE: u8 = 0x85;
    pub const DISPLAYS: u8 = 0x87;
    pub const TOUCH: u8 = 0x90;
    pub const PENCIL: u8 = 0x91;
    pub const POINTER: u8 = 0x92;
    pub const KEY: u8 = 0x93;
    pub const TEXT: u8 = 0x94;
    pub const PINCH: u8 = 0x95;
    pub const SWIPE: u8 = 0x96;
    pub const GAME_DECLINE: u8 = 0x97;
    pub const WEBVIEW_DECLINE: u8 = 0x98;
    pub const HOLD: u8 = 0x99;
    pub const CLIENT_CLIPBOARD: u8 = 0xA0;
    pub const DEVICES: u8 = 0xB0;
    pub const DEVICE_CAMERA: u8 = 0xB1;
    pub const DEVICE_DEPTH: u8 = 0xB2;
    pub const DEVICE_AUDIO: u8 = 0xB3;
    pub const DEVICE_MOTION: u8 = 0xB4;
    pub const DEVICE_GAMEPAD: u8 = 0xB5;
    pub const DEVICE_BUTTON: u8 = 0xB6;
    pub const DEVICE_BATTERY: u8 = 0xB7;
    pub const DEVICE_ERROR: u8 = 0xB8;
    pub const DROP_ENTER: u8 = 0xA1;
    pub const DROP_MOTION: u8 = 0xA2;
    pub const DROP_LEAVE: u8 = 0xA3;
    pub const DROP_PERFORM: u8 = 0xA4;
    pub const DRAG_TAKE: u8 = 0xA5;
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

fn clipboard_value(c: &Clipboard) -> Value {
    let entry = |e: &ClipboardEntry| MapBuilder::new().put("mime", e.mime.as_str()).put("data", e.data.clone()).build();
    MapBuilder::new()
        .put("mime", c.mime.as_str())
        .put("data", c.data.clone())
        .opt("secret", c.secret.then_some(true))
        .opt(
            "alternatives",
            (!c.alternatives.is_empty()).then(|| Value::Array(c.alternatives.iter().map(entry).collect())),
        )
        .build()
}

fn clipboard_from(f: &Fields<'_>) -> Result<Clipboard, ProtocolError> {
    let alternatives = match f.opt("alternatives", fields::as_array)? {
        None => Vec::new(),
        Some(entries) => entries
            .iter()
            .map(|e| {
                let e = Fields::new("clipboard.alternatives", e)?;
                Ok(ClipboardEntry { mime: e.string("mime")?, data: e.bytes("data")? })
            })
            .collect::<Result<_, ProtocolError>>()?,
    };
    Ok(Clipboard {
        mime: f.string("mime")?,
        data: f.bytes("data")?,
        alternatives,
        secret: f.opt_bool("secret")?.unwrap_or(false),
    })
}

impl Message {
    pub fn type_id(&self) -> u8 {
        use type_id::*;
        match self {
            Message::ServerHello(_) => HELLO,
            Message::WindowCreate(_) => WINDOW_CREATE,
            Message::WindowUpdate(_) => WINDOW_UPDATE,
            Message::WindowDestroy { .. } => WINDOW_DESTROY,
            Message::WindowActivate { .. } => WINDOW_ACTIVATE,
            Message::Cursor(_) => CURSOR,
            Message::CursorNamed { .. } => CURSOR_NAMED,
            Message::TextInput(_) => TEXT_INPUT,
            Message::Targets(_) => TARGETS,
            Message::TextFocus { .. } => TEXT_FOCUS,
            Message::ServerClipboard(_) => CLIPBOARD,
            Message::Notification(_) => NOTIFICATION,
            Message::DropStatus { .. } => DROP_STATUS,
            Message::DropResult { .. } => DROP_RESULT,
            Message::DragStart { .. } => DRAG_START,
            Message::DragEnd { .. } => DRAG_END,
            Message::DragData(_) => DRAG_DATA,
            Message::Audio(_) => AUDIO,
            Message::DeviceStatus { .. } => DEVICE_STATUS,
            Message::DeviceOpen { .. } => DEVICE_OPEN,
            Message::DeviceClose { .. } => DEVICE_CLOSE,
            Message::DeviceRumble(_) => DEVICE_RUMBLE,
            Message::DeviceKeyframe { .. } => DEVICE_KEYFRAME,
            Message::Devices { .. } => DEVICES,
            Message::DeviceCamera(_) => DEVICE_CAMERA,
            Message::DeviceDepth(_) => DEVICE_DEPTH,
            Message::DeviceAudio(_) => DEVICE_AUDIO,
            Message::DeviceMotion(_) => DEVICE_MOTION,
            Message::DeviceGamepad(_) => DEVICE_GAMEPAD,
            Message::DeviceButton { .. } => DEVICE_BUTTON,
            Message::DeviceBattery(_) => DEVICE_BATTERY,
            Message::DeviceError { .. } => DEVICE_ERROR,
            Message::WebviewCreate(_) => WEBVIEW_CREATE,
            Message::WebviewDestroy { .. } => WEBVIEW_DESTROY,
            Message::WebviewDecline { .. } => WEBVIEW_DECLINE,
            Message::GameCreate(_) => GAME_CREATE,
            Message::GameDestroy { .. } => GAME_DESTROY,
            Message::Pong { .. } => PONG,
            Message::Bye { .. } => BYE,
            Message::ClientHello(_) => CLIENT_HELLO,
            Message::Vsync { .. } => VSYNC,
            Message::Configure(_) => CONFIGURE,
            Message::Close { .. } => CLOSE,
            Message::Displays { .. } => DISPLAYS,
            Message::Touch(_) => TOUCH,
            Message::Pencil(_) => PENCIL,
            Message::Pointer(_) => POINTER,
            Message::Key(_) => KEY,
            Message::Text(_) => TEXT,
            Message::Pinch(_) => PINCH,
            Message::Swipe(_) => SWIPE,
            Message::Hold(_) => HOLD,
            Message::ClientClipboard(_) => CLIENT_CLIPBOARD,
            Message::DropEnter(_) => DROP_ENTER,
            Message::DropMotion { .. } => DROP_MOTION,
            Message::DropLeave => DROP_LEAVE,
            Message::DropPerform(_) => DROP_PERFORM,
            Message::DragTake => DRAG_TAKE,
            Message::GameDecline { .. } => GAME_DECLINE,
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
                .put("features", m.features.clone())
                .opt("epoch", m.epoch.clone())
                .opt("gpu_live_epoch", m.gpu_live_epoch.filter(|v| v.iter().any(|b| *b != 0)).map(|v| v.to_vec()))
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
                .opt("desktop_id", m.desktop_id.clone())
                .opt("pid", m.pid)
                .opt("clip", m.clip)
                .opt("stack", m.stack)
                .opt("idle_inhibit", m.idle_inhibit.then_some(true))
                .opt("content_type", (m.content_type != ContentType::None).then_some(m.content_type))
                .opt("keys_grabbed", m.keys_grabbed.then_some(true))
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
                .opt("desktop_id", m.desktop_id.clone())
                .opt("pid", m.pid)
                .opt("clip", m.clip)
                .opt("stack", m.stack)
                .opt("idle_inhibit", m.idle_inhibit)
                .opt("content_type", m.content_type)
                .opt("keys_grabbed", m.keys_grabbed)
                .build(),
            Message::WindowDestroy { id }
            | Message::WindowActivate { id }
            | Message::Close { id }
            | Message::GameDestroy { id }
            | Message::WebviewDestroy { id } => MapBuilder::new().put("id", *id).build(),
            Message::WebviewCreate(m) => MapBuilder::new()
                .put("id", m.id)
                .put("window", m.window)
                .put("app", m.app.as_str())
                .put("bridge", m.bridge.as_str())
                .put("grant", m.grant.as_str())
                .put("root", m.root.as_str())
                .put("entry", m.entry.as_str())
                .build(),
            Message::WebviewDecline { id, reason } => {
                MapBuilder::new().put("id", *id).put("reason", reason.as_str()).build()
            }
            Message::GameDecline { id, reason } => {
                MapBuilder::new().put("id", *id).put("reason", reason.as_str()).build()
            }
            Message::GameCreate(m) => MapBuilder::new()
                .put("id", m.id)
                .put("window", m.window)
                .put("root", m.root.as_str())
                .put("entry", m.entry.as_str())
                .opt(
                    "saves",
                    m.saves.as_ref().map(|saves| {
                        Value::Array(
                            saves
                                .iter()
                                .map(|s| {
                                    MapBuilder::new()
                                        .put("mount", s.mount.as_str())
                                        .put("path", s.path.as_str())
                                        .build()
                                })
                                .collect(),
                        )
                    }),
                )
                .build(),
            Message::Targets(m) => MapBuilder::new()
                .put("id", m.id)
                .put("serial", m.serial)
                .put("targets", Value::Array(m.targets.iter().map(target_value).collect()))
                .build(),
            Message::TextFocus { id, editing } => MapBuilder::new().put("id", *id).put("editing", *editing).build(),
            Message::Cursor(m) => MapBuilder::new()
                .opt("id", m.id)
                .put("image", m.image.clone())
                .put("hotspot", Value::Array(vec![m.hotspot[0].into(), m.hotspot[1].into()]))
                .build(),
            Message::CursorNamed { name } => MapBuilder::new().put("name", name.as_str()).build(),
            Message::TextInput(m) => MapBuilder::new()
                .put("id", m.id)
                .put("enabled", m.enabled)
                .opt("purpose", m.purpose.clone())
                .opt("surrounding", m.surrounding.as_ref().map(|s| s.text.as_str()))
                .opt("cursor", m.surrounding.as_ref().map(|s| s.cursor))
                .opt("anchor", m.surrounding.as_ref().map(|s| s.anchor))
                .build(),
            Message::ServerClipboard(c)
            | Message::ClientClipboard(c)
            | Message::DragData(c)
            | Message::DropPerform(c) => clipboard_value(c),
            Message::DropStatus { accepted } => MapBuilder::new().opt("accepted", *accepted).build(),
            Message::DropResult { ok, reason } => MapBuilder::new().put("ok", *ok).opt("reason", *reason).build(),
            Message::DragStart { mimes } => MapBuilder::new().put("mimes", mimes.clone()).build(),
            Message::DragEnd { taken } => MapBuilder::new().put("taken", *taken).build(),
            Message::DropEnter(m) => {
                MapBuilder::new().put("id", m.id).put("x", m.x).put("y", m.y).put("mimes", m.mimes.clone()).build()
            }
            Message::DropMotion { id, x, y } => MapBuilder::new().put("id", *id).put("x", *x).put("y", *y).build(),
            Message::DropLeave | Message::DragTake => MapBuilder::new().build(),
            Message::Notification(m) => MapBuilder::new()
                .put("id", m.id)
                .put("app", m.app.as_str())
                .put("summary", m.summary.as_str())
                .put("body", m.body.as_str())
                .build(),
            Message::Audio(m) => MapBuilder::new()
                .put("codec", m.codec.as_str())
                .put("pts_us", m.pts_us)
                .opt("channels", m.channels)
                .put("data", m.data.clone())
                .build(),
            Message::DeviceStatus { devices } => devices::status_value(devices),
            Message::DeviceOpen { device, rate_hz } => {
                MapBuilder::new().put("device", device.as_str()).opt("rate_hz", *rate_hz).build()
            }
            Message::DeviceClose { device } | Message::DeviceKeyframe { device } => {
                MapBuilder::new().put("device", device.as_str()).build()
            }
            Message::DeviceRumble(m) => devices::rumble_value(m),
            Message::Devices { devices } => devices::devices_value(devices),
            Message::DeviceCamera(m) => devices::camera_value(m),
            Message::DeviceDepth(m) => devices::depth_value(m),
            Message::DeviceAudio(m) => devices::audio_value(m),
            Message::DeviceMotion(m) => devices::motion_value(m),
            Message::DeviceGamepad(m) => devices::gamepad_value(m),
            Message::DeviceButton { device, key, pressed } => devices::button_value(device, *key, *pressed),
            Message::DeviceBattery(m) => devices::battery_value(m),
            Message::DeviceError { device, reason } => {
                MapBuilder::new().put("device", device.as_str()).put("reason", reason.as_str()).build()
            }
            Message::Pong { t_us } | Message::Ping { t_us } => MapBuilder::new().put("t_us", *t_us).build(),
            Message::Bye { reason } => MapBuilder::new().put("reason", *reason).build(),
            Message::ClientHello(m) => MapBuilder::new()
                .put("version", m.version)
                .put("token", m.token.as_str())
                .put("displays", displays_value(&m.displays))
                .opt("audio_decoders", m.audio_decoders.clone())
                .opt("wasm", m.wasm.then_some(true))
                .opt("webview", m.webview.then_some(true))
                .opt("devices", m.devices.then_some(true))
                .opt("targets", m.targets.then_some(true))
                .opt("children", m.children.then_some(true))
                .opt("clipboard_types", m.clipboard_types.clone())
                .build(),
            Message::Vsync { display, t_us } => MapBuilder::new().put("display", *display).put("t_us", *t_us).build(),
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
            Message::Pinch(m) => MapBuilder::new()
                .put("id", m.id)
                .put("phase", m.phase)
                .put("x", m.x)
                .put("y", m.y)
                .put("scale", m.scale)
                .put("rotation", m.rotation)
                .put("fingers", m.fingers)
                .build(),
            Message::Swipe(m) => MapBuilder::new()
                .put("id", m.id)
                .put("phase", m.phase)
                .put("x", m.x)
                .put("y", m.y)
                .put("dx", m.dx)
                .put("dy", m.dy)
                .put("fingers", m.fingers)
                .build(),
            Message::Hold(m) => MapBuilder::new()
                .put("id", m.id)
                .put("phase", m.phase)
                .put("x", m.x)
                .put("y", m.y)
                .put("fingers", m.fingers)
                .build(),
            Message::Pointer(m) => MapBuilder::new()
                .put("id", m.id)
                .put("x", m.x)
                .put("y", m.y)
                .put("buttons", m.buttons)
                .opt(
                    "scroll",
                    m.scroll.as_ref().map(|s| {
                        MapBuilder::new()
                            .put("dx", s.dx)
                            .put("dy", s.dy)
                            .put("precise", s.precise)
                            .opt("seq", s.seq)
                            .opt("lift", s.lift.map(|[vx, vy]| Value::Array(vec![vx.into(), vy.into()])))
                            .opt("hold", s.hold.then_some(true))
                            .build()
                    }),
                )
                .opt("relative", m.relative.map(|[dx, dy]| Value::Array(vec![dx.into(), dy.into()])))
                .build(),
            Message::Key(m) => {
                MapBuilder::new().put("keysym", m.keysym).opt("code", m.code).put("pressed", m.pressed).put("mods", m.mods.clone()).build()
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
                features: f.strings("features")?,
                epoch: f.opt_string("epoch")?,
                gpu_live_epoch: f
                    .opt_bytes("gpu_live_epoch")
                    .ok()
                    .flatten()
                    .and_then(|v| <[u8; 16]>::try_from(v).ok())
                    .filter(|v| v.iter().any(|b| *b != 0)),
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
                desktop_id: f.opt_string("desktop_id")?,
                pid: f.opt_u32("pid")?,
                clip: f.opt_rect("clip")?,
                stack: f.opt_u32("stack")?,
                idle_inhibit: f.opt_bool("idle_inhibit")?.unwrap_or(false),
                content_type: f.opt("content_type", |v| match v {
                    Value::Text(s) => ContentType::parse(s),
                    _ => None,
                })?
                .unwrap_or(ContentType::None),
                keys_grabbed: f.opt_bool("keys_grabbed")?.unwrap_or(false),
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
                desktop_id: f.opt_string("desktop_id")?,
                pid: f.opt_u32("pid")?,
                clip: f.opt_rect("clip")?,
                stack: f.opt_u32("stack")?,
                idle_inhibit: f.opt_bool("idle_inhibit")?,
                content_type: f.opt("content_type", |v| match v {
                    Value::Text(s) => ContentType::parse(s),
                    _ => None,
                })?,
                keys_grabbed: f.opt_bool("keys_grabbed")?,
            }),
            WINDOW_DESTROY => Message::WindowDestroy { id: f.u64("id")? },
            WINDOW_ACTIVATE => Message::WindowActivate { id: f.u64("id")? },
            TARGETS => Message::Targets(Targets {
                id: f.u64("id")?,
                serial: f.u64("serial")?,
                targets: f.array("targets")?.iter().map(target_from).collect::<Result<_, _>>()?,
            }),
            TEXT_FOCUS => Message::TextFocus { id: f.u64("id")?, editing: f.bool("editing")? },
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
                surrounding: match f.opt_string("surrounding")? {
                    None => None,
                    Some(text) => {
                        let cursor = f.u64("cursor")?;
                        let anchor = f.u64("anchor")?;
                        Some(Surrounding { text, cursor, anchor })
                    }
                },
            }),
            CLIPBOARD => Message::ServerClipboard(clipboard_from(&f)?),
            DROP_STATUS => Message::DropStatus { accepted: f.opt_bool("accepted")? },
            DROP_RESULT => Message::DropResult {
                ok: f.bool("ok")?,
                reason: f.opt("reason", |v| match v {
                    Value::Text(s) => DropFailure::parse(s),
                    _ => None,
                })?,
            },
            DRAG_START => Message::DragStart { mimes: f.strings("mimes")? },
            DRAG_END => Message::DragEnd { taken: f.bool("taken")? },
            DRAG_DATA => Message::DragData(clipboard_from(&f)?),
            NOTIFICATION => Message::Notification(Notification {
                id: f.u64("id")?,
                app: f.string("app")?,
                summary: f.string("summary")?,
                body: f.string("body")?,
            }),
            AUDIO => Message::Audio(Audio {
                codec: f.string("codec")?,
                pts_us: f.u64("pts_us")?,
                channels: f.opt_u32("channels")?,
                data: f.bytes("data")?,
            }),
            WEBVIEW_CREATE => Message::WebviewCreate(WebviewCreate {
                id: f.u64("id")?,
                window: f.u64("window")?,
                app: f.string("app")?,
                bridge: f.string("bridge")?,
                grant: f.string("grant")?,
                root: f.string("root")?,
                entry: f.string("entry")?,
            }),
            WEBVIEW_DESTROY => Message::WebviewDestroy { id: f.u64("id")? },
            WEBVIEW_DECLINE => Message::WebviewDecline { id: f.u64("id")?, reason: f.string("reason")? },
            GAME_CREATE => Message::GameCreate(GameCreate {
                id: f.u64("id")?,
                window: f.u64("window")?,
                root: f.string("root")?,
                entry: f.string("entry")?,
                saves: match f.opt("saves", fields::as_array)? {
                    None => None,
                    Some(saves) => Some(
                        saves
                            .iter()
                            .map(|s| {
                                let s = Fields::new("game.create.saves", s)?;
                                Ok(GameSave { mount: s.string("mount")?, path: s.string("path")? })
                            })
                            .collect::<Result<_, ProtocolError>>()?,
                    ),
                },
            }),
            GAME_DESTROY => Message::GameDestroy { id: f.u64("id")? },
            GAME_DECLINE => Message::GameDecline { id: f.u64("id")?, reason: f.string("reason")? },
            PONG => Message::Pong { t_us: f.u64("t_us")? },
            BYE => Message::Bye { reason: enum_field(&f, "reason", ByeReason::parse)? },
            CLIENT_HELLO => Message::ClientHello(ClientHello {
                version: f.u32("version")?,
                token: f.string("token")?,
                displays: displays_from(&f)?,
                audio_decoders: match f.opt("audio_decoders", fields::as_array)? {
                    None => None,
                    Some(_) => Some(f.strings("audio_decoders")?),
                },
                wasm: f.opt_bool("wasm")?.unwrap_or(false),
                webview: f.opt_bool("webview")?.unwrap_or(false),
                devices: f.opt_bool("devices")?.unwrap_or(false),
                targets: f.opt_bool("targets")?.unwrap_or(false),
                children: f.opt_bool("children")?.unwrap_or(false),
                clipboard_types: match f.opt("clipboard_types", fields::as_array)? {
                    None => None,
                    Some(_) => Some(f.strings("clipboard_types")?),
                },
            }),
            VSYNC => Message::Vsync { display: f.u32("display")?, t_us: f.u64("t_us")? },
            CONFIGURE => Message::Configure(Configure {
                id: f.u64("id")?,
                geometry: f.opt_rect("geometry")?,
                display: f.opt_u32("display")?,
                fullscreen: f.opt_bool("fullscreen")?,
                maximized: f.opt_bool("maximized")?,
                activated: f.opt_bool("activated")?,
            }),
            CLOSE => Message::Close { id: f.u64("id")? },
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
            PINCH => Message::Pinch(Pinch {
                id: f.u64("id")?,
                phase: enum_field(&f, "phase", GesturePhase::parse)?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                scale: f.f64("scale")?,
                rotation: f.f64("rotation")?,
                fingers: f.u32("fingers")?,
            }),
            SWIPE => Message::Swipe(Swipe {
                id: f.u64("id")?,
                phase: enum_field(&f, "phase", GesturePhase::parse)?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                dx: f.f64("dx")?,
                dy: f.f64("dy")?,
                fingers: f.u32("fingers")?,
            }),
            HOLD => Message::Hold(Hold {
                id: f.u64("id")?,
                phase: enum_field(&f, "phase", GesturePhase::parse)?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                fingers: f.u32("fingers")?,
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
                        Some(Scroll {
                            dx: s.f64("dx")?,
                            dy: s.f64("dy")?,
                            precise: s.bool("precise")?,
                            seq: s.opt_u64("seq")?,
                            lift: s.opt("lift", fields::as_f64_pair)?,
                            hold: s.opt_bool("hold")?.unwrap_or(false),
                        })
                    }
                },
                relative: f.opt("relative", fields::as_f64_pair)?,
            }),
            KEY => {
                Message::Key(Key { keysym: f.u32("keysym")?, code: f.opt_u32("code")?, pressed: f.bool("pressed")?, mods: f.strings("mods")? })
            }
            TEXT => Message::Text(Text {
                commit: f.opt_string("commit")?,
                preedit: f.opt_string("preedit")?,
                cursor: f.opt("cursor", fields::as_u32_pair)?,
                delete_before: f.opt_u32("delete_before")?,
                delete_after: f.opt_u32("delete_after")?,
            }),
            CLIENT_CLIPBOARD => Message::ClientClipboard(clipboard_from(&f)?),
            DROP_ENTER => Message::DropEnter(DropEnter {
                id: f.u64("id")?,
                x: f.f64("x")?,
                y: f.f64("y")?,
                mimes: f.strings("mimes")?,
            }),
            DROP_MOTION => Message::DropMotion { id: f.u64("id")?, x: f.f64("x")?, y: f.f64("y")? },
            DROP_LEAVE => Message::DropLeave,
            DROP_PERFORM => Message::DropPerform(clipboard_from(&f)?),
            DRAG_TAKE => Message::DragTake,
            PING => Message::Ping { t_us: f.u64("t_us")? },
            DEVICE_STATUS => Message::DeviceStatus { devices: devices::status_from(&f)? },
            DEVICE_OPEN => Message::DeviceOpen { device: f.string("device")?, rate_hz: f.opt_f64("rate_hz")? },
            DEVICE_CLOSE => Message::DeviceClose { device: f.string("device")? },
            DEVICE_RUMBLE => Message::DeviceRumble(devices::rumble_from(&f)?),
            DEVICE_KEYFRAME => Message::DeviceKeyframe { device: f.string("device")? },
            DEVICES => Message::Devices { devices: devices::devices_from(&f)? },
            DEVICE_CAMERA => Message::DeviceCamera(devices::camera_from(&f)?),
            DEVICE_DEPTH => Message::DeviceDepth(devices::depth_from(&f)?),
            DEVICE_AUDIO => Message::DeviceAudio(devices::audio_from(&f)?),
            DEVICE_MOTION => Message::DeviceMotion(devices::motion_from(&f)?),
            DEVICE_GAMEPAD => Message::DeviceGamepad(devices::gamepad_from(&f)?),
            DEVICE_BUTTON => {
                let (device, key, pressed) = devices::button_from(&f)?;
                Message::DeviceButton { device, key, pressed }
            }
            DEVICE_BATTERY => Message::DeviceBattery(devices::battery_from(&f)?),
            DEVICE_ERROR => Message::DeviceError { device: f.string("device")?, reason: f.string("reason")? },
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
        WINDOW_ACTIVATE => "window.activate",
        WEBVIEW_CREATE => "webview.create",
        WEBVIEW_DESTROY => "webview.destroy",
        WEBVIEW_DECLINE => "webview.decline",
        GAME_CREATE => "game.create",
        GAME_DESTROY => "game.destroy",
        GAME_DECLINE => "game.decline",
        CURSOR => "cursor",
        CURSOR_NAMED => "cursor.named",
        TEXT_INPUT => "text_input",
        TARGETS => "targets",
        TEXT_FOCUS => "text_focus",
        CLIPBOARD | CLIENT_CLIPBOARD => "clipboard",
        NOTIFICATION => "notification",
        DROP_STATUS => "drop.status",
        DROP_RESULT => "drop.result",
        DRAG_START => "drag.start",
        DRAG_END => "drag.end",
        DRAG_DATA => "drag.data",
        DROP_ENTER => "drop.enter",
        DROP_MOTION => "drop.motion",
        DROP_LEAVE => "drop.leave",
        DROP_PERFORM => "drop.perform",
        DRAG_TAKE => "drag.take",
        AUDIO => "audio",
        PONG => "pong",
        BYE => "bye",
        VSYNC => "vsync",
        CONFIGURE => "configure",
        CLOSE => "close",
        DISPLAYS => "displays",
        TOUCH => "touch",
        PENCIL => "pencil",
        POINTER => "pointer",
        PINCH => "pinch",
        SWIPE => "swipe",
        HOLD => "hold",
        KEY => "key",
        TEXT => "text",
        PING => "ping",
        DEVICE_STATUS => "device.status",
        DEVICE_OPEN => "device.open",
        DEVICE_CLOSE => "device.close",
        DEVICE_RUMBLE => "device.rumble",
        DEVICE_KEYFRAME => "device.keyframe",
        DEVICES => "devices",
        DEVICE_CAMERA => "device.camera",
        DEVICE_DEPTH => "device.depth",
        DEVICE_AUDIO => "device.audio",
        DEVICE_MOTION => "device.motion",
        DEVICE_GAMEPAD => "device.gamepad",
        DEVICE_BUTTON => "device.button",
        DEVICE_BATTERY => "device.battery",
        DEVICE_ERROR => "device.error",
        _ => return None,
    })
}

/// `[x, y, w, h, kind]`.
fn target_value(t: &Target) -> Value {
    Value::Array(vec![t.rect.x.into(), t.rect.y.into(), t.rect.w.into(), t.rect.h.into(), (t.kind as u64).into()])
}

fn target_from(v: &Value) -> Result<Target, ProtocolError> {
    let bad = ProtocolError::Field { message: "targets", field: "targets", problem: "not [x, y, w, h, kind]" };
    let Value::Array(items) = v else { return Err(bad) };
    if items.len() != 5 {
        return Err(bad);
    }
    let int = |v: &Value| fields::as_i32(v);
    match (int(&items[0]), int(&items[1]), int(&items[2]), int(&items[3]), int(&items[4])) {
        (Some(x), Some(y), Some(w), Some(h), Some(kind)) if w >= 0 && h >= 0 && (0..=255).contains(&kind) => {
            Ok(Target { rect: Rect::new(x, y, w, h), kind: kind as u8 })
        }
        _ => Err(bad),
    }
}
