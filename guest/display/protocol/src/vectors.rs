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
        one("cursor-image", "", Message::Cursor(Cursor { id: Some(7), image: media.png.clone(), hotspot: [3, 1] })),
        one("cursor-named-text", "A text cursor: the client may show the keyboard.", Message::CursorNamed { name: "text".into() }),
        one(
            "text-input-enabled",
            "text-input-v3 enabled on window 7 with the terminal purpose.",
            Message::TextInput(TextInputState { id: 7, enabled: true, purpose: Some("terminal".into()) }),
        ),
        one("text-input-disabled", "", Message::TextInput(TextInputState { id: 7, enabled: false, purpose: None })),
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
        one("video-keyframe", "", Message::VideoKeyframe { id: 1 }),
        one(
            "audio-opus-stereo",
            "A decodable 20 ms stereo Opus packet (a 440 Hz tone, libopus), as the server sends: channels 2.",
            Message::Audio(Audio { codec: "opus".into(), pts_us: 1_234_600_000, channels: Some(2), data: media.opus_stereo.clone() }),
        ),
        one("pong", "", Message::Pong { t_us: 98_765_432_100 }),
        one("bye-auth", "Sent before closing on a token mismatch.", Message::Bye { reason: ByeReason::Auth }),
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
            }),
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
