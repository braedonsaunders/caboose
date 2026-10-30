//! The phone's microphone as a source in the display's PulseAudio (docs/devices.md,
//! "Microphone"): a `module-pipe-source` fed with the phone's Opus, decoded and paced in
//! real time, and a watcher that tells the hub when applications record from it.

use ffmpeg_next as ff;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub const SOURCE: &str = "caboose_phone_microphone";
const RATE: u32 = 48_000;
/// Samples in one 20 ms packet.
const FRAME: usize = 960;
/// Packets buffered before playing, and the most kept before the oldest are dropped.
const PREROLL: usize = 3;
const BACKLOG: usize = 10;

fn pactl(server: &str) -> Command {
    let mut c = Command::new("pactl");
    c.arg(format!("--server={server}")).stdin(Stdio::null()).stderr(Stdio::null());
    c
}

fn run(mut c: Command) -> Result<String, String> {
    let out = c.output().map_err(|e| format!("pactl: {e}"))?;
    if !out.status.success() {
        return Err(format!("pactl exited with {}", out.status));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The PulseAudio source: loaded on creation, unloaded (and the previous default source
/// restored) when dropped.
pub struct Source {
    server: String,
    module: u32,
    pub fifo: PathBuf,
    previous_default: Option<String>,
}

impl Source {
    pub fn load(server: &str, dir: &Path, description: &str) -> Result<Self, String> {
        let fifo = dir.join("phone-microphone.fifo");
        let _ = std::fs::remove_file(&fifo);
        let previous_default = run({
            let mut c = pactl(server);
            c.arg("get-default-source");
            c
        })
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty() && s != SOURCE);
        let module = run({
            let mut c = pactl(server);
            c.args([
                "load-module".to_owned(),
                "module-pipe-source".to_owned(),
                format!("source_name={SOURCE}"),
                format!("file={}", fifo.display()),
                "format=s16le".to_owned(),
                format!("rate={RATE}"),
                "channels=1".to_owned(),
                format!("source_properties=device.description=\"{}\"", description.replace(['"', '\\'], "")),
            ]);
            c
        })?
        .trim()
        .parse::<u32>()
        .map_err(|_| "pactl load-module printed no module index".to_owned())?;
        let source = Self { server: server.to_owned(), module, fifo, previous_default };
        let _ = run({
            let mut c = pactl(server);
            c.args(["set-default-source", SOURCE]);
            c
        });
        Ok(source)
    }

    /// Opens the pipe for writing without blocking (PulseAudio holds its read end).
    pub fn open_writer(&self) -> std::io::Result<OwnedFd> {
        use std::os::unix::fs::OpenOptionsExt;
        let f = std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(&self.fifo)?;
        Ok(f.into())
    }
}

impl Drop for Source {
    fn drop(&mut self) {
        let _ = run({
            let mut c = pactl(&self.server);
            c.args(["unload-module", &self.module.to_string()]);
            c
        });
        if let Some(previous) = &self.previous_default {
            let _ = run({
                let mut c = pactl(&self.server);
                c.args(["set-default-source", previous]);
                c
            });
        }
        let _ = std::fs::remove_file(&self.fifo);
    }
}

/// Counts the streams recording from the source in `pactl list short` output.
pub fn recorders(sources: &str, outputs: &str) -> usize {
    let Some(index) = sources.lines().find_map(|l| {
        let mut cols = l.split('\t');
        let index = cols.next()?;
        (cols.next()? == SOURCE).then(|| index.to_owned())
    }) else {
        return 0;
    };
    outputs.lines().filter(|l| l.split('\t').nth(1) == Some(index.as_str())).count()
}

/// Watches the server's source outputs and reports whether anything records from the
/// source, on each change. Ends when the receiver is gone or pactl exits.
pub struct Watcher {
    child: Child,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Watcher {
    pub fn spawn(server: &str, report: impl Fn(bool) + Send + 'static) -> Result<Self, String> {
        let mut child = pactl(server)
            .arg("subscribe")
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| format!("pactl subscribe: {e}"))?;
        let stdout = child.stdout.take().expect("piped stdout");
        let server = server.to_owned();
        let count = move || -> bool {
            let list = |what: &str| {
                run({
                    let mut c = pactl(&server);
                    c.args(["list", "short", what]);
                    c
                })
                .unwrap_or_default()
            };
            recorders(&list("sources"), &list("source-outputs")) > 0
        };
        let thread = std::thread::Builder::new()
            .name("microphone watch".into())
            .spawn(move || {
                let mut last = count();
                report(last);
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if line.contains("source-output") {
                        let now = count();
                        if now != last {
                            last = now;
                            report(now);
                        }
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(Self { child, thread: Some(thread) })
    }
}

impl Drop for Watcher {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Decodes 20 ms mono Opus packets to s16 PCM.
struct Decoder {
    decoder: ff::decoder::Audio,
    frame: ff::frame::Audio,
}

// SAFETY: the libavcodec context is used only by the writer thread that owns it.
unsafe impl Send for Decoder {}

impl Decoder {
    fn new() -> Result<Self, String> {
        ff::init().map_err(|e| e.to_string())?;
        let codec = ff::decoder::find(ff::codec::Id::OPUS).ok_or("libavcodec has no Opus decoder")?;
        let mut ctx = ff::codec::context::Context::new_with_codec(codec);
        // SAFETY: the context is not open yet; Opus needs its rate and channels before.
        unsafe {
            let raw = ctx.as_mut_ptr();
            (*raw).sample_rate = RATE as i32;
            ff::ffi::av_channel_layout_default(&mut (*raw).ch_layout, 1);
        }
        let decoder = ctx.decoder().audio().map_err(|e| e.to_string())?;
        Ok(Self { decoder, frame: ff::frame::Audio::empty() })
    }

    fn decode(&mut self, packet: &[u8]) -> Result<Vec<i16>, String> {
        self.decoder.send_packet(&ff::Packet::copy(packet)).map_err(|e| e.to_string())?;
        let mut pcm = Vec::new();
        while self.decoder.receive_frame(&mut self.frame).is_ok() {
            pcm.extend(samples(&self.frame));
        }
        Ok(pcm)
    }
}

/// The first channel of a decoded frame as s16.
fn samples(frame: &ff::frame::Audio) -> Vec<i16> {
    use ff::format::sample::{Sample, Type};
    let n = frame.samples();
    let data = frame.data(0);
    // SAFETY: reads the channel count of a frame the decoder filled in.
    let channels = unsafe { (*frame.as_ptr()).ch_layout.nb_channels }.max(1) as usize;
    let stride = if frame.is_planar() { 1 } else { channels };
    match frame.format() {
        Sample::F32(t) => (0..n)
            .map(|i| {
                let at = if t == Type::Planar { i } else { i * stride } * 4;
                let v = f32::from_ne_bytes(data[at..at + 4].try_into().unwrap());
                (v.clamp(-1.0, 1.0) * 32767.0).round() as i16
            })
            .collect(),
        Sample::I16(t) => (0..n)
            .map(|i| {
                let at = if t == Type::Planar { i } else { i * stride } * 2;
                i16::from_ne_bytes([data[at], data[at + 1]])
            })
            .collect(),
        _ => vec![0; n],
    }
}

/// A jitter buffer of 20 ms PCM frames: plays after `PREROLL` frames, keeps at most
/// `BACKLOG`, and gives silence when empty.
#[derive(Default)]
pub struct Jitter {
    frames: VecDeque<Vec<i16>>,
    playing: bool,
}

impl Jitter {
    pub fn push(&mut self, pcm: Vec<i16>) {
        for chunk in pcm.chunks(FRAME) {
            let mut frame = chunk.to_vec();
            frame.resize(FRAME, 0);
            self.frames.push_back(frame);
        }
        while self.frames.len() > BACKLOG {
            self.frames.pop_front();
        }
        if self.frames.len() >= PREROLL {
            self.playing = true;
        }
    }

    /// The next 20 ms: a frame, or silence while prerolling or starved.
    pub fn next(&mut self) -> Vec<i16> {
        if self.playing {
            if let Some(f) = self.frames.pop_front() {
                return f;
            }
            self.playing = false;
        }
        vec![0; FRAME]
    }

    pub fn clear(&mut self) {
        self.frames.clear();
        self.playing = false;
    }
}

pub enum Input {
    Opus(Vec<u8>),
    /// The phone is gone: silence, and forget what was buffered.
    Detach,
}

/// Writes the source's pipe every 20 ms until its channel closes.
pub struct Writer {
    pub tx: mpsc::Sender<Input>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Writer {
    pub fn spawn(fifo: OwnedFd) -> std::io::Result<Self> {
        let (tx, rx) = mpsc::channel();
        let thread = std::thread::Builder::new().name("microphone".into()).spawn(move || write_loop(fifo, rx))?;
        Ok(Self { tx, thread: Some(thread) })
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        let (dead, _) = mpsc::channel();
        self.tx = dead;
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn write_loop(fifo: OwnedFd, rx: mpsc::Receiver<Input>) {
    let mut decoder: Option<Decoder> = None;
    let mut jitter = Jitter::default();
    let tick = Duration::from_millis(20);
    let mut next = Instant::now();
    loop {
        // Take what arrived until this tick is due.
        loop {
            let wait = next.saturating_duration_since(Instant::now());
            match rx.recv_timeout(wait) {
                Ok(Input::Opus(packet)) => {
                    if decoder.is_none() {
                        match Decoder::new() {
                            Ok(d) => decoder = Some(d),
                            Err(e) => {
                                tracing::warn!("microphone: {e}");
                                return;
                            }
                        }
                    }
                    match decoder.as_mut().unwrap().decode(&packet) {
                        Ok(pcm) => jitter.push(pcm),
                        Err(e) => tracing::debug!("microphone: decode: {e}"),
                    }
                }
                Ok(Input::Detach) => {
                    jitter.clear();
                    decoder = None;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
        let frame = jitter.next();
        let bytes: Vec<u8> = frame.iter().flat_map(|s| s.to_le_bytes()).collect();
        // A full pipe (nothing reading) drops the frame rather than falling behind.
        let _ = super::sys::write_all(&fifo, &bytes);
        next += tick;
        // After a stall, resume from now rather than writing a burst.
        if Instant::now() > next + tick * 5 {
            next = Instant::now() + tick;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recorders_count_only_the_phone_source() {
        let sources = "0\tcaboose.monitor\tmodule-null-sink.c\ts16le 2ch 48000Hz\tSUSPENDED\n\
                       1\tcaboose_phone_microphone\tmodule-pipe-source.c\ts16le 1ch 48000Hz\tRUNNING\n";
        let outputs = "4\t0\t12\tprotocol-native.c\ts16le 2ch 48000Hz\n\
                       7\t1\t15\tprotocol-native.c\tfloat32le 1ch 48000Hz\n\
                       8\t1\t16\tprotocol-native.c\ts16le 1ch 48000Hz\n";
        assert_eq!(recorders(sources, outputs), 2);
        assert_eq!(recorders(sources, "4\t0\t12\tprotocol-native.c\ts16le 2ch 48000Hz\n"), 0);
        assert_eq!(recorders("0\tcaboose.monitor\tx\ty\tz\n", outputs), 0, "no phone source");
    }

    #[test]
    fn jitter_prerolls_then_plays_in_order() {
        let mut j = Jitter::default();
        j.push(vec![1; FRAME]);
        j.push(vec![2; FRAME]);
        assert_eq!(j.next(), vec![0; FRAME], "still prerolling");
        j.push(vec![3; FRAME]);
        assert_eq!(j.next()[0], 1);
        assert_eq!(j.next()[0], 2);
        assert_eq!(j.next()[0], 3);
        assert_eq!(j.next(), vec![0; FRAME], "starved: silence, then preroll again");
        j.push(vec![4; FRAME]);
        assert_eq!(j.next(), vec![0; FRAME]);
    }

    #[test]
    fn jitter_bounds_its_backlog() {
        let mut j = Jitter::default();
        for i in 0..15 {
            j.push(vec![i; FRAME]);
        }
        assert_eq!(j.next()[0], 5, "the oldest beyond the backlog were dropped");
    }

    #[test]
    fn a_short_decode_is_padded_to_a_frame() {
        let mut j = Jitter::default();
        j.push(vec![9; FRAME * 2 + 10]);
        assert_eq!(j.next().len(), FRAME);
        j.next();
        let last = j.next();
        assert_eq!((&last[..10], last[10]), (&[9i16; 10][..], 0));
    }
}
