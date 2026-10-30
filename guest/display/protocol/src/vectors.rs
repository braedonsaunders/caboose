//! The golden vectors in guest/display/vectors/: exact wire bytes for every message
//! type, plus streams that exercise skipping and liberal decoding. Every client
//! implementation replays them. `cargo run -p caboose-display-protocol --example
//! write-vectors` regenerates the files; `cargo test` fails if they drift.

use crate::cbor::{self, Value};
use crate::*;

/// Real media embedded in vectors so a client can push them through its decoders.
/// Generated once by vectors/media/generate.sh and committed.
pub struct Media {
    /// One 64x64 H.264 keyframe, Annex-B, SPS/PPS included.
    pub h264_keyframe: Vec<u8>,
    /// One 64x64 HEVC keyframe, Annex-B, VPS/SPS/PPS included.
    pub hevc_keyframe: Vec<u8>,
    /// A 16x16 RGBA PNG.
    pub png: Vec<u8>,
    /// One 20 ms stereo Opus packet (a 440 Hz tone) from libopus.
    pub opus_stereo: Vec<u8>,
}

pub enum Entry {
    /// A canonical message: the bytes are `encode(message)`.
    Message(Message),
    /// A message whose payload is not canonical (other widths, key order, unknown
    /// keys). It must decode to `decodes_to`; re-encoding yields the canonical form.
    Liberal { type_id: u8, payload: Vec<u8>, decodes_to: Message },
    /// A type id no v0 peer knows; it must be skipped by length.
    Unknown { type_id: u8, payload: Vec<u8> },
}

pub struct Vector {
    pub name: &'static str,
    pub description: &'static str,
    pub entries: Vec<Entry>,
}

impl Vector {
    pub fn bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for entry in &self.entries {
            match entry {
                Entry::Message(m) => encode_into(m, &mut out),
                Entry::Liberal { type_id, payload, .. } | Entry::Unknown { type_id, payload } => {
                    out.push(*type_id);
                    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
                    out.extend_from_slice(payload);
                }
            }
        }
        out
    }

    pub fn json(&self) -> String {
        let mut out = String::new();
        out.push_str("{\n");
        out.push_str(&format!("  \"name\": {},\n", json_string(self.name)));
        out.push_str(&format!("  \"description\": {},\n", json_string(self.description)));
        out.push_str("  \"messages\": [\n");
        for (i, entry) in self.entries.iter().enumerate() {
            out.push_str("    ");
            out.push_str(&entry_json(entry));
            out.push_str(if i + 1 < self.entries.len() { ",\n" } else { "\n" });
        }
        out.push_str("  ],\n");
        out.push_str(&format!("  \"hex\": \"{}\"\n", hex(&self.bytes())));
        out.push_str("}\n");
        out
    }
}

fn entry_json(entry: &Entry) -> String {
    match entry {
        Entry::Message(m) => message_json(m, None),
        Entry::Liberal { payload, decodes_to, .. } => message_json(decodes_to, Some(payload)),
        Entry::Unknown { type_id, payload } => format!(
            "{{\"direction\": \"{}\", \"type\": null, \"type_id\": {}, \"payload_hex\": \"{}\"}}",
            direction_name(*type_id),
            type_id,
            hex(payload)
        ),
    }
}

fn message_json(m: &Message, liberal: Option<&Vec<u8>>) -> String {
    let mut s = format!(
        "{{\"direction\": \"{}\", \"type\": {}, \"type_id\": {}, \"fields\": {}",
        direction_name(m.type_id()),
        json_string(m.name()),
        m.type_id(),
        value_json(&m.to_value())
    );
    if let Some(payload) = liberal {
        s.push_str(&format!(
            ", \"payload_hex\": \"{}\", \"canonical_payload_hex\": \"{}\"",
            hex(payload),
            hex(&cbor::encode(&m.to_value()))
        ));
    }
    s.push('}');
    s
}

fn direction_name(type_id: u8) -> &'static str {
    match Direction::of(type_id) {
        Direction::ServerToClient => "server",
        Direction::ClientToServer => "client",
    }
}

/// Typed JSON for a CBOR value: byte strings are `{"$bytes": hex}`, floats are
/// `{"$float": n}`, map keys in canonical order.
pub fn value_json(v: &Value) -> String {
    match v {
        Value::Int(i) => i.to_string(),
        Value::Float(f) => format!("{{\"$float\": {f:?}}}"),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".into(),
        Value::Bytes(b) => format!("{{\"$bytes\": \"{}\"}}", hex(b)),
        Value::Text(t) => json_string(t),
        Value::Array(items) => format!("[{}]", items.iter().map(value_json).collect::<Vec<_>>().join(", ")),
        Value::Map(entries) => {
            let mut sorted: Vec<&(String, Value)> = entries.iter().collect();
            sorted.sort_by_key(|a| cbor::encode(&Value::Text(a.0.clone())));
            let body: Vec<String> =
                sorted.iter().map(|(k, v)| format!("{}: {}", json_string(k), value_json(v))).collect();
            format!("{{{}}}", body.join(", "))
        }
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn json_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn one(name: &'static str, description: &'static str, message: Message) -> Vector {
    Vector { name, description, entries: vec![Entry::Message(message)] }
}

fn phone() -> Display {
    Display { id: 1, width: 1179, height: 2556, scale: 3.0, refresh_hz: 120.0, hdr: true }
}

fn tv() -> Display {
    Display { id: 2, width: 3840, height: 2160, scale: 2.0, refresh_hz: 59.94, hdr: false }
}

/// Every vector, in a stable order.
pub fn all(media: &Media) -> Vec<Vector> {
    let terminal = WindowCreate {
        id: 7,
        parent: None,
        kind: WindowKind::Toplevel,
        title: "caboose@computer: ~ — Terminal".into(),
        app_id: "org.freedesktop.weston.wayland-terminal".into(),
        icon: Some(media.png.clone()),
        geometry: Rect::new(0, 0, 1179, 2556),
        min: Some(Size { w: 300, h: 200 }),
        max: None,
        fullscreen: false,
        display: Some(1),
        xwayland: false,
        alpha: false,
    };
    let menu = WindowCreate {
        id: 9,
        parent: Some(7),
        kind: WindowKind::Popup,
        title: String::new(),
        app_id: "chromium".into(),
        icon: None,
        geometry: Rect::new(24, -310, 480, 300),
        min: None,
        max: None,
        fullscreen: false,
        display: Some(1),
        xwayland: false,
        alpha: false,
    };
    let xterm = WindowCreate {
        id: 12,
        parent: None,
        kind: WindowKind::Toplevel,
        title: "xterm".into(),
        app_id: "XTerm".into(),
        icon: None,
        geometry: Rect::new(0, 0, 1920, 1080),
        min: Some(Size { w: 10, h: 17 }),
        max: Some(Size { w: 32767, h: 32767 }),
        fullscreen: true,
        display: Some(2),
        xwayland: true,
        alpha: false,
    };

    vec![
        one(
            "server-hello",
            "The server's answer to a valid client hello.",
            Message::ServerHello(ServerHello {
                version: 0,
                displays: vec![1, 2],
                encoders: vec![Codec::Hevc, Codec::H264],
                features: ["vsync", "ack", "touch", "text-input-v3", "cursor-named", "xwayland"]
                    .map(String::from)
                    .to_vec(),
                epoch: None,
            }),
        ),
        one(
            "server-hello-epoch",
            "A server hello with the server process's epoch, which tells a reconnecting client its window ids still name the same windows.",
            Message::ServerHello(ServerHello {
                version: 0,
                displays: vec![1],
                encoders: vec![Codec::Hevc],
                features: ["vsync", "ack"].map(String::from).to_vec(),
                epoch: Some("5f3a9c01d2e4b678".into()),
            }),
        ),
        one(
            "server-hello-atlas",
            "A zero-video server hello when the client negotiates atlas and scene.",
            Message::ServerHello(ServerHello {
                version: 0,
                displays: vec![1],
                encoders: vec![],
                features: ["vsync", "ack", "atlas", "scene"].map(String::from).to_vec(),
                epoch: Some("5f3a9c01d2e4b678".into()),
            }),
        ),
        one("window-create-toplevel", "A native Wayland toplevel with an icon and a minimum size.", Message::WindowCreate(terminal)),
        one("window-create-popup", "A popup above its parent; geometry is relative to the parent and may be negative.", Message::WindowCreate(menu)),
        one("window-create-xwayland", "A fullscreen X11 window through Xwayland on the TV display.", Message::WindowCreate(xterm)),
        one(
            "window-update-title",
            "Only the changed fields are present.",
            Message::WindowUpdate(WindowUpdate { id: 7, title: Some("vim notes.md — Terminal".into()), ..Default::default() }),
        ),
        one(
            "window-update-geometry",
            "A resize and a move to the TV display.",
            Message::WindowUpdate(WindowUpdate {
                id: 7,
                geometry: Some(Rect::new(100, 80, 1600, 900)),
                display: Some(2),
                fullscreen: Some(false),
                ..Default::default()
            }),
        ),
        one("window-destroy", "", Message::WindowDestroy { id: 9 }),
        one(
            "frame-h264-keyframe",
            "A decodable 64x64 H.264 keyframe (Annex-B with SPS/PPS) covering a 64x64 window.",
            Message::Frame(Frame {
                id: 7,
                codec: Codec::H264,
                keyframe: true,
                pts_us: 1_234_567_890,
                rect: Rect::new(0, 0, 64, 64),
                crop: Rect::new(0, 0, 64, 64),
                data: media.h264_keyframe.clone(),
            }),
        ),
        one(
            "frame-hevc-keyframe-scaled",
            "A decodable 64x64 HEVC keyframe whose visible 62x60 crop lands on a 124x120 window rect (the client scales by 2).",
            Message::Frame(Frame {
                id: 12,
                codec: Codec::Hevc,
                keyframe: true,
                pts_us: 4_294_967_296,
                rect: Rect::new(0, 0, 124, 120),
                crop: Rect::new(0, 0, 62, 60),
                data: media.hevc_keyframe.clone(),
            }),
        ),
        one(
            "tile-png",
            "A lossless tile.",
            Message::Tile(Tile { id: 7, rect: Rect::new(16, 32, 16, 16), format: TileFormat::Png, data: media.png.clone() }),
        ),
        one(
            "surface-batch",
            "An atomic byte-perfect surface damage batch with CopyRect, solid fills, cached XXH64 tile refs, and a Pal2Lz4 tile.",
            Message::SurfaceBatch(SurfaceBatch {
                id: 7,
                seq: 1,
                pts_us: 1_234_567_890,
                size: Size { w: 1179, h: 2556 },
                rect: Rect::new(0, 0, 1179, 2556),
                keyframe: true,
                copies: vec![SurfaceCopy { dx: 0, dy: -64, rect: Rect::new(0, 0, 1179, 1920) }],
                fills: vec![SurfaceFill { rect: Rect::new(0, 1920, 1179, 636), rgba: 0x1E1E2EFF }],
                refs: vec![SurfaceTileRef { x: 0, y: 0, hash: 0x9E37_79B1_85EB_CA87 }],
                tiles: vec![SurfaceTile {
                    rect: Rect::new(64, 0, 64, 64),
                    hash: Some(0xC2B2_AE3D_27D4_EB4F),
                    format: AtlasTileFormat::Pal2Lz4,
                    data: vec![0x0c, 0x00, 0x00, 0x00, 0xc0, 0x1e, 0x1e, 0x2e, 0xff, 0xff, 0xff, 0xff, 0xff, 0xAA, 0x55, 0xAA, 0x55],
                }],
            }),
        ),
        one(
            "surface-reset",
            "Resets the client's XXH64 tile cache on a new epoch.",
            Message::SurfaceReset { epoch: 2 },
        ),
        one(
            "scene-font",
            "Registers a TrueType/OpenType font face by its XXH64 hash for scene.commit glyph runs.",
            Message::SceneFont(SceneFont {
                font: 0x85EB_CA77_C2B2_AE63,
                index: 0,
                family: Some("Inter".into()),
                data: vec![0x00, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x80, 0x00, 0x03, 0x00, 0x40],
            }),
        ),
        one(
            "scene-commit",
            "A retained vector and glyph scene-graph commit with group, scroll container, and positioned glyph run.",
            Message::SceneCommit(SceneCommit {
                id: 7,
                seq: 1,
                pts_us: 1_234_567_890,
                root: 1,
                reset: true,
                nodes: vec![
                    SceneNode {
                        id: 1,
                        kind: SceneNodeKind::Group,
                        rect: Some(Rect::new(0, 0, 1179, 2556)),
                        radius: None,
                        color: None,
                        scroll: None,
                        children: Some(vec![2, 3]),
                        font: None,
                        size: None,
                        glyphs: None,
                        path: None,
                        surface: None,
                    },
                    SceneNode {
                        id: 2,
                        kind: SceneNodeKind::Scroll,
                        rect: Some(Rect::new(0, 64, 1179, 2492)),
                        radius: None,
                        color: None,
                        scroll: Some(Rect::new(0, 120, 1179, 7200)),
                        children: Some(vec![3]),
                        font: None,
                        size: None,
                        glyphs: None,
                        path: None,
                        surface: None,
                    },
                    SceneNode {
                        id: 3,
                        kind: SceneNodeKind::Glyphs,
                        rect: Some(Rect::new(24, 96, 600, 32)),
                        radius: None,
                        color: Some(0xCDD6F4FF),
                        scroll: None,
                        children: None,
                        font: Some(0x85EB_CA77_C2B2_AE63),
                        size: Some(16.0),
                        glyphs: Some(vec![0x24, 0x00, 0x00, 0x00, 0xC0, 0x41, 0x00, 0x00, 0xE0, 0x41]),
                        path: None,
                        surface: None,
                    },
                ],
                remove: vec![],
            }),
        ),
        one("cursor-image", "", Message::Cursor(Cursor { id: Some(7), image: media.png.clone(), hotspot: [3, 1] })),
        one("cursor-named-text", "A text cursor: the client may show the keyboard.", Message::CursorNamed { name: "text".into() }),
        one(
            "text-input-enabled",
            "text-input-v3 enabled on window 7 with the terminal purpose.",
            Message::TextInput(TextInputState { id: 7, enabled: true, purpose: Some("terminal".into()), surrounding: None }),
        ),
        one(
            "text-input-surrounding",
            "The application's text around the caret: 'Héllo wor|ld', the caret after 'wor' (byte 10).",
            Message::TextInput(TextInputState {
                id: 7,
                enabled: true,
                purpose: Some("normal".into()),
                surrounding: Some(Surrounding { text: "Héllo world".into(), cursor: 10, anchor: 10 }),
            }),
        ),
        one(
            "text-input-disabled",
            "",
            Message::TextInput(TextInputState { id: 7, enabled: false, purpose: None, surrounding: None }),
        ),
        one(
            "clipboard-server",
            "",
            Message::ServerClipboard(Clipboard { mime: "text/plain;charset=utf-8".into(), data: "héllo ✓".as_bytes().to_vec() }),
        ),
        one(
            "notification",
            "",
            Message::Notification(Notification {
                id: 3,
                app: "Chromium".into(),
                summary: "Download complete".into(),
                body: "report.pdf\n2.1 MB".into(),
            }),
        ),
        one(
            "audio-opus",
            "One 20 ms Opus packet (a valid silence frame).",
            Message::Audio(Audio { codec: "opus".into(), pts_us: 1_234_580_000, channels: None, data: vec![0xf8, 0xff, 0xfe] }),
        ),
        one(
            "video-create-passthrough",
            "A passthrough HEVC stream in BT.2020 PQ (H.273: primaries 9, transfer 16, matrix 9), clipped by the 1080 crop of a 1088-line picture.",
            Message::VideoCreate(VideoCreate {
                id: 1,
                window: 7,
                rect: Rect::new(0, 120, 1179, 663),
                clip: Some(Rect::new(0, 120, 1179, 660)),
                z: Some(0),
                codec: Codec::Hevc,
                source: VideoSource::Passthrough,
                color: Some(VideoColor { primaries: 9, transfer: 16, matrix: 9, full_range: false }),
                extradata: None,
                scaled: false,
            }),
        ),
        one(
            "video-create-surface",
            "A YUV subsurface streamed as video at its own size; no clip, z and colour default.",
            Message::VideoCreate(VideoCreate {
                id: 2,
                window: 12,
                rect: Rect::new(40, 80, 1280, 720),
                clip: None,
                z: None,
                codec: Codec::H264,
                source: VideoSource::Surface,
                color: None,
                extradata: None,
                scaled: false,
            }),
        ),
        one(
            "video-create-scaled-motion",
            "A half-resolution motion picture placed in window coordinates.",
            Message::VideoCreate(VideoCreate {
                id: 3, window: 12, rect: Rect::new(40, 80, 640, 360), clip: None, z: None,
                codec: Codec::H264, source: VideoSource::Motion, color: None, extradata: None, scaled: true,
            }),
        ),
        one(
            "video-frame-passthrough",
            "Decode order only: no pts_us; video.present says when it shows. The data is a decodable H.264 keyframe.",
            Message::VideoFrame(VideoFrame { id: 1, seq: 0, keyframe: true, pts_us: None, data: media.h264_keyframe.clone() }),
        ),
        one(
            "video-frame-surface",
            "A surface stream's frame, shown as soon as it is decoded; pts_us is the commit time.",
            Message::VideoFrame(VideoFrame { id: 2, seq: 41, keyframe: false, pts_us: Some(1_234_600_000), data: vec![0, 0, 0, 1, 0x41, 0x9a, 0x02] }),
        ),
        one(
            "video-update",
            "Scrolled partly under the window's top edge.",
            Message::VideoUpdate(VideoUpdate { id: 1, rect: Some(Rect::new(0, -200, 1179, 663)), clip: Some(Rect::new(0, 0, 1179, 463)), z: None }),
        ),
        one("video-destroy", "", Message::VideoDestroy { id: 1 }),
        one(
            "video-present",
            "The application is showing frame 17 of stream 1 now.",
            Message::VideoPresent { id: 1, seq: 17, pts_us: 1_234_633_333 },
        ),
        one("video-ack", "", Message::VideoAck { id: 2, seq: 41 }),
        one(
            "game-create",
            "Window 7's game runs on the client: its files are served from root, it loads entry, and it persists /powder in a directory of the home.",
            Message::GameCreate(GameCreate {
                id: 1,
                window: 7,
                root: ".local/share/caboose/games/powder-toy/web".into(),
                entry: "index.html".into(),
                saves: Some(vec![GameSave { mount: "/powder".into(), path: ".local/share/The Powder Toy".into() }]),
            }),
        ),
        one(
            "game-create-no-saves",
            "A game that saves nothing: no saves key.",
            Message::GameCreate(GameCreate {
                id: 2,
                window: 12,
                root: "Games/doom".into(),
                entry: "index.html".into(),
                saves: None,
            }),
        ),
        one("webview-create", "An agent app on window 7.", Message::WebviewCreate(WebviewCreate {
            id: 1, window: 7, app: "notes".into(), bridge: "0123456789abcdef0123456789abcdef".into(), grant: "fedcba9876543210fedcba9876543210".into(), root: "Apps/notes".into(), entry: "index.html".into(),
        })),
        one("webview-destroy", "", Message::WebviewDestroy { id: 1 }),
        one("webview-decline", "", Message::WebviewDecline { id: 1, reason: "web view failed".into() }),
        one("game-destroy", "", Message::GameDestroy { id: 1 }),
        one("gpu-create", "Window 7's pictures are a Vulkan stream the client renders.", Message::GpuCreate { id: 1, window: 7 }),
        one(
            "gpu-data",
            "The first bytes of stream 1: a GFXReconstruct file header (fourcc GFXR, format 0.0, no options).",
            Message::GpuData(GpuData { id: 1, offset: 0, data: b"GFXR\0\0\0\0\0\0\0\0\0\0\0\0".to_vec() }),
        ),
        one("gpu-destroy", "", Message::GpuDestroy { id: 1, reason: None }),
        one(
            "gpu-destroy-spool-limit",
            "The computer stopped keeping stream 1: it outgrew the spool limit.",
            Message::GpuDestroy { id: 1, reason: Some("spool-limit".into()) },
        ),
        one("gpu-ack", "The client has consumed stream 1 up to byte 65536.", Message::GpuAck { id: 1, offset: 65536 }),
        one(
            "game-decline",
            "The client cannot run game 1: its page needs threads the device would not give it.",
            Message::GameDecline { id: 1, reason: "the page is not cross-origin isolated".into() },
        ),
        one("video-keyframe", "", Message::VideoKeyframe { id: 1 }),
        one(
            "audio-opus-stereo",
            "A decodable 20 ms stereo Opus packet (a 440 Hz tone, libopus), as the server sends: channels 2.",
            Message::Audio(Audio { codec: "opus".into(), pts_us: 1_234_600_000, channels: Some(2), data: media.opus_stereo.clone() }),
        ),
        one(
            "device-status",
            "The camera became /dev/video4; the computer's kernel has no UHID for the battery.",
            Message::DeviceStatus {
                devices: vec![
                    DeviceState { id: "camera-back".into(), nodes: vec!["/dev/video4".into()], error: None },
                    DeviceState {
                        id: "battery".into(),
                        nodes: vec![],
                        error: Some("This computer's kernel has no UHID".into()),
                    },
                ],
            },
        ),
        one("device-open", "Motion opened at 100 Hz.", Message::DeviceOpen { device: "motion".into(), rate_hz: Some(100.0) }),
        one("device-close", "", Message::DeviceClose { device: "camera-back".into() }),
        one(
            "device-rumble",
            "",
            Message::DeviceRumble(DeviceRumble { device: "gamepad-1".into(), strong: 1.0, weak: 0.25, ms: 250 }),
        ),
        one("device-keyframe", "", Message::DeviceKeyframe { device: "camera-back".into() }),
        one("pong", "", Message::Pong { t_us: 98_765_432_100 }),
        one("bye-auth", "Sent before closing on a token mismatch.", Message::Bye { reason: ByeReason::Auth }),
        one(
            "bye-replaced",
            "Sent to a client when another client takes over the display.",
            Message::Bye { reason: ByeReason::Replaced },
        ),
        one(
            "client-hello",
            "A phone with a TV attached.",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::Av1, Codec::H264],
                displays: vec![phone(), tv()],
                video_decoders: None,
                audio_decoders: None,
                wasm: false,
                webview: false,
                gpu: false,
                scaled_motion: false,
                devices: false,
                atlas: false,
                scene: false,
            }),
        ),
        one(
            "client-hello-scaled-motion",
            "A client accepts half-resolution motion without enabling passthrough video.",
            Message::ClientHello(ClientHello {
                version: 0, token: "f3a9c1d27e8b4a6f".into(), decoders: vec![Codec::H264], displays: vec![phone()],
                video_decoders: None, audio_decoders: None, wasm: false, webview: false, gpu: false, scaled_motion: true, devices: false,
                atlas: false, scene: false,
            }),
        ),
        one(
            "client-hello-video",
            "A client that also plays video streams: HEVC and H.264, not VP9 (left to the window stream).",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::H264],
                displays: vec![phone()],
                video_decoders: Some(vec![Codec::Hevc, Codec::H264]),
                audio_decoders: None,
                wasm: false,
                webview: false,
                gpu: false,
                scaled_motion: false,
                devices: false,
                atlas: false,
                scene: false,
            }),
        ),
        one(
            "client-hello-audio",
            "client-hello-video plus the computer's sound.",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::H264],
                displays: vec![phone()],
                video_decoders: Some(vec![Codec::Hevc, Codec::H264]),
                audio_decoders: Some(vec!["opus".into()]),
                wasm: false,
                webview: false,
                gpu: false,
                scaled_motion: false,
                devices: false,
                atlas: false,
                scene: false,
            }),
        ),
        one(
            "client-hello-gpu",
            "client-hello-audio from a client that also renders Vulkan streams.",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::H264],
                displays: vec![phone()],
                video_decoders: Some(vec![Codec::Hevc, Codec::H264]),
                audio_decoders: Some(vec!["opus".into()]),
                wasm: false,
                webview: false,
                gpu: true,
                scaled_motion: false,
                devices: false,
                atlas: false,
                scene: false,
            }),
        ),
        one(
            "client-hello-wasm",
            "client-hello-audio from a client that also runs games handed off to it.",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::H264],
                displays: vec![phone()],
                video_decoders: Some(vec![Codec::Hevc, Codec::H264]),
                audio_decoders: Some(vec!["opus".into()]),
                wasm: true,
                webview: false,
                gpu: false,
                scaled_motion: false,
                devices: false,
                atlas: false,
                scene: false,
            }),
        ),
        one(
            "client-hello-webview",
            "A client that runs agent app web views.",
            Message::ClientHello(ClientHello {
                version: 0, token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::H264], displays: vec![phone()],
                video_decoders: None, audio_decoders: None, wasm: false, webview: true, gpu: false, scaled_motion: false,
                devices: false, atlas: false, scene: false,
            }),
        ),
        one(
            "client-hello-devices",
            "client-hello-audio from a phone that offers its hardware as devices.",
            Message::ClientHello(ClientHello {
                version: 0, token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![Codec::Hevc, Codec::H264], displays: vec![phone()],
                video_decoders: None, audio_decoders: Some(vec!["opus".into()]), wasm: false, webview: false, gpu: false,
                scaled_motion: false, devices: true, atlas: false, scene: false,
            }),
        ),
        one(
            "client-hello-atlas",
            "Zero-video client hello advertising Surface Atlas and Scene Graph support with empty window decoders.",
            Message::ClientHello(ClientHello {
                version: 0,
                token: "f3a9c1d27e8b4a6f".into(),
                decoders: vec![],
                displays: vec![phone()],
                video_decoders: Some(vec![Codec::Hevc, Codec::H264]),
                audio_decoders: Some(vec!["opus".into()]),
                wasm: false,
                webview: false,
                gpu: false,
                scaled_motion: false,
                devices: false,
                atlas: true,
                scene: true,
            }),
        ),
        one(
            "devices",
            "A phone offering a camera, its depth sensor, microphone, motion sensors, a controller, buttons and battery.",
            Message::Devices {
                devices: vec![
                    Device {
                        position: Some(CameraPosition::Back),
                        size: Some(Size { w: 1280, h: 720 }),
                        fps: Some(30.0),
                        ..Device::new("camera-back", DeviceKind::Camera, "iPhone Back Camera")
                    },
                    Device {
                        position: Some(CameraPosition::Back),
                        size: Some(Size { w: 256, h: 192 }),
                        fps: Some(15.0),
                        ..Device::new("depth", DeviceKind::Depth, "iPhone Depth")
                    },
                    Device::new("microphone", DeviceKind::Microphone, "iPhone Microphone"),
                    Device {
                        sensors: Some(vec![
                            MotionSensor::Accelerometer,
                            MotionSensor::Gyroscope,
                            MotionSensor::Magnetometer,
                            MotionSensor::Rotation,
                            MotionSensor::Pressure,
                        ]),
                        ..Device::new("motion", DeviceKind::Motion, "iPhone Motion Sensors")
                    },
                    Device { rumble: Some(true), ..Device::new("gamepad-1", DeviceKind::Gamepad, "DualSense Wireless Controller") },
                    Device {
                        keys: Some(vec![DeviceKey::VolumeUp, DeviceKey::VolumeDown, DeviceKey::Camera, DeviceKey::Action]),
                        ..Device::new("buttons", DeviceKind::Buttons, "iPhone Buttons")
                    },
                    Device::new("battery", DeviceKind::Battery, "iPhone Battery"),
                ],
            },
        ),
        Vector {
            name: "liberal-devices-future",
            description: "Not canonical: a device of a kind this version does not know and a sensor name it does not know. The unknown device is skipped and the unknown sensor dropped.",
            entries: vec![Entry::Liberal {
                type_id: type_id::DEVICES,
                payload: cbor::encode(&Value::Map(vec![(
                    "devices".into(),
                    Value::Array(vec![
                        Value::Map(vec![
                            ("id".into(), Value::Text("lidar-mesh".into())),
                            ("kind".into(), Value::Text("mesh".into())),
                            ("name".into(), Value::Text("iPhone Scene".into())),
                        ]),
                        Value::Map(vec![
                            ("id".into(), Value::Text("motion".into())),
                            ("kind".into(), Value::Text("motion".into())),
                            ("name".into(), Value::Text("iPhone Motion Sensors".into())),
                            ("sensors".into(), Value::Array(vec![Value::Text("accelerometer".into()), Value::Text("lux".into())])),
                        ]),
                    ]),
                )])),
                decodes_to: Message::Devices {
                    devices: vec![Device {
                        sensors: Some(vec![MotionSensor::Accelerometer]),
                        ..Device::new("motion", DeviceKind::Motion, "iPhone Motion Sensors")
                    }],
                },
            }],
        },
        one(
            "device-camera",
            "A camera keyframe: the 64x64 H.264 keyframe with its SPS and PPS.",
            Message::DeviceCamera(DeviceCamera {
                device: "camera-back".into(),
                seq: 0,
                keyframe: true,
                t_us: 77_000_033_333,
                data: media.h264_keyframe.clone(),
            }),
        ),
        one(
            "device-depth",
            "A 2x2 depth picture: 1 m, 1.5 m, no reading, 4 m.",
            Message::DeviceDepth(DeviceDepth {
                device: "depth".into(),
                t_us: 77_000_066_666,
                size: Size { w: 2, h: 2 },
                data: [1000u16, 1500, 0, 4000].iter().flat_map(|d| d.to_le_bytes()).collect(),
            }),
        ),
        one(
            "device-audio",
            "One 20 ms mono Opus packet (a valid silence frame).",
            Message::DeviceAudio(DeviceAudio { device: "microphone".into(), t_us: 77_000_020_000, data: vec![0xf8, 0xff, 0xfe] }),
        ),
        one(
            "device-motion",
            "Two samples of a phone lying face up: the first from every sensor, the second accelerometer and gyroscope only.",
            Message::DeviceMotion(DeviceMotion {
                device: "motion".into(),
                samples: vec![
                    MotionSample {
                        t_us: 77_000_000_000,
                        accel: Some([0.0, 0.0, 9.80665]),
                        gyro: Some([0.0, 0.0, 0.0]),
                        magnet: Some([21.5, -4.25, -40.0]),
                        rotation: Some([0.0, 0.0, 0.0, 1.0]),
                        pressure: Some(101.325),
                    },
                    MotionSample {
                        t_us: 77_000_010_000,
                        accel: Some([0.125, -0.5, 9.75]),
                        gyro: Some([0.01, -0.02, 0.5]),
                        ..Default::default()
                    },
                ],
            }),
        ),
        one(
            "device-gamepad",
            "A held, the left stick pushed up and right, the right trigger half pulled.",
            Message::DeviceGamepad(DeviceGamepad {
                device: "gamepad-1".into(),
                buttons: gamepad_buttons::SOUTH,
                axes: [0.5, 1.0, 0.0, 0.0, 0.0, 0.5],
            }),
        ),
        one(
            "device-button",
            "Volume up pressed while a camera streams.",
            Message::DeviceButton { device: "buttons".into(), key: DeviceKey::VolumeUp, pressed: true },
        ),
        one(
            "device-battery",
            "",
            Message::DeviceBattery(DeviceBattery {
                device: "battery".into(),
                level: 0.75,
                charging: true,
                full: false,
                low_power: false,
                thermal: ThermalState::Fair,
            }),
        ),
        one(
            "device-error",
            "",
            Message::DeviceError { device: "camera-back".into(), reason: "Camera access is off in Settings".into() },
        ),
        one("vsync", "", Message::Vsync { display: 1, t_us: 5_000_008_333 }),
        one("ack", "", Message::Ack { id: 7, pts_us: 1_234_567_890, decoded_us: 2150 }),
        one("ack-decode-failed", "decoded_us is -1 when decoding failed; a request_keyframe follows.", Message::Ack { id: 7, pts_us: 1_234_567_890, decoded_us: -1 }),
        one(
            "configure",
            "",
            Message::Configure(Configure {
                id: 7,
                geometry: Some(Rect::new(0, 0, 2556, 1179)),
                display: Some(1),
                fullscreen: None,
                maximized: Some(true),
                activated: Some(true),
            }),
        ),
        one("close", "", Message::Close { id: 7 }),
        one("request-keyframe", "", Message::RequestKeyframe { id: 7 }),
        one(
            "displays",
            "The phone rotated and the TV unplugged.",
            Message::Displays {
                displays: vec![Display { id: 1, width: 2556, height: 1179, scale: 3.0, refresh_hz: 120.0, hdr: true }],
            },
        ),
        one(
            "touch-two-fingers",
            "Two contacts in one wl_touch.frame.",
            Message::Touch(Touch {
                id: 7,
                points: vec![
                    TouchPoint { slot: 0, phase: TouchPhase::Motion, x: 512.5, y: 900.25, force: Some(0.5), radius: Some(21.0) },
                    TouchPoint { slot: 1, phase: TouchPhase::Down, x: 700.0, y: 1200.75, force: None, radius: None },
                ],
            }),
        ),
        one(
            "pencil-hover",
            "",
            Message::Pencil(Pencil {
                id: 7,
                phase: PencilPhase::Hover,
                x: 300.5,
                y: 410.0,
                pressure: 0.0,
                tilt: [12.5, -30.0],
                azimuth_deg: 271.25,
            }),
        ),
        one(
            "pointer-left-drag",
            "",
            Message::Pointer(Pointer { id: 7, x: 10.5, y: 20.0, buttons: buttons::LEFT, scroll: None }),
        ),
        one(
            "pointer-scroll-precise",
            "Pixel scroll with no buttons held.",
            Message::Pointer(Pointer {
                id: 7,
                x: 640.0,
                y: 480.0,
                buttons: 0,
                scroll: Some(Scroll { dx: 0.0, dy: -42.5, precise: true }),
            }),
        ),
        one(
            "key-shift-a",
            "Keysym 0x41 (A) pressed with shift held.",
            Message::Key(Key { keysym: 0x41, pressed: true, mods: vec!["shift".into()] }),
        ),
        one("text-commit", "", Message::Text(Text { commit: Some("naïve café 👍".into()), ..Default::default() })),
        one(
            "text-preedit",
            "Marked text (CJK input) with the caret after the first character (3 UTF-8 bytes).",
            Message::Text(Text { preedit: Some("にほん".into()), cursor: Some([3, 3]), ..Default::default() }),
        ),
        one(
            "text-replace",
            "Autocorrect: delete two grapheme clusters before the cursor and commit the replacement.",
            Message::Text(Text { commit: Some("the ".into()), delete_before: Some(2), ..Default::default() }),
        ),
        one(
            "scene-scroll",
            "Client-predicted scroll offset synced back to the guest.",
            Message::SceneScroll(SceneScroll { id: 7, node: 2, sx: 0.0, sy: 240.5 }),
        ),
        one(
            "clipboard-client",
            "",
            Message::ClientClipboard(Clipboard { mime: "text/plain;charset=utf-8".into(), data: b"copied on the phone".to_vec() }),
        ),
        one("ping", "", Message::Ping { t_us: 98_765_432_100 }),
        Vector {
            name: "stream-unknown-skipped",
            description: "Three server messages back to back with an unknown type 0x50 between them; a v0 client skips it by length.",
            entries: vec![
                Entry::Message(Message::CursorNamed { name: "default".into() }),
                Entry::Unknown { type_id: 0x50, payload: cbor::encode(&Value::Map(vec![("future".into(), Value::Bool(true))])) },
                Entry::Message(Message::WindowDestroy { id: 12 }),
            ],
        },
        Vector {
            name: "liberal-window-update",
            description: "Not canonical: keys out of order, an id as uint32, a float16 where none is needed, an unknown key. It must decode; re-encoding gives the canonical payload.",
            entries: vec![Entry::Liberal {
                type_id: type_id::WINDOW_UPDATE,
                // {"title": "x", "future_key": [1.5 as float16], "id": 7 as u32}
                payload: {
                    let mut p = vec![0xa3, 0x65];
                    p.extend_from_slice(b"title");
                    p.extend_from_slice(&[0x61, b'x', 0x6a]);
                    p.extend_from_slice(b"future_key");
                    p.extend_from_slice(&[0x81, 0xf9, 0x3e, 0x00, 0x62]);
                    p.extend_from_slice(b"id");
                    p.extend_from_slice(&[0x1a, 0, 0, 0, 7]);
                    p
                },
                decodes_to: Message::WindowUpdate(WindowUpdate { id: 7, title: Some("x".into()), ..Default::default() }),
            }],
        },
        Vector {
            name: "liberal-vsync-wide-int",
            description: "Not canonical: a uint64-width integer for t_us and keys reversed.",
            entries: vec![Entry::Liberal {
                type_id: type_id::VSYNC,
                payload: {
                    let mut p = vec![0xa2, 0x64];
                    p.extend_from_slice(b"t_us");
                    p.push(0x1b);
                    p.extend_from_slice(&1000u64.to_be_bytes());
                    p.push(0x67);
                    p.extend_from_slice(b"display");
                    p.push(0x01);
                    p
                },
                decodes_to: Message::Vsync { display: 1, t_us: 1000 },
            }],
        },
    ]
}
