//! caboose-display-probe: a headless Caboose Display client for scripted checks.
//!
//! It connects like the phone does (hello with token and displays), ticks vsync at the
//! display's refresh rate, drives windows with input, and reports the windows, keyboard,
//! clipboard, drag and drop, sound and touch targets the server sent, and what the
//! connection carried. Window pictures go to the phone's GPU, not over this connection;
//! the control socket's `screenshot` shows them. With `--server-pid` it also reports the
//! server's CPU time.

use caboose_display_protocol::{self as proto, Decoded, Message, StreamDecoder};
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
    --audio                play the computer's sound (decoded and measured, not heard)
    --wasm                 run games handed off to the client (reports game.create and
                           game.destroy; a game's window is a target like any other)
    --clipboard-types LIST MIME types to take from the computer's clipboard besides text
    --duration SECS        how long to run [default: 10]
    --stall-after SECS     then stop reading and sending, the socket left open (a
                           suspended client)
    --windows N            fail unless at least N windows appear
    --server-pid PID       report the server's CPU time from /proc
    --type TEXT            once a window shows, send TEXT as a text commit to it
    --click X,Y            once a window shows, click there (window-local pixels)
    --touch X,Y            once a window shows, tap there with one finger
    --window ID            the window --actions are for [default: the first that shows]
    --actions LIST         once a window shows, run `;`-separated actions 300 ms apart:
                           key:KEYSYM[+mod...] (press and release; mods shift, control,
                           mod1, mod4), text:STRING, edit:N:STRING (delete N before,
                           then commit), copy:STRING (the phone's clipboard),
                           copy-file:MIME:PATH (the file's bytes as MIME on the
                           phone's clipboard), copy-files:PATH[,PATH...] (the files as
                           the phone's text/uri-list), tap:X,Y, press:X,Y,
                           move:X,Y, release:X,Y (the left button),
                           drop-enter:TYPE[|TYPE...]@X,Y (`text` for UTF-8 text),
                           drop-move:X,Y, drop-leave,
                           drop-text:STRING, drop-files:PATH[,PATH...] (a drop from
                           the phone), drag-take (the phone takes a drag),
                           click:X,Y, wait:MS, maximize (fill the display),
                           scroll:X,Y,DY (precise, DY pixels), wheel:X,Y,DY (the same,
                           with the next action 16 ms later, as a trackpad sends them),
                           look:X,Y,DX,DY (relative
                           motion, the pointer left at X,Y), resize:W,H, close,
                           decline (refuse the game handed to the probe, as a device that
                           cannot run it does),
                           finger-down:X,Y, finger-move:X,Y, finger-up:X,Y (16 ms apart)
    --targets FILE         aim touches (hello targets: true): append every `targets` message
                           to FILE as a JSON line (t_us, id, serial, targets), and every
                           `text_focus` (t_us, id, editing)
    --check                exit 0 as soon as the server answers hello (readiness probe)
    --json                 print the report as one JSON line

A window shows half a second after the server announces it, when its application has
had time to draw.
";

/// How long after a window is announced the probe acts on it.
const SHOWN_AFTER: Duration = Duration::from_millis(500);

struct Args {
    url: String,
    token: String,
    displays: Vec<proto::Display>,
    audio: bool,
    wasm: bool,
    clipboard_types: Option<Vec<String>>,
    duration: Duration,
    /// Stop reading and sending after this long, keeping the connection open.
    stall_after: Option<Duration>,
    windows: Option<usize>,
    server_pid: Option<u32>,
    type_text: Option<String>,
    click: Option<(f64, f64)>,
    touch: Option<(f64, f64)>,
    actions: Vec<String>,
    window: Option<u64>,
    check: bool,
    json: bool,
    targets: Option<PathBuf>,
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

fn parse_args_from(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args {
        url: "ws://127.0.0.1:14600/".into(),
        token: String::new(),
        displays: Vec::new(),
        audio: false,
        wasm: false,
        clipboard_types: None,
        duration: Duration::from_secs(10),
        stall_after: None,
        windows: None,
        server_pid: None,
        type_text: None,
        click: None,
        touch: None,
        actions: Vec::new(),
        window: None,
        check: false,
        json: false,
        targets: None,
    };
    let mut args = argv.into_iter();
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
            "--wasm" => a.wasm = true,
            "--clipboard-types" => a.clipboard_types = Some(value()?.split(',').map(str::to_owned).collect()),
            "--duration" => a.duration = Duration::from_secs_f64(value()?.parse().map_err(|_| "bad --duration")?),
            "--stall-after" => {
                a.stall_after = Some(Duration::from_secs_f64(value()?.parse().map_err(|_| "bad --stall-after")?))
            }
            "--windows" => a.windows = Some(value()?.parse().map_err(|_| "bad --windows")?),
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
            "--targets" => a.targets = Some(PathBuf::from(value()?)),
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

/// FNV-1a, 64-bit: how the report identifies clipboard bytes (scripts/check.py computes
/// the same).
fn fnv1a(data: &[u8]) -> u64 {
    data.iter().fold(0xcbf29ce484222325, |h, b| (h ^ *b as u64).wrapping_mul(0x100000001b3))
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

struct GameStats {
    game: proto::GameCreate,
    destroyed: bool,
}

#[derive(Default)]
struct WindowStats {
    title: String,
    /// What a taskbar groups the window by, and its own icon (PNG bytes; 0 for none).
    app_id: String,
    pid: Option<u32>,
    icon_bytes: usize,
    /// How many times an icon arrived (with the window, then each change).
    icons: u64,
    kind: &'static str,
    parent: Option<u64>,
    geometry: proto::Rect,
    /// The window keeps its alpha (a popup).
    alpha: bool,
    /// When the server announced it.
    announced: Option<Instant>,
    destroyed: bool,
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
            alternatives: Vec::new(),
        })],
        // copy-file:MIME:PATH copies the file's bytes as MIME, as copying an image does.
        "copy-file" => {
            let (mime, path) = arg.split_once(':').ok_or_else(|| format!("bad copy-file {arg}"))?;
            let data = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
            vec![Message::ClientClipboard(proto::Clipboard { mime: mime.into(), data, alternatives: Vec::new() })]
        }
        // copy-files:PATH,... copies files the phone uploaded, as a text/uri-list.
        "copy-files" => {
            let paths: Vec<&str> = arg.split(',').collect();
            vec![Message::ClientClipboard(proto::Clipboard {
                mime: proto::clipboard::URI_LIST.into(),
                data: proto::clipboard::uri_list(&paths),
                alternatives: Vec::new(),
            })]
        }
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
        // press, move and release drive the left button separately, as a drag does.
        "press" | "move" | "release" => {
            let (x, y) = point(arg)?;
            let buttons = if verb == "release" { 0 } else { proto::buttons::LEFT };
            vec![Message::Pointer(proto::Pointer { id, x, y, buttons, scroll: None, relative: None })]
        }
        // drop-enter:TYPES@X,Y starts a drop from the phone offering TYPES (`|`-separated;
        // `text` stands for text/plain;charset=utf-8, whose `;` would end the action).
        "drop-enter" => {
            let (types, at) = arg.split_once('@').ok_or_else(|| format!("bad drop-enter {arg}"))?;
            let (x, y) = point(at)?;
            vec![Message::DropEnter(proto::DropEnter {
                id,
                x,
                y,
                mimes: types
                    .split('|')
                    .map(|t| if t == "text" { proto::clipboard::TEXT.to_owned() } else { t.to_owned() })
                    .collect(),
            })]
        }
        "drop-move" => {
            let (x, y) = point(arg)?;
            vec![Message::DropMotion { id, x, y }]
        }
        "drop-leave" => vec![Message::DropLeave],
        "drop-text" => vec![Message::DropPerform(proto::Clipboard {
            mime: proto::clipboard::TEXT.into(),
            data: arg.as_bytes().to_vec(),
            alternatives: Vec::new(),
        })],
        "drop-files" => {
            let paths: Vec<&str> = arg.split(',').collect();
            vec![Message::DropPerform(proto::Clipboard {
                mime: proto::clipboard::URI_LIST.into(),
                data: proto::clipboard::uri_list(&paths),
                alternatives: Vec::new(),
            })]
        }
        "drag-take" => vec![Message::DragTake],
        "click" => {
            let (x, y) = point(arg)?;
            [proto::buttons::LEFT, 0]
                .map(|buttons| Message::Pointer(proto::Pointer { id, x, y, buttons, scroll: None, relative: None }))
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
        // scroll:X,Y,DY scrolls by DY pixels (precise, as a trackpad or a touch drag) at X,Y.
        "scroll" | "wheel" => {
            let mut parts = arg.splitn(3, ',');
            let mut next = || parts.next().and_then(|v| v.parse::<f64>().ok()).ok_or(format!("bad scroll {arg}"));
            let (x, y, dy) = (next()?, next()?, next()?);
            vec![Message::Pointer(proto::Pointer {
                id,
                x,
                y,
                buttons: 0,
                scroll: Some(proto::Scroll { dx: 0.0, dy, precise: true, seq: None }),
                relative: None,
            })]
        }
        // look:X,Y,DX,DY moves the pointer DX, DY relative to where it is, leaving it at X,Y
        // (a stick's mouse look).
        "look" => {
            let mut parts = arg.splitn(4, ',');
            let mut next = || parts.next().and_then(|v| v.parse::<f64>().ok()).ok_or(format!("bad look {arg}"));
            let (x, y, dx, dy) = (next()?, next()?, next()?, next()?);
            vec![Message::Pointer(proto::Pointer { id, x, y, buttons: 0, scroll: None, relative: Some([dx, dy]) })]
        }
        _ => return Err(format!("unknown action {verb}")),
    })
}

fn send(ws: &mut WebSocket<MaybeTlsStream<TcpStream>>, m: &Message) -> Result<(), String> {
    ws.send(WsMessage::Binary(proto::encode(m).into())).map_err(|e| e.to_string())
}

/// Appends one JSON line to the `--targets` file.
fn append_line(path: &std::path::Path, line: &str) {
    let written = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(line.as_bytes()));
    if let Err(e) = written {
        eprintln!("cannot write {}: {e}", path.display());
    }
}

fn main() {
    let args = match parse_args_from(std::env::args().skip(1)) {
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
    let mut request =
        tungstenite::client::IntoClientRequest::into_client_request(args.url.as_str()).map_err(|e| e.to_string())?;
    request.headers_mut().insert("sec-websocket-protocol", "binary".parse().unwrap());
    let (mut ws, _) = tungstenite::connect(request).map_err(|e| format!("connect {}: {e}", args.url))?;
    if let MaybeTlsStream::Plain(s) = ws.get_mut() {
        s.set_nodelay(true).ok();
        s.set_read_timeout(Some(Duration::from_millis(1))).ok();
    }
    send(
        &mut ws,
        &Message::ClientHello(proto::ClientHello {
            version: proto::VERSION,
            token: args.token.clone(),
            displays: args.displays.clone(),
            audio_decoders: args.audio.then(|| vec!["opus".to_owned()]),
            wasm: args.wasm,
            webview: false,
            devices: false,
            targets: args.targets.is_some(),
            clipboard_types: args.clipboard_types.clone(),
        }),
    )?;

    let start = Instant::now();
    let cpu0 = args.server_pid.and_then(process_cpu_ms);
    let mut decoder_stream = StreamDecoder::new();
    let mut windows: BTreeMap<u64, WindowStats> = BTreeMap::new();
    let mut hello: Option<proto::ServerHello> = None;
    let mut acted = false;
    let mut pending: std::collections::VecDeque<String> = args.actions.iter().cloned().collect();
    let mut target: Option<u64> = None;
    let mut next_action = Instant::now();
    let vsync_interval = Duration::from_secs_f64(1.0 / args.displays[0].refresh_hz.max(1.0));
    let mut next_vsync = Instant::now();
    let mut text_input_events = 0u32;
    // The phone keyboard's state as the display announced it, in order.
    let mut text_inputs: Vec<proto::TextInputState> = Vec::new();
    let mut games: BTreeMap<u64, GameStats> = BTreeMap::new();
    let mut clipboard: Option<String> = None;
    let mut clipboard_entries: Vec<(String, usize, u64)> = Vec::new();
    // Drag and drop as the server reported it, in order: "status:true", "result:ok",
    // "result:rejected", "start:TYPES", "data:MIME=TEXT_OR_SIZE", "end:taken".
    let mut dnd_events: Vec<String> = Vec::new();
    let mut sound = AudioStats::default();
    let mut ping_sent: Option<u64> = None;
    let mut rtt_us: Option<u64> = None;
    let mut bye: Option<proto::ByeReason> = None;
    // Every byte the server sent.
    let mut wire_bytes: u64 = 0;

    'outer: while start.elapsed() < args.duration {
        if args.stall_after.is_some_and(|s| start.elapsed() >= s) {
            // A suspended client: the socket stays open, nothing is read or sent.
            std::thread::sleep(args.duration.saturating_sub(start.elapsed()));
            break;
        }
        let now = Instant::now();
        // The first window that shows is the one input goes to.
        if target.is_none() {
            target = windows
                .iter()
                .find(|(id, w)| {
                    !w.destroyed
                        && w.kind != "popup"
                        && args.window.is_none_or(|t| t == **id)
                        && w.announced.is_some_and(|t| now.duration_since(t) >= SHOWN_AFTER)
                })
                .map(|(id, _)| *id);
        }
        if let (Some(id), false) = (target, acted) {
            acted = true;
            if let Some((x, y)) = args.click {
                for buttons in [proto::buttons::LEFT, 0] {
                    send(&mut ws, &Message::Pointer(proto::Pointer { id, x, y, buttons, scroll: None, relative: None }))?;
                }
            }
            if let Some((x, y)) = args.touch {
                for phase in [proto::TouchPhase::Down, proto::TouchPhase::Up] {
                    let point = proto::TouchPoint { slot: 0, phase, x, y, force: None, radius: None };
                    send(&mut ws, &Message::Touch(proto::Touch { id, points: vec![point] }))?;
                }
            }
            if let Some(text) = &args.type_text {
                send(&mut ws, &Message::Text(proto::Text { commit: Some(text.clone()), ..Default::default() }))?;
            }
        }
        if let (Some(id), Some(action)) = (target, pending.front().cloned()) {
            if now >= next_action {
                pending.pop_front();
                next_action = now
                    + Duration::from_millis(if action.starts_with("finger-") || action.starts_with("wheel:") { 16 } else { 300 });
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
            Ok(WsMessage::Binary(bytes)) => {
                wire_bytes += bytes.len() as u64;
                decoder_stream.push(&bytes)
            }
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
                        println!("ready: features {:?}", h.features);
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
                    s.app_id = c.app_id.clone();
                    s.pid = c.pid;
                    s.icon_bytes = c.icon.as_ref().map_or(0, Vec::len);
                    s.icons += u64::from(c.icon.is_some());
                    s.geometry = c.geometry;
                    s.kind = c.kind.as_str();
                    s.parent = c.parent;
                    s.alpha = c.alpha;
                    s.announced.get_or_insert_with(Instant::now);
                    s.destroyed = false;
                }
                Message::WindowUpdate(u) => {
                    let s = windows.entry(u.id).or_default();
                    if let Some(t) = u.title {
                        s.title = t;
                    }
                    if let Some(a) = u.app_id {
                        s.app_id = a;
                    }
                    if let Some(p) = u.pid {
                        s.pid = Some(p);
                    }
                    if let Some(i) = &u.icon {
                        s.icon_bytes = i.len();
                        s.icons += 1;
                    }
                    if let Some(g) = u.geometry {
                        s.geometry = g;
                    }
                    if let Some(a) = u.alpha {
                        s.alpha = a;
                    }
                }
                Message::WindowDestroy { id } => {
                    windows.entry(id).or_default().destroyed = true;
                }
                Message::TextInput(t) => {
                    text_input_events += 1;
                    text_inputs.push(t);
                }
                Message::TextFocus { id, editing } => {
                    if let Some(path) = &args.targets {
                        append_line(path, &format!("{{\"t_us\":{},\"id\":{id},\"editing\":{editing}}}\n", monotonic_us()));
                    }
                }
                Message::Targets(t) => {
                    if let Some(path) = &args.targets {
                        let list: Vec<String> = t
                            .targets
                            .iter()
                            .map(|g| format!("[{},{},{},{},{}]", g.rect.x, g.rect.y, g.rect.w, g.rect.h, g.kind))
                            .collect();
                        append_line(
                            path,
                            &format!(
                                "{{\"t_us\":{},\"id\":{},\"serial\":{},\"targets\":[{}]}}\n",
                                monotonic_us(),
                                t.id,
                                t.serial,
                                list.join(",")
                            ),
                        );
                    }
                }
                Message::GameCreate(g) => {
                    // A game's window presents no pictures; it is a target once its game binds.
                    if target.is_none() && args.window.is_none_or(|w| w == g.window) {
                        target = Some(g.window);
                    }
                    games.insert(g.id, GameStats { game: g, destroyed: false });
                }
                Message::GameDestroy { id } => {
                    if let Some(g) = games.get_mut(&id) {
                        g.destroyed = true;
                    }
                }
                Message::ServerClipboard(c) => {
                    clipboard = c
                        .entries()
                        .find(|(m, _)| *m == proto::clipboard::TEXT)
                        .map(|(_, d)| String::from_utf8_lossy(d).into_owned());
                    clipboard_entries = c.entries().map(|(m, d)| (m.to_owned(), d.len(), fnv1a(d))).collect();
                }
                Message::DropStatus { accepted } => {
                    dnd_events.push(format!("status:{}", accepted.map(|a| a.to_string()).unwrap_or("unknown".into())))
                }
                Message::DropResult { ok, reason } => dnd_events
                    .push(format!("result:{}", if ok { "ok" } else { reason.map(|r| r.as_str()).unwrap_or("failed") })),
                Message::DragStart { mimes } => dnd_events.push(format!("start:{}", mimes.join("|"))),
                Message::DragEnd { taken } => {
                    dnd_events.push(format!("end:{}", if taken { "taken" } else { "not-taken" }))
                }
                Message::DragData(c) => {
                    for (mime, data) in c.entries() {
                        let shown = if mime == proto::clipboard::TEXT || mime == proto::clipboard::URI_LIST {
                            String::from_utf8_lossy(data).trim_end().to_owned()
                        } else {
                            format!("{} bytes", data.len())
                        };
                        dnd_events.push(format!("data:{mime}={shown}"));
                    }
                }
                Message::Audio(a) => sound.packet(&a),
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
    let mut ok = hello.is_some() && bye.is_none();
    if let Some(n) = args.windows {
        ok &= windows.len() >= n;
    }
    ok &= sound.errors == 0;

    if args.json {
        let per: Vec<String> = windows
            .iter()
            .map(|(id, w)| {
                format!(
                    "{{\"id\":{id},\"title\":{:?},\"app_id\":{:?},\"pid\":{},\"icon_bytes\":{},\"icons\":{},\"kind\":{:?},\"parent\":{},\"geometry\":[{},{},{},{}],\"alpha\":{},\"destroyed\":{}}}",
                    w.title,
                    w.app_id,
                    w.pid.map(|p| p.to_string()).unwrap_or("null".into()),
                    w.icon_bytes,
                    w.icons,
                    w.kind,
                    w.parent.map(|p| p.to_string()).unwrap_or("null".into()),
                    w.geometry.x,
                    w.geometry.y,
                    w.geometry.w,
                    w.geometry.h,
                    w.alpha,
                    w.destroyed,
                )
            })
            .collect();
        println!(
            "{{\"ok\":{ok},\"seconds\":{elapsed:.2},\"features\":[{}],\"games\":[{}],\"windows\":[{}],\"server_cpu_ms\":{},\"server_cpu_pct\":{},\"rtt_ms\":{},\"text_input_events\":{text_input_events},\"text_inputs\":[{}],\"clipboard\":{},\"clipboard_entries\":[{}],\"dnd\":[{}],\"audio\":{{\"packets\":{},\"bytes\":{},\"decoded\":{},\"errors\":{},\"channels\":{},\"peak\":{:.3},\"gaps\":{}}},\"bye\":{},\"wire_bytes\":{wire_bytes},\"wire_kbps\":{:.0}}}",
            hello.as_ref().map(|h| h.features.iter().map(|f| format!("{f:?}")).collect::<Vec<_>>().join(",")).unwrap_or_default(),
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
            per.join(","),
            cpu_ms.map(|c| format!("{c:.0}")).unwrap_or("null".into()),
            cpu_ms.map(|c| format!("{:.1}", c / elapsed / 10.0)).unwrap_or("null".into()),
            rtt_us.map(|r| format!("{:.2}", r as f64 / 1000.0)).unwrap_or("null".into()),
            text_inputs
                .iter()
                .map(|t| format!(
                    "{{\"window\":{},\"enabled\":{},\"purpose\":{}}}",
                    t.id,
                    t.enabled,
                    t.purpose.as_ref().map(|p| format!("{p:?}")).unwrap_or("null".into())
                ))
                .collect::<Vec<_>>()
                .join(","),
            clipboard.as_ref().map(|c| format!("{c:?}")).unwrap_or("null".into()),
            clipboard_entries
                .iter()
                .map(|(mime, bytes, hash)| format!("{{\"mime\":{mime:?},\"bytes\":{bytes},\"fnv1a\":\"{hash:016x}\"}}"))
                .collect::<Vec<_>>()
                .join(","),
            dnd_events.iter().map(|e| format!("{e:?}")).collect::<Vec<_>>().join(","),
            sound.packets,
            sound.bytes,
            sound.decoded,
            sound.errors,
            sound.channels,
            sound.peak,
            sound.gaps,
            bye.map(|b| format!("\"{}\"", b.as_str())).unwrap_or("null".into()),
            wire_bytes as f64 * 8.0 / 1000.0 / elapsed.max(0.001),
        );
    } else {
        match &hello {
            Some(h) => println!("server: features {:?}", h.features),
            None => println!("server: no hello{}", bye.map(|b| format!(" (bye: {})", b.as_str())).unwrap_or_default()),
        }
        for (id, w) in &windows {
            println!(
                "window {id} {:?}: {} {}x{} at {},{}{}",
                w.title,
                w.kind,
                w.geometry.w,
                w.geometry.h,
                w.geometry.x,
                w.geometry.y,
                if w.destroyed { ", destroyed" } else { "" }
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
        println!("received {wire_bytes} bytes in {elapsed:.1} s");
        if let Some(c) = cpu_ms {
            println!("server CPU: {c:.0} ms over {elapsed:.1} s ({:.1}% of a core)", c / elapsed / 10.0);
        }
        if let Some(r) = rtt_us {
            println!("round trip: {:.2} ms", r as f64 / 1000.0);
        }
        println!("{}", if ok { "OK" } else { "FAILED" });
    }
    Ok(ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        parse_args_from(list.iter().map(|s| s.to_string()))
    }

    #[test]
    fn displays_default_and_parse() {
        let a = args(&[]).unwrap();
        assert_eq!((a.displays[0].width, a.displays[0].height, a.displays[0].scale), (1920, 1080, 1.0));
        let a = args(&["--display", "1179x2556@120x3"]).unwrap();
        assert_eq!((a.displays[0].refresh_hz, a.displays[0].scale), (120.0, 3.0));
    }

    #[test]
    fn picture_options_are_gone() {
        for gone in ["--decoders", "--video-decoders", "--atlas", "--scene", "--zero-video", "--min-fps", "--save"] {
            assert!(args(&[gone, "x"]).is_err(), "{gone}");
        }
    }

    #[test]
    fn actions_become_messages() {
        let key = action_messages(3, "key:ff0d+control").unwrap();
        assert_eq!(key.len(), 2);
        assert!(matches!(&key[0], Message::Key(k) if k.keysym == 0xff0d && k.pressed && k.mods == ["control"]));
        assert!(matches!(action_messages(3, "wait:250").unwrap()[0], Message::Ping { t_us: 250 }));
        assert!(matches!(&action_messages(3, "scroll:10,20,-40").unwrap()[0],
            Message::Pointer(p) if p.scroll.as_ref().is_some_and(|s| s.dy == -40.0 && s.precise)));
        assert!(action_messages(3, "overscan:0,600").is_err());
        assert!(action_messages(3, "nope").is_err());
    }

    #[test]
    fn clipboard_hashes_match_the_check_script() {
        assert_eq!(fnv1a(b""), 0xcbf29ce484222325);
        assert_eq!(fnv1a(b"a"), 0xaf63dc4c8601ec8c);
    }
}
