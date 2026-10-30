//! caboose-display-probe: a headless Caboose Display client for scripted checks.
//!
//! It connects like the phone does (hello with token and displays), ticks vsync at the
//! display's refresh rate, decodes every frame with libavcodec, acknowledges each one
//! with its decode time, and reports per-window fps, bitrate, decode time and latency.
//! With `--server-pid` it also reports the server's CPU time per frame and overall.

use caboose_display_protocol::{self as proto, Codec, Decoded, Message, StreamDecoder};
use ffmpeg_next as ff;
use std::collections::BTreeMap;
use std::io::{ErrorKind, Write as _};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message as WsMessage, WebSocket};

const USAGE: &str = "\
caboose-display-probe: headless Caboose Display client

USAGE:
    caboose-display-probe [OPTIONS]

OPTIONS:
    --url URL              server [default: ws://127.0.0.1:14600/]
    --token TOKEN          display token
    --token-file PATH      read the token from a file
    --display WxH@HZxS     a display to announce (repeatable) [default: 1920x1080@60x1]
    --decoders LIST        comma-separated codecs [default: hevc,h264]
    --video-decoders LIST  codecs to accept as video.* streams [default: none]
    --scaled-motion        accept half-resolution motion streams
    --copy                 apply frame.copy (scrolls as a copy within the picture plus tiles)
    --audio                play the computer's sound (decoded and measured, not heard)
    --wasm                 run games handed off to the client (reports game.create and
                           game.destroy; a game's window is a target like any other)
    --gpu-save DIR         take Vulkan streams (gpu.*): write each to DIR/gpu-<id>.gfxr and
                           acknowledge what was written
    --duration SECS        how long to run [default: 10]
    --stall-after SECS     then stop reading and sending, the socket left open (a
                           suspended client)
    --windows N            fail unless at least N windows appear
    --min-fps F            fail unless the busiest window reaches F fps
    --save DIR             write each window's last picture (PNG) and stream here
    --server-pid PID       report the server's CPU time from /proc
    --type TEXT            once a window shows, send TEXT as a text commit to it
    --click X,Y            once a window shows, click there (window-local pixels)
    --touch X,Y            once a window shows, tap there with one finger
    --window ID            the window --actions are for [default: the first that shows]
    --actions LIST         once a window shows, run `;`-separated actions 300 ms apart:
                           key:KEYSYM[+mod...] (press and release; mods shift, control,
                           mod1, mod4), text:STRING, edit:N:STRING (delete N before,
                           then commit), copy:STRING (the phone's clipboard), tap:X,Y,
                           click:X,Y, wait:MS, maximize (fill the display),
                           scroll:X,Y,DY (precise, DY pixels), resize:W,H, close,
                           decline (refuse the game handed to the probe, as a device that
                           cannot run it does),
                           finger-down:X,Y, finger-move:X,Y, finger-up:X,Y (16 ms apart)
    --check                exit 0 as soon as the server answers hello (readiness probe)
    --json                 print the report as one JSON line
";

struct Args {
    url: String,
    token: String,
    displays: Vec<proto::Display>,
    decoders: Vec<Codec>,
    video_decoders: Option<Vec<Codec>>,
    scaled_motion: bool,
    copy: bool,
    audio: bool,
    wasm: bool,
    gpu_save: Option<PathBuf>,
    duration: Duration,
    /// Stop reading and sending after this long, keeping the connection open.
    stall_after: Option<Duration>,
    windows: Option<usize>,
    min_fps: Option<f64>,
    save: Option<PathBuf>,
    server_pid: Option<u32>,
    type_text: Option<String>,
    click: Option<(f64, f64)>,
    touch: Option<(f64, f64)>,
    actions: Vec<String>,
    window: Option<u64>,
    check: bool,
    json: bool,
}

fn parse_display(id: u32, s: &str) -> Option<proto::Display> {
    let (size, rest) = s.split_once('@').unwrap_or((s, "60x1"));
    let (w, h) = size.split_once('x')?;
    let (hz, scale) = rest.split_once('x').unwrap_or((rest, "1"));
    Some(proto::Display {
        id,
        width: w.parse().ok()?,
        height: h.parse().ok()?,
        scale: scale.parse().ok()?,
        refresh_hz: hz.parse().ok()?,
        hdr: false,
    })
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        url: "ws://127.0.0.1:14600/".into(),
        token: String::new(),
        displays: Vec::new(),
        decoders: vec![Codec::Hevc, Codec::H264],
        video_decoders: None,
        scaled_motion: false,
        copy: false,
        audio: false,
        wasm: false,
        gpu_save: None,
        duration: Duration::from_secs(10),
        stall_after: None,
        windows: None,
        min_fps: None,
        save: None,
        server_pid: None,
        type_text: None,
        click: None,
        touch: None,
        actions: Vec::new(),
        window: None,
        check: false,
        json: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--url" => a.url = value()?,
            "--token" => a.token = value()?,
            "--token-file" => {
                let path = value()?;
                a.token = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?.trim().to_owned();
            }
            "--display" => {
                let v = value()?;
                let id = a.displays.len() as u32 + 1;
                a.displays.push(parse_display(id, &v).ok_or_else(|| format!("bad --display {v}"))?);
            }
            "--audio" => a.audio = true,
            "--scaled-motion" => a.scaled_motion = true,
            "--copy" => a.copy = true,
            "--wasm" => a.wasm = true,
            "--gpu-save" => a.gpu_save = Some(value()?.into()),
            "--video-decoders" => {
                a.video_decoders = Some(
                    value()?
                        .split(',')
                        .map(|c| Codec::parse(c.trim()).ok_or(format!("unknown codec {c}")))
                        .collect::<Result<_, _>>()?,
                );
            }
            "--decoders" => {
                a.decoders = value()?
                    .split(',')
                    .map(|c| Codec::parse(c.trim()).ok_or(format!("unknown codec {c}")))
                    .collect::<Result<_, _>>()?;
            }
            "--duration" => a.duration = Duration::from_secs_f64(value()?.parse().map_err(|_| "bad --duration")?),
            "--stall-after" => {
                a.stall_after = Some(Duration::from_secs_f64(value()?.parse().map_err(|_| "bad --stall-after")?))
            }
            "--windows" => a.windows = Some(value()?.parse().map_err(|_| "bad --windows")?),
            "--min-fps" => a.min_fps = Some(value()?.parse().map_err(|_| "bad --min-fps")?),
            "--save" => a.save = Some(value()?.into()),
            "--server-pid" => a.server_pid = Some(value()?.parse().map_err(|_| "bad --server-pid")?),
            "--type" => a.type_text = Some(value()?),
            "--click" | "--touch" => {
                let v = value()?;
                let bad = || format!("bad {arg} {v}");
                let (x, y) = v.split_once(',').ok_or_else(bad)?;
                let point = Some((x.parse().map_err(|_| bad())?, y.parse().map_err(|_| bad())?));
                if arg == "--click" {
                    a.click = point;
                } else {
                    a.touch = point;
                }
            }
            "--actions" => a.actions = value()?.split(';').map(str::to_owned).filter(|s| !s.is_empty()).collect(),
            "--window" => a.window = Some(value()?.parse().map_err(|_| "bad --window")?),
            "--check" => a.check = true,
            "--json" => a.json = true,
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    if a.displays.is_empty() {
        a.displays.push(parse_display(1, "1920x1080@60x1").unwrap());
    }
    Ok(a)
}

fn monotonic_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes the timespec it is given.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000
}

/// utime + stime of a process, in milliseconds.
fn process_cpu_ms(pid: u32) -> Option<f64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 2..];
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let utime: f64 = fields.get(11)?.parse().ok()?;
    let stime: f64 = fields.get(12)?.parse().ok()?;
    // SAFETY: sysconf has no preconditions.
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    Some((utime + stime) * 1000.0 / ticks)
}

struct GpuStats {
    window: u64,
    bytes: u64,
    file: Option<std::fs::File>,
    destroyed: bool,
    reason: Option<String>,
}

struct GameStats {
    game: proto::GameCreate,
    destroyed: bool,
}

#[derive(Default)]
struct WindowStats {
    title: String,
    kind: &'static str,
    parent: Option<u64>,
    geometry: proto::Rect,
    frames: u64,
    keyframes: u64,
    bytes: u64,
    decode_us: Vec<u64>,
    latency_us: Vec<u64>,
    decode_errors: u64,
    first: Option<Instant>,
    last: Option<Instant>,
    codec: Option<Codec>,
    size: (u32, u32),
    /// The first frame received was a keyframe.
    first_keyframe: bool,
    /// Picture sizes seen, and whether each new size began with a keyframe.
    sizes: u64,
    resized_without_keyframe: bool,
    last_crop: Option<(i32, i32)>,
    destroyed: bool,
    tiles: u64,
    tile_bytes: u64,
    /// Tiles that did not decode or came before any picture.
    tile_errors: u64,
    copies: u64,
    /// Distinct observed picture displacements, bounded for long-running probes.
    copy_shifts: Vec<[i32; 2]>,
    /// Copies that came before any picture.
    copy_errors: u64,
}

/// The `audio` stream as received.
#[derive(Default)]
struct AudioStats {
    packets: u64,
    bytes: u64,
    decoded: u64,
    errors: u64,
    channels: u32,
    /// Largest absolute sample, 0..1.
    peak: f32,
    /// Jumps in pts larger than a packet (silence that was not sent).
    gaps: u64,
    last_pts: Option<u64>,
    decoder: Option<ff::decoder::Audio>,
}

impl AudioStats {
    fn packet(&mut self, a: &proto::Audio) {
        self.packets += 1;
        self.bytes += a.data.len() as u64;
        self.channels = a.channels.unwrap_or(2);
        if self.last_pts.is_some_and(|p| a.pts_us > p + 25_000) {
            self.gaps += 1;
        }
        self.last_pts = Some(a.pts_us);
        if self.decoder.is_none() {
            self.decoder = ff::decoder::find(ff::codec::Id::OPUS)
                .and_then(|c| ff::codec::context::Context::new_with_codec(c).decoder().audio().ok());
        }
        let Some(d) = self.decoder.as_mut() else { return };
        if d.send_packet(&ff::Packet::copy(&a.data)).is_err() {
            self.errors += 1;
            return;
        }
        let mut frame = ff::frame::Audio::empty();
        while d.receive_frame(&mut frame).is_ok() {
            self.decoded += 1;
            // libavcodec's Opus decoder gives float samples.
            for plane in 0..frame.planes() {
                for s in frame.plane::<f32>(plane) {
                    self.peak = self.peak.max(s.abs());
                }
            }
        }
    }
}

/// One `video.*` stream as received.
struct VideoStats {
    window: u64,
    rect: proto::Rect,
    clip: Option<proto::Rect>,
    codec: Codec,
    source: proto::VideoSource,
    scaled: bool,
    size: Option<(u32, u32)>,
    frames: u64,
    bytes: u64,
    /// Frames that carried a pts.
    timed: u64,
    keyframe_first: Option<bool>,
    keyframes: u64,
    decoded: u64,
    decode_errors: u64,
    presents: u64,
    /// Presents that named a frame this client had not received.
    unknown_presents: u64,
    last_present: Option<u64>,
    seqs: std::collections::HashSet<u64>,
    decoder: Option<ff::decoder::Video>,
    destroyed: bool,
}

struct Decoder {
    codec: Codec,
    decoder: ff::decoder::Video,
    last: Option<ff::frame::Video>,
    crop: proto::Rect,
    stream: Option<std::fs::File>,
    /// What was painted over `last` since it was decoded, in order.
    paints: Vec<Paint>,
}

/// A change to the picture after it was decoded, as the client applies it.
enum Paint {
    /// A tile: picture pixels, RGB.
    Tile(proto::Rect, Vec<u8>),
    /// `frame.copy`: picture pixels, and where the source's top-left pixel lands.
    Copy(proto::Rect, [i32; 2]),
}

/// A PNG tile's RGB pixels, if it is an 8-bit RGB PNG of the rectangle's size.
fn decode_tile(rect: proto::Rect, data: &[u8]) -> Option<Vec<u8>> {
    let mut reader = png::Decoder::new(std::io::Cursor::new(data)).read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let fits = info.width == rect.w as u32 && info.height == rect.h as u32;
    (fits && info.color_type == png::ColorType::Rgb && info.bit_depth == png::BitDepth::Eight).then(|| {
        buf.truncate(info.buffer_size());
        buf
    })
}

fn open_decoder(codec: Codec) -> Result<ff::decoder::Video, ff::Error> {
    let id = match codec {
        Codec::H264 => ff::codec::Id::H264,
        Codec::Hevc => ff::codec::Id::HEVC,
        Codec::Av1 => ff::codec::Id::AV1,
        Codec::Vp9 => ff::codec::Id::VP9,
    };
    let av = ff::decoder::find(id).ok_or(ff::Error::DecoderNotFound)?;
    let mut ctx = ff::codec::context::Context::new_with_codec(av);
    ctx.set_threading(ff::threading::Config { kind: ff::threading::Type::Slice, count: 2 });
    ctx.decoder().video()
}

fn save_png(
    frame: &ff::frame::Video,
    crop: proto::Rect,
    paints: &[Paint],
    path: &std::path::Path,
) -> Result<(), String> {
    let (w, h) = (frame.width(), frame.height());
    let mut scaler = ff::software::scaling::Context::get(
        frame.format(),
        w,
        h,
        ff::format::Pixel::RGB24,
        w,
        h,
        ff::software::scaling::Flags::POINT,
    )
    .map_err(|e| e.to_string())?;
    let mut rgb = ff::frame::Video::empty();
    scaler.run(frame, &mut rgb).map_err(|e| e.to_string())?;
    let cw = (crop.w.max(1) as u32).min(w);
    let ch = (crop.h.max(1) as u32).min(h);
    let stride = rgb.stride(0);
    let mut pixels = Vec::with_capacity((cw * ch * 3) as usize);
    for y in crop.y.max(0) as usize..(crop.y.max(0) as u32 + ch) as usize {
        let start = y * stride + crop.x.max(0) as usize * 3;
        pixels.extend_from_slice(&rgb.data(0)[start..start + cw as usize * 3]);
    }
    // Tiles and copies applied since the picture, in order, as the client shows them.
    let inside = |x: i32, y: i32| (0..cw as i32).contains(&x) && (0..ch as i32).contains(&y);
    for paint in paints {
        match paint {
            Paint::Tile(r, tile) => {
                for ty in 0..r.h {
                    for tx in 0..r.w {
                        let (x, y) = (r.x + tx - crop.x, r.y + ty - crop.y);
                        if inside(x, y) {
                            let (d, s) = ((y as usize * cw as usize + x as usize) * 3, (ty * r.w + tx) as usize * 3);
                            pixels[d..d + 3].copy_from_slice(&tile[s..s + 3]);
                        }
                    }
                }
            }
            Paint::Copy(r, dst) => {
                // From the picture as it was before the copy: the two may overlap.
                let before = pixels.clone();
                for ty in 0..r.h {
                    for tx in 0..r.w {
                        let (sx, sy) = (r.x + tx - crop.x, r.y + ty - crop.y);
                        let (dx, dy) = (dst[0] + tx - crop.x, dst[1] + ty - crop.y);
                        if inside(sx, sy) && inside(dx, dy) {
                            let (d, s) = (
                                (dy as usize * cw as usize + dx as usize) * 3,
                                (sy as usize * cw as usize + sx as usize) * 3,
                            );
                            pixels[d..d + 3].copy_from_slice(&before[s..s + 3]);
                        }
                    }
                }
            }
        }
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), cw, ch);
    encoder.set_color(png::ColorType::Rgb);
    encoder.write_header().and_then(|mut w| w.write_image_data(&pixels)).map_err(|e| e.to_string())
}

/// The messages for one `--actions` step. `wait:MS` is returned as a Ping carrying the
/// delay, which the caller turns into a pause.
fn action_messages(id: u64, action: &str) -> Result<Vec<Message>, String> {
    let (verb, arg) = action.split_once(':').unwrap_or((action, ""));
    let point = |a: &str| -> Result<(f64, f64), String> {
        let (x, y) = a.split_once(',').ok_or_else(|| format!("bad point {a}"))?;
        Ok((x.parse().map_err(|_| format!("bad x {x}"))?, y.parse().map_err(|_| format!("bad y {y}"))?))
    };
    Ok(match verb {
        "key" => {
            let mut parts = arg.split('+');
            let sym = parts.next().unwrap_or_default();
            let keysym =
                u32::from_str_radix(sym.trim_start_matches("0x"), 16).map_err(|_| format!("bad keysym {sym}"))?;
            let mods: Vec<String> = parts.map(str::to_owned).collect();
            [true, false].map(|pressed| Message::Key(proto::Key { keysym, pressed, mods: mods.clone() })).to_vec()
        }
        "text" => vec![Message::Text(proto::Text { commit: Some(arg.to_owned()), ..Default::default() })],
        // copy:STRING puts STRING on the computer's clipboard, as copying on the phone does.
        "copy" => vec![Message::ClientClipboard(proto::Clipboard {
            mime: "text/plain;charset=utf-8".into(),
            data: arg.as_bytes().to_vec(),
        })],
        // edit:N:STRING deletes N grapheme clusters before the cursor and commits STRING,
        // as an autocorrection does.
        "edit" => {
            let (n, text) = arg.split_once(':').ok_or_else(|| format!("bad edit {arg}"))?;
            let n: u32 = n.parse().map_err(|_| format!("bad edit count {n}"))?;
            let commit = (!text.is_empty()).then(|| text.to_owned());
            vec![Message::Text(proto::Text { commit, delete_before: Some(n), ..Default::default() })]
        }
        "tap" => {
            let (x, y) = point(arg)?;
            [proto::TouchPhase::Down, proto::TouchPhase::Up]
                .map(|phase| {
                    Message::Touch(proto::Touch {
                        id,
                        points: vec![proto::TouchPoint { slot: 0, phase, x, y, force: None, radius: None }],
                    })
                })
                .to_vec()
        }
        "finger-down" | "finger-move" | "finger-up" => {
            let (x, y) = point(arg)?;
            let phase = match verb {
                "finger-down" => proto::TouchPhase::Down,
                "finger-move" => proto::TouchPhase::Motion,
                _ => proto::TouchPhase::Up,
            };
            vec![Message::Touch(proto::Touch {
                id,
                points: vec![proto::TouchPoint { slot: 0, phase, x, y, force: None, radius: None }],
            })]
        }
        "click" => {
            let (x, y) = point(arg)?;
            [proto::buttons::LEFT, 0]
                .map(|buttons| Message::Pointer(proto::Pointer { id, x, y, buttons, scroll: None }))
                .to_vec()
        }
        "close" => vec![Message::Close { id }],
        "wait" => vec![Message::Ping { t_us: arg.parse().map_err(|_| format!("bad wait {arg}"))? }],
        // The window fills its display, as the phone shows one window at a time.
        "maximize" => vec![Message::Configure(proto::Configure {
            id,
            maximized: Some(true),
            activated: Some(true),
            ..Default::default()
        })],
        // scroll:X,Y,DY scrolls by DY pixels (precise, as a trackpad or a touch drag) at X,Y.
        // resize:W,H asks for the window at that size (display pixels).
        "resize" => {
            let (w, h) = point(arg)?;
            vec![Message::Configure(proto::Configure {
                id,
                geometry: Some(proto::Rect::new(0, 0, w as i32, h as i32)),
                activated: Some(true),
                ..Default::default()
            })]
        }
        "scroll" => {
            let mut parts = arg.splitn(3, ',');
            let mut next = || parts.next().and_then(|v| v.parse::<f64>().ok()).ok_or(format!("bad scroll {arg}"));
            let (x, y, dy) = (next()?, next()?, next()?);
            vec![Message::Pointer(proto::Pointer {
                id,
                x,
                y,
                buttons: 0,
                scroll: Some(proto::Scroll { dx: 0.0, dy, precise: true }),
            })]
        }
        _ => return Err(format!("unknown action {verb}")),
    })
}

fn send(ws: &mut WebSocket<MaybeTlsStream<TcpStream>>, m: &Message) -> Result<(), String> {
    ws.send(WsMessage::Binary(proto::encode(m).into())).map_err(|e| e.to_string())
}

fn percentile(v: &[u64], p: f64) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let mut s = v.to_vec();
    s.sort_unstable();
    s[((s.len() - 1) as f64 * p).round() as usize] as f64
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("caboose-display-probe: {e}\n\n{USAGE}");
            std::process::exit(2);
        }
    };
    match run(args) {
        Ok(true) => {}
        Ok(false) => std::process::exit(1),
        Err(e) => {
            eprintln!("caboose-display-probe: {e}");
            std::process::exit(1);
        }
    }
}

fn run(args: Args) -> Result<bool, String> {
    ff::init().map_err(|e| e.to_string())?;
    ff::util::log::set_level(ff::util::log::Level::Fatal);
    let request =
        tungstenite::client::IntoClientRequest::into_client_request(args.url.as_str()).map_err(|e| e.to_string())?;
    let mut request = request;
    request.headers_mut().insert("sec-websocket-protocol", "binary".parse().unwrap());
    let (mut ws, _) = tungstenite::connect(request).map_err(|e| format!("connect {}: {e}", args.url))?;
    if let MaybeTlsStream::Plain(s) = ws.get_mut() {
        s.set_nodelay(true).ok();
        s.set_read_timeout(Some(Duration::from_millis(1))).ok();
    }
    send(
        &mut ws,
        &Message::ClientHello(proto::ClientHello {
            devices: false,
            version: proto::VERSION,
            token: args.token.clone(),
            decoders: args.decoders.clone(),
            displays: args.displays.clone(),
            video_decoders: args.video_decoders.clone(),
            audio_decoders: args.audio.then(|| vec!["opus".to_owned()]),
            wasm: args.wasm,
            webview: false,
            gpu: args.gpu_save.is_some(),
            scaled_motion: args.scaled_motion,
            copy: args.copy,
        }),
    )?;

    let start = Instant::now();
    let connected_us = monotonic_us();
    let cpu0 = args.server_pid.and_then(process_cpu_ms);
    let mut decoder_stream = StreamDecoder::new();
    let mut windows: BTreeMap<u64, WindowStats> = BTreeMap::new();
    let mut decoders: BTreeMap<u64, Decoder> = BTreeMap::new();
    let mut hello: Option<proto::ServerHello> = None;
    let mut acted = false;
    let mut pending: std::collections::VecDeque<String> = args.actions.iter().cloned().collect();
    let mut target: Option<u64> = None;
    let mut next_action = Instant::now();
    let vsync_interval = Duration::from_secs_f64(1.0 / args.displays[0].refresh_hz.max(1.0));
    let mut next_vsync = Instant::now();
    let mut text_input_events = 0u32;
    let mut videos: BTreeMap<u64, VideoStats> = BTreeMap::new();
    let mut games: BTreeMap<u64, GameStats> = BTreeMap::new();
    let mut gpus: BTreeMap<u64, GpuStats> = BTreeMap::new();
    let mut clipboard: Option<String> = None;
    let mut sound = AudioStats::default();
    let mut ping_sent: Option<u64> = None;
    let mut rtt_us: Option<u64> = None;
    let mut bye: Option<proto::ByeReason> = None;

    'outer: while start.elapsed() < args.duration {
        if args.stall_after.is_some_and(|s| start.elapsed() >= s) {
            // A suspended client: the socket stays open, nothing is read or sent.
            std::thread::sleep(args.duration.saturating_sub(start.elapsed()));
            break;
        }
        let now = Instant::now();
        if let (Some(id), Some(action)) = (target, pending.front().cloned()) {
            if now >= next_action {
                pending.pop_front();
                next_action = now + Duration::from_millis(if action.starts_with("finger-") { 16 } else { 300 });
                if action == "decline" {
                    // The game handed to the probe, not the window: game ids are their own namespace.
                    if let Some(game) = games.keys().next().copied() {
                        let reason = "the probe declines it".to_owned();
                        send(&mut ws, &Message::GameDecline { id: game, reason })?;
                    }
                    continue;
                }
                for m in action_messages(id, &action)? {
                    if let Message::Ping { t_us } = m {
                        next_action = now + Duration::from_millis(t_us);
                        continue;
                    }
                    send(&mut ws, &m)?;
                }
            }
        }
        if hello.is_some() && now >= next_vsync {
            for d in &args.displays {
                send(&mut ws, &Message::Vsync { display: d.id, t_us: monotonic_us() })?;
            }
            next_vsync += vsync_interval;
            if next_vsync < now {
                next_vsync = now + vsync_interval;
            }
            if ping_sent.is_none() {
                let t = monotonic_us();
                ping_sent = Some(t);
                send(&mut ws, &Message::Ping { t_us: t })?;
            }
        }
        match ws.read() {
            Ok(WsMessage::Binary(bytes)) => decoder_stream.push(&bytes),
            Ok(WsMessage::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => break,
            Err(e) => return Err(format!("read: {e}")),
        }
        loop {
            let message = match decoder_stream.next_message().map_err(|e| e.to_string())? {
                None => break,
                Some(Decoded::Message(m)) => m,
                Some(Decoded::Unknown { .. }) => continue,
                Some(Decoded::Invalid { type_id, error }) => {
                    return Err(format!("server sent invalid 0x{type_id:02x}: {error}"))
                }
            };
            match message {
                Message::ServerHello(h) => {
                    if args.check {
                        println!("ready: encoders {:?}, features {:?}", h.encoders, h.features);
                        return Ok(true);
                    }
                    hello = Some(h);
                }
                Message::Bye { reason } => {
                    bye = Some(reason);
                    break 'outer;
                }
                Message::WindowCreate(c) => {
                    let s = windows.entry(c.id).or_default();
                    s.title = if c.title.is_empty() { c.app_id.clone() } else { c.title.clone() };
                    s.geometry = c.geometry;
                    s.kind = c.kind.as_str();
                    s.parent = c.parent;
                }
                Message::WindowUpdate(u) => {
                    let s = windows.entry(u.id).or_default();
                    if let Some(t) = u.title {
                        s.title = t;
                    }
                    if let Some(g) = u.geometry {
                        s.geometry = g;
                    }
                }
                Message::WindowDestroy { id } => {
                    decoders.remove(&id);
                    windows.entry(id).or_default().destroyed = true;
                }
                Message::Tile(t) => {
                    let s = windows.entry(t.id).or_default();
                    s.tiles += 1;
                    s.tile_bytes += t.data.len() as u64;
                    match (decode_tile(t.rect, &t.data), decoders.get_mut(&t.id)) {
                        (Some(rgb), Some(d)) if d.last.is_some() => d.paints.push(Paint::Tile(t.rect, rgb)),
                        _ => s.tile_errors += 1,
                    }
                }
                Message::FrameCopy(c) => {
                    let s = windows.entry(c.id).or_default();
                    s.copies += 1;
                    let shift = [c.dst[0] - c.src.x, c.dst[1] - c.src.y];
                    if s.copy_shifts.len() < 16 && !s.copy_shifts.contains(&shift) {
                        s.copy_shifts.push(shift);
                    }
                    match decoders.get_mut(&c.id) {
                        Some(d) if d.last.is_some() => d.paints.push(Paint::Copy(c.src, c.dst)),
                        _ => s.copy_errors += 1,
                    }
                }
                Message::Frame(f) => {
                    let received = monotonic_us();
                    let s = windows.entry(f.id).or_default();
                    if s.frames == 0 {
                        s.first_keyframe = f.keyframe;
                    }
                    s.frames += 1;
                    s.keyframes += f.keyframe as u64;
                    s.bytes += f.data.len() as u64;
                    if s.last_crop != Some((f.crop.w, f.crop.h)) {
                        s.sizes += 1;
                        s.resized_without_keyframe |= !f.keyframe;
                        s.last_crop = Some((f.crop.w, f.crop.h));
                    }
                    s.codec = Some(f.codec);
                    s.first.get_or_insert_with(Instant::now);
                    s.last = Some(Instant::now());
                    // Pictures of content committed before this client connected say
                    // nothing about latency.
                    if f.pts_us >= connected_us {
                        s.latency_us.push(received.saturating_sub(f.pts_us));
                    }
                    if !decoders.get(&f.id).is_some_and(|d| d.codec == f.codec) {
                        let decoder =
                            open_decoder(f.codec).map_err(|e| format!("decoder for {}: {e}", f.codec.as_str()))?;
                        let stream = match &args.save {
                            Some(dir) => {
                                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                                Some(
                                    std::fs::File::create(dir.join(format!("window-{}.{}", f.id, f.codec.as_str())))
                                        .map_err(|e| e.to_string())?,
                                )
                            }
                            None => None,
                        };
                        decoders.insert(
                            f.id,
                            Decoder { codec: f.codec, decoder, last: None, crop: f.crop, stream, paints: Vec::new() },
                        );
                    }
                    let d = decoders.get_mut(&f.id).unwrap();
                    d.crop = f.crop;
                    if let Some(file) = d.stream.as_mut() {
                        file.write_all(&f.data).map_err(|e| e.to_string())?;
                    }
                    let t0 = Instant::now();
                    let packet = ff::Packet::copy(&f.data);
                    let mut ok = d.decoder.send_packet(&packet).is_ok();
                    let mut frame = ff::frame::Video::empty();
                    let mut got = false;
                    while ok {
                        match d.decoder.receive_frame(&mut frame) {
                            Ok(()) => {
                                got = true;
                                s.size = (frame.width(), frame.height());
                                d.last = Some(frame.clone());
                                d.paints.clear();
                            }
                            Err(ff::Error::Other { errno: libc::EAGAIN }) => break,
                            Err(_) => {
                                ok = false;
                            }
                        }
                    }
                    let decoded_us = if ok && got { t0.elapsed().as_micros() as i64 } else { -1 };
                    if decoded_us >= 0 {
                        s.decode_us.push(decoded_us as u64);
                    } else {
                        s.decode_errors += 1;
                    }
                    send(&mut ws, &Message::Ack { id: f.id, pts_us: f.pts_us, decoded_us })?;
                    if decoded_us < 0 {
                        send(&mut ws, &Message::RequestKeyframe { id: f.id })?;
                    }
                    if target.is_none()
                        && got
                        && args.window.is_none_or(|w| w == f.id)
                        && windows.get(&f.id).is_some_and(|w| w.kind != "popup")
                    {
                        target = Some(f.id);
                    }
                    if !acted && got {
                        acted = true;
                        if let Some((x, y)) = args.click {
                            for buttons in [proto::buttons::LEFT, 0] {
                                send(
                                    &mut ws,
                                    &Message::Pointer(proto::Pointer { id: f.id, x, y, buttons, scroll: None }),
                                )?;
                            }
                        }
                        if let Some((x, y)) = args.touch {
                            for phase in [proto::TouchPhase::Down, proto::TouchPhase::Up] {
                                let point = proto::TouchPoint { slot: 0, phase, x, y, force: None, radius: None };
                                send(&mut ws, &Message::Touch(proto::Touch { id: f.id, points: vec![point] }))?;
                            }
                        }
                        if let Some(text) = &args.type_text {
                            send(
                                &mut ws,
                                &Message::Text(proto::Text { commit: Some(text.clone()), ..Default::default() }),
                            )?;
                        }
                    }
                }
                Message::TextInput(_) => text_input_events += 1,
                Message::GameCreate(g) => {
                    // A game's window sends no pictures, so it becomes the target when its game binds.
                    if target.is_none() && args.window.is_none_or(|w| w == g.window) {
                        target = Some(g.window);
                    }
                    games.insert(g.id, GameStats { game: g, destroyed: false });
                }
                Message::GpuCreate { id, window } => {
                    if target.is_none() && args.window.is_none_or(|w| w == window) {
                        target = Some(window);
                    }
                    let file = match &args.gpu_save {
                        Some(dir) => {
                            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                            Some(std::fs::File::create(dir.join(format!("gpu-{id}.gfxr"))).map_err(|e| e.to_string())?)
                        }
                        None => None,
                    };
                    gpus.insert(id, GpuStats { window, bytes: 0, file, destroyed: false, reason: None });
                }
                Message::GpuData(d) => {
                    if let Some(g) = gpus.get_mut(&d.id) {
                        if d.offset == g.bytes {
                            if let Some(f) = g.file.as_mut() {
                                f.write_all(&d.data).map_err(|e| e.to_string())?;
                            }
                            g.bytes += d.data.len() as u64;
                            send(&mut ws, &Message::GpuAck { id: d.id, offset: g.bytes })?;
                        }
                    }
                }
                Message::GpuDestroy { id, reason } => {
                    if let Some(g) = gpus.get_mut(&id) {
                        g.destroyed = true;
                        g.reason = reason;
                    }
                }
                Message::GameDestroy { id } => {
                    if let Some(g) = games.get_mut(&id) {
                        g.destroyed = true;
                    }
                }
                Message::ServerClipboard(c) => clipboard = Some(String::from_utf8_lossy(&c.data).into_owned()),
                Message::Audio(a) => sound.packet(&a),
                Message::VideoCreate(c) => {
                    videos.insert(
                        c.id,
                        VideoStats {
                            window: c.window,
                            rect: c.rect,
                            clip: c.clip,
                            codec: c.codec,
                            source: c.source,
                            scaled: c.scaled,
                            size: None,
                            frames: 0,
                            bytes: 0,
                            timed: 0,
                            keyframe_first: None,
                            keyframes: 0,
                            decoded: 0,
                            decode_errors: 0,
                            presents: 0,
                            unknown_presents: 0,
                            last_present: None,
                            seqs: Default::default(),
                            decoder: open_decoder(c.codec).ok(),
                            destroyed: false,
                        },
                    );
                }
                Message::VideoUpdate(u) => {
                    if let Some(v) = videos.get_mut(&u.id) {
                        if let Some(r) = u.rect {
                            v.rect = r;
                        }
                        if u.clip.is_some() {
                            v.clip = u.clip;
                        }
                    }
                }
                Message::VideoDestroy { id } => {
                    if let Some(v) = videos.get_mut(&id) {
                        v.destroyed = true;
                    }
                }
                Message::VideoFrame(f) => {
                    let Some(v) = videos.get_mut(&f.id) else { continue };
                    v.frames += 1;
                    v.keyframes += f.keyframe as u64;
                    v.bytes += f.data.len() as u64;
                    v.timed += f.pts_us.is_some() as u64;
                    v.keyframe_first.get_or_insert(f.keyframe);
                    v.seqs.insert(f.seq);
                    if let Some(d) = v.decoder.as_mut() {
                        let ok = d.send_packet(&ff::Packet::copy(&f.data)).is_ok();
                        let mut frame = ff::frame::Video::empty();
                        while ok && d.receive_frame(&mut frame).is_ok() {
                            v.decoded += 1;
                            v.size = Some((frame.width(), frame.height()));
                        }
                        if !ok {
                            v.decode_errors += 1;
                        }
                    }
                    send(&mut ws, &Message::VideoAck { id: f.id, seq: f.seq })?;
                }
                Message::VideoPresent { id, seq, .. } => {
                    if let Some(v) = videos.get_mut(&id) {
                        v.presents += 1;
                        v.unknown_presents += !v.seqs.contains(&seq) as u64;
                        v.last_present = Some(seq);
                    }
                }
                Message::Pong { t_us } if Some(t_us) == ping_sent => rtt_us = Some(monotonic_us() - t_us),
                _ => {}
            }
        }
    }
    let elapsed = start.elapsed().as_secs_f64();
    let cpu_ms = match (cpu0, args.server_pid.and_then(process_cpu_ms)) {
        (Some(a), Some(b)) => Some(b - a),
        _ => None,
    };
    if let Some(dir) = &args.save {
        for (id, d) in &decoders {
            if let Some(frame) = &d.last {
                if let Err(e) = save_png(frame, d.crop, &d.paints, &dir.join(format!("window-{id}.png"))) {
                    eprintln!("window {id}: cannot save PNG: {e}");
                }
            }
        }
    }

    let total_frames: u64 = windows.values().map(|w| w.frames).sum();
    let busiest_fps = windows
        .values()
        .filter_map(|w| match (w.first, w.last) {
            (Some(a), Some(b)) if w.frames > 1 => Some((w.frames - 1) as f64 / (b - a).as_secs_f64().max(1e-6)),
            _ => None,
        })
        .fold(0.0, f64::max);
    let mut ok = hello.is_some() && bye.is_none();
    if let Some(n) = args.windows {
        ok &= windows.len() >= n;
    }
    if let Some(f) = args.min_fps {
        ok &= busiest_fps >= f;
    }
    ok &= windows.values().all(|w| w.decode_errors == 0 && w.tile_errors == 0);
    ok &= videos.values().all(|v| v.decode_errors == 0);
    ok &= sound.errors == 0;

    if args.json {
        let per: Vec<String> = windows
            .iter()
            .map(|(id, w)| {
                let span = match (w.first, w.last) {
                    (Some(a), Some(b)) => (b - a).as_secs_f64(),
                    _ => 0.0,
                };
                format!(
                    "{{\"id\":{id},\"title\":{:?},\"kind\":{:?},\"parent\":{},\"geometry\":[{},{},{},{}],\"keyframe_first\":{},\"codec\":{:?},\"size\":[{},{}],\"frames\":{},\"keyframes\":{},\"bytes\":{},\"fps\":{:.1},\"kbps\":{:.0},\"decode_ms_p50\":{:.2},\"latency_ms_p50\":{:.2},\"latency_ms_p95\":{:.2},\"decode_errors\":{},\"sizes\":{},\"keyframe_after_resize\":{},\"destroyed\":{},\"tiles\":{},\"tile_bytes\":{},\"tile_errors\":{},\"copies\":{},\"copy_errors\":{},\"copy_shifts\":{:?}}}",
                    w.title,
                    w.kind,
                    w.parent.map(|p| p.to_string()).unwrap_or("null".into()),
                    w.geometry.x,
                    w.geometry.y,
                    w.geometry.w,
                    w.geometry.h,
                    w.first_keyframe,
                    w.codec.map(|c| c.as_str()).unwrap_or(""),
                    w.size.0,
                    w.size.1,
                    w.frames,
                    w.keyframes,
                    w.bytes,
                    if span > 0.0 { (w.frames.saturating_sub(1)) as f64 / span } else { 0.0 },
                    w.bytes as f64 * 8.0 / 1000.0 / elapsed,
                    percentile(&w.decode_us, 0.5) / 1000.0,
                    percentile(&w.latency_us, 0.5) / 1000.0,
                    percentile(&w.latency_us, 0.95) / 1000.0,
                    w.decode_errors,
                    w.sizes,
                    !w.resized_without_keyframe,
                    w.destroyed,
                    w.tiles,
                    w.tile_bytes,
                    w.tile_errors,
                    w.copies,
                    w.copy_errors,
                    w.copy_shifts
                )
            })
            .collect();
        println!(
            "{{\"ok\":{ok},\"seconds\":{elapsed:.2},\"gpus\":[{}],\"games\":[{}],\"videos\":[{}],\"windows\":[{}],\"frames\":{total_frames},\"server_cpu_ms\":{},\"server_cpu_pct\":{},\"server_cpu_ms_per_frame\":{},\"rtt_ms\":{},\"text_input_events\":{text_input_events},\"clipboard\":{},\"audio\":{{\"packets\":{},\"bytes\":{},\"decoded\":{},\"errors\":{},\"channels\":{},\"peak\":{:.3},\"gaps\":{}}},\"bye\":{}}}",
            gpus.iter()
                .map(|(id, g)| format!(
                    "{{\"id\":{id},\"window\":{},\"bytes\":{},\"destroyed\":{},\"reason\":{}}}",
                    g.window,
                    g.bytes,
                    g.destroyed,
                    g.reason.as_ref().map(|r| format!("{r:?}")).unwrap_or("null".into())
                ))
                .collect::<Vec<_>>()
                .join(","),
            games
                .iter()
                .map(|(id, g)| format!(
                    "{{\"id\":{id},\"window\":{},\"root\":{:?},\"entry\":{:?},\"saves\":[{}],\"destroyed\":{}}}",
                    g.game.window,
                    g.game.root,
                    g.game.entry,
                    g.game
                        .saves
                        .iter()
                        .flatten()
                        .map(|s| format!("{{\"mount\":{:?},\"path\":{:?}}}", s.mount, s.path))
                        .collect::<Vec<_>>()
                        .join(","),
                    g.destroyed
                ))
                .collect::<Vec<_>>()
                .join(","),
            videos
                .iter()
                .map(|(id, v)| format!(
                    "{{\"id\":{id},\"window\":{},\"codec\":{:?},\"source\":{:?},\"scaled\":{},\"size\":{},\"rect\":[{},{},{},{}],\"clip\":{},\"frames\":{},\"bytes\":{},\"timed\":{},\"keyframe_first\":{},\"keyframes\":{},\"decoded\":{},\"decode_errors\":{},\"presents\":{},\"unknown_presents\":{},\"last_present\":{},\"destroyed\":{}}}",
                    v.window,
                    v.codec.as_str(),
                    v.source.as_str(),
                    v.scaled,
                    v.size.map(|(w,h)| format!("[{w},{h}]")).unwrap_or("null".into()),
                    v.rect.x,
                    v.rect.y,
                    v.rect.w,
                    v.rect.h,
                    v.clip.map(|c| format!("[{},{},{},{}]", c.x, c.y, c.w, c.h)).unwrap_or("null".into()),
                    v.frames,
                    v.bytes,
                    v.timed,
                    v.keyframe_first.map(|k| k.to_string()).unwrap_or("null".into()),
                    v.keyframes,
                    v.decoded,
                    v.decode_errors,
                    v.presents,
                    v.unknown_presents,
                    v.last_present.map(|s| s.to_string()).unwrap_or("null".into()),
                    v.destroyed
                ))
                .collect::<Vec<_>>()
                .join(","),
            per.join(","),
            cpu_ms.map(|c| format!("{c:.0}")).unwrap_or("null".into()),
            cpu_ms.map(|c| format!("{:.1}", c / elapsed / 10.0)).unwrap_or("null".into()),
            cpu_ms.filter(|_| total_frames > 0).map(|c| format!("{:.2}", c / total_frames as f64)).unwrap_or("null".into()),
            rtt_us.map(|r| format!("{:.2}", r as f64 / 1000.0)).unwrap_or("null".into()),
            clipboard.as_ref().map(|c| format!("{c:?}")).unwrap_or("null".into()),
            sound.packets,
            sound.bytes,
            sound.decoded,
            sound.errors,
            sound.channels,
            sound.peak,
            sound.gaps,
            bye.map(|b| format!("\"{}\"", b.as_str())).unwrap_or("null".into()),
        );
    } else {
        match &hello {
            Some(h) => println!("server: encoders {:?}, features {:?}", h.encoders, h.features),
            None => println!("server: no hello{}", bye.map(|b| format!(" (bye: {})", b.as_str())).unwrap_or_default()),
        }
        for (id, w) in &windows {
            let span = match (w.first, w.last) {
                (Some(a), Some(b)) => (b - a).as_secs_f64(),
                _ => 0.0,
            };
            println!(
                "window {id} {:?}: {} {}x{}, {} frames ({} key), {:.1} fps, {:.0} kbit/s, decode p50 {:.2} ms, latency p50 {:.2} ms p95 {:.2} ms, {} decode errors",
                w.title,
                w.codec.map(|c| c.as_str()).unwrap_or("-"),
                w.size.0,
                w.size.1,
                w.frames,
                w.keyframes,
                if span > 0.0 { (w.frames.saturating_sub(1)) as f64 / span } else { 0.0 },
                w.bytes as f64 * 8.0 / 1000.0 / elapsed,
                percentile(&w.decode_us, 0.5) / 1000.0,
                percentile(&w.latency_us, 0.5) / 1000.0,
                percentile(&w.latency_us, 0.95) / 1000.0,
                w.decode_errors
            );
        }
        for (id, g) in &gpus {
            println!(
                "gpu {id}: window {}, {} bytes{}",
                g.window,
                g.bytes,
                if g.destroyed { ", destroyed" } else { "" }
            );
        }
        for (id, g) in &games {
            println!(
                "game {id}: window {}, {}/{}{}",
                g.game.window,
                g.game.root,
                g.game.entry,
                if g.destroyed { ", destroyed" } else { "" }
            );
        }
        if let Some(c) = cpu_ms {
            println!(
                "server CPU: {c:.0} ms over {elapsed:.1} s ({:.1}% of a core){}",
                c / elapsed / 10.0,
                if total_frames > 0 { format!(", {:.2} ms per frame", c / total_frames as f64) } else { String::new() }
            );
        }
        if let Some(r) = rtt_us {
            println!("round trip: {:.2} ms", r as f64 / 1000.0);
        }
        println!("{}", if ok { "OK" } else { "FAILED" });
    }
    Ok(ok)
}
