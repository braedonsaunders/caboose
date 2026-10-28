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
    --duration SECS        how long to run [default: 10]
    --windows N            fail unless at least N windows appear
    --min-fps F            fail unless the busiest window reaches F fps
    --save DIR             write each window's last picture (PNG) and stream here
    --server-pid PID       report the server's CPU time from /proc
    --type TEXT            once a window shows, send TEXT as a text commit to it
    --click X,Y            once a window shows, click there (window-local pixels)
    --touch X,Y            once a window shows, tap there with one finger
    --check                exit 0 as soon as the server answers hello (readiness probe)
    --json                 print the report as one JSON line
";

struct Args {
    url: String,
    token: String,
    displays: Vec<proto::Display>,
    decoders: Vec<Codec>,
    duration: Duration,
    windows: Option<usize>,
    min_fps: Option<f64>,
    save: Option<PathBuf>,
    server_pid: Option<u32>,
    type_text: Option<String>,
    click: Option<(f64, f64)>,
    touch: Option<(f64, f64)>,
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
        duration: Duration::from_secs(10),
        windows: None,
        min_fps: None,
        save: None,
        server_pid: None,
        type_text: None,
        click: None,
        touch: None,
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
            "--decoders" => {
                a.decoders = value()?
                    .split(',')
                    .map(|c| Codec::parse(c.trim()).ok_or(format!("unknown codec {c}")))
                    .collect::<Result<_, _>>()?;
            }
            "--duration" => a.duration = Duration::from_secs_f64(value()?.parse().map_err(|_| "bad --duration")?),
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
}

struct Decoder {
    codec: Codec,
    decoder: ff::decoder::Video,
    last: Option<ff::frame::Video>,
    crop: proto::Rect,
    stream: Option<std::fs::File>,
}

fn open_decoder(codec: Codec) -> Result<ff::decoder::Video, ff::Error> {
    let id = match codec {
        Codec::H264 => ff::codec::Id::H264,
        Codec::Hevc => ff::codec::Id::HEVC,
        Codec::Av1 => ff::codec::Id::AV1,
    };
    let av = ff::decoder::find(id).ok_or(ff::Error::DecoderNotFound)?;
    let mut ctx = ff::codec::context::Context::new_with_codec(av);
    ctx.set_threading(ff::threading::Config { kind: ff::threading::Type::Slice, count: 2 });
    ctx.decoder().video()
}

fn save_png(frame: &ff::frame::Video, crop: proto::Rect, path: &std::path::Path) -> Result<(), String> {
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
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), cw, ch);
    encoder.set_color(png::ColorType::Rgb);
    encoder.write_header().and_then(|mut w| w.write_image_data(&pixels)).map_err(|e| e.to_string())
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
            version: proto::VERSION,
            token: args.token.clone(),
            decoders: args.decoders.clone(),
            displays: args.displays.clone(),
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
    let vsync_interval = Duration::from_secs_f64(1.0 / args.displays[0].refresh_hz.max(1.0));
    let mut next_vsync = Instant::now();
    let mut text_input_events = 0u32;
    let mut ping_sent: Option<u64> = None;
    let mut rtt_us: Option<u64> = None;
    let mut bye: Option<proto::ByeReason> = None;

    'outer: while start.elapsed() < args.duration {
        let now = Instant::now();
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
                        decoders.insert(f.id, Decoder { codec: f.codec, decoder, last: None, crop: f.crop, stream });
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
                if let Err(e) = save_png(frame, d.crop, &dir.join(format!("window-{id}.png"))) {
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
    ok &= windows.values().all(|w| w.decode_errors == 0);

    if args.json {
        let per: Vec<String> = windows
            .iter()
            .map(|(id, w)| {
                let span = match (w.first, w.last) {
                    (Some(a), Some(b)) => (b - a).as_secs_f64(),
                    _ => 0.0,
                };
                format!(
                    "{{\"id\":{id},\"title\":{:?},\"kind\":{:?},\"parent\":{},\"geometry\":[{},{},{},{}],\"keyframe_first\":{},\"codec\":{:?},\"size\":[{},{}],\"frames\":{},\"keyframes\":{},\"fps\":{:.1},\"kbps\":{:.0},\"decode_ms_p50\":{:.2},\"latency_ms_p50\":{:.2},\"latency_ms_p95\":{:.2},\"decode_errors\":{}}}",
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
                    if span > 0.0 { (w.frames.saturating_sub(1)) as f64 / span } else { 0.0 },
                    w.bytes as f64 * 8.0 / 1000.0 / elapsed,
                    percentile(&w.decode_us, 0.5) / 1000.0,
                    percentile(&w.latency_us, 0.5) / 1000.0,
                    percentile(&w.latency_us, 0.95) / 1000.0,
                    w.decode_errors
                )
            })
            .collect();
        println!(
            "{{\"ok\":{ok},\"seconds\":{elapsed:.2},\"windows\":[{}],\"frames\":{total_frames},\"server_cpu_ms\":{},\"server_cpu_pct\":{},\"server_cpu_ms_per_frame\":{},\"rtt_ms\":{},\"text_input_events\":{text_input_events},\"bye\":{}}}",
            per.join(","),
            cpu_ms.map(|c| format!("{c:.0}")).unwrap_or("null".into()),
            cpu_ms.map(|c| format!("{:.1}", c / elapsed / 10.0)).unwrap_or("null".into()),
            cpu_ms.filter(|_| total_frames > 0).map(|c| format!("{:.2}", c / total_frames as f64)).unwrap_or("null".into()),
            rtt_us.map(|r| format!("{:.2}", r as f64 / 1000.0)).unwrap_or("null".into()),
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
