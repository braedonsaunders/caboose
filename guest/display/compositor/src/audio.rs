//! The computer's sound, for the phone.
//!
//! The compositor runs its own PulseAudio server on a private socket
//! (`pulse/native` in the instance's directory, `Config::instance_dir`), whose only sink is a null sink named
//! `caboose`, so it is every application's default output. Launched applications get
//! `PULSE_SERVER` pointing at it. While a client that plays Opus is connected, `parec`
//! records the sink's monitor; each 20 ms of 48 kHz stereo is encoded with libopus on a
//! thread and sent as `audio` with the capture time of its first sample on the clock the
//! pictures use. Digital silence is not sent after a second of it, and nothing records
//! while no client listens.

use ffmpeg_next as ff;
use smithay::reexports::calloop::channel::Sender;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub const RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;
/// Samples per channel in one 20 ms packet.
pub const FRAME: usize = 960;
const BYTES: usize = FRAME * CHANNELS as usize * 2;
/// Silent packets sent before going quiet (one second), so the decoder ends cleanly.
const SILENT_PACKETS_SENT: u32 = 50;

/// One encoded packet.
pub struct Packet {
    pub pts_us: u64,
    pub data: Vec<u8>,
}

fn monotonic_us() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes the timespec it is given.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1000
}

/// The compositor's PulseAudio server.
pub struct Audio {
    pub socket: PathBuf,
    server: Child,
    capture: Option<Capture>,
}

struct Capture {
    recorder: Child,
    stop: Arc<AtomicBool>,
}

impl Drop for Audio {
    fn drop(&mut self) {
        self.stop_capture();
        let _ = self.server.kill();
        let _ = self.server.wait();
    }
}

impl Audio {
    /// Starts PulseAudio with the null sink, its socket under the instance's private
    /// directory. `None` (logged) if PulseAudio or parec is not installed or does not come up.
    pub fn start(instance_dir: &Path) -> Option<Self> {
        let dir = instance_dir.join("pulse");
        if let Err(e) = std::fs::create_dir_all(&dir) {
            tracing::warn!("no audio: {}: {e}", dir.display());
            return None;
        }
        let socket = dir.join("native");
        let _ = std::fs::remove_file(&socket);
        let server = Command::new("pulseaudio")
            .args(["--daemonize=no", "--exit-idle-time=-1", "--use-pid-file=no", "--system=no", "-n", "--log-target=stderr"])
            .arg(format!("--load=module-native-protocol-unix socket={} auth-anonymous=1", socket.display()))
            .arg("--load=module-null-sink sink_name=caboose rate=48000 channels=2 sink_properties=device.description=Caboose")
            .env("PULSE_RUNTIME_PATH", &dir)
            .env("PULSE_STATE_PATH", &dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let mut server = match server {
            Ok(s) => s,
            Err(e) => {
                tracing::info!("no audio: cannot start PulseAudio: {e}");
                return None;
            }
        };
        for _ in 0..50 {
            if socket.exists() {
                tracing::info!("audio: PulseAudio on {}", socket.display());
                return Some(Self { socket, server, capture: None });
            }
            if let Ok(Some(status)) = server.try_wait() {
                tracing::warn!("no audio: PulseAudio exited ({status})");
                return None;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        tracing::warn!("no audio: PulseAudio did not create {}", socket.display());
        let _ = server.kill();
        None
    }

    pub fn server_address(&self) -> String {
        format!("unix:{}", self.socket.display())
    }

    /// Records the sink and sends encoded packets to `out` until [`Self::stop_capture`].
    pub fn start_capture(&mut self, out: Sender<Packet>, bitrate: u32) {
        if self.capture.is_some() {
            return;
        }
        let recorder = Command::new("parec")
            .arg(format!("--server={}", self.server_address()))
            .args([
                "--device=caboose.monitor",
                "--format=s16le",
                "--rate=48000",
                "--channels=2",
                "--latency-msec=20",
                "--raw",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn();
        let mut recorder = match recorder {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("no audio capture: parec: {e}");
                return;
            }
        };
        let stdout = recorder.stdout.take().expect("piped stdout");
        let stop = Arc::new(AtomicBool::new(false));
        let stop_thread = stop.clone();
        let spawned = std::thread::Builder::new().name("audio".into()).spawn(move || {
            if let Err(e) = encode_loop(stdout, out, bitrate, &stop_thread) {
                // Killing the recorder on a deliberate stop ends its stream; only an
                // unexpected end is worth a warning.
                if !stop_thread.load(Ordering::Relaxed) {
                    tracing::warn!("audio capture stopped: {e}");
                }
            }
        });
        if let Err(e) = spawned {
            tracing::warn!("no audio capture: {e}");
            let _ = recorder.kill();
            return;
        }
        tracing::info!("audio: capturing");
        self.capture = Some(Capture { recorder, stop });
    }

    pub fn stop_capture(&mut self) {
        if let Some(mut c) = self.capture.take() {
            c.stop.store(true, Ordering::Relaxed);
            let _ = c.recorder.kill();
            let _ = c.recorder.wait();
            tracing::info!("audio: capture stopped");
        }
    }
}

/// An Opus encoder for 20 ms of 48 kHz stereo.
pub struct OpusEncoder {
    encoder: ff::encoder::Audio,
    frame: ff::frame::Audio,
    samples: i64,
}

// SAFETY: the libavcodec context is used by one thread at a time.
unsafe impl Send for OpusEncoder {}

impl OpusEncoder {
    pub fn new(bitrate: u32) -> Result<Self, String> {
        ff::init().map_err(|e| e.to_string())?;
        let codec = ff::encoder::find_by_name("libopus").ok_or("libavcodec has no libopus")?;
        let mut ctx =
            ff::codec::context::Context::new_with_codec(codec).encoder().audio().map_err(|e| e.to_string())?;
        ctx.set_rate(RATE as i32);
        ctx.set_channel_layout(ff::ChannelLayout::STEREO);
        ctx.set_format(ff::format::Sample::I16(ff::format::sample::Type::Packed));
        ctx.set_bit_rate(bitrate as usize);
        ctx.set_time_base(ff::Rational(1, RATE as i32));
        let mut options = ff::Dictionary::new();
        options.set("application", "audio");
        options.set("frame_duration", "20");
        options.set("vbr", "on");
        let encoder = ctx.open_with(options).map_err(|e| e.to_string())?;
        let frame = ff::frame::Audio::new(
            ff::format::Sample::I16(ff::format::sample::Type::Packed),
            FRAME,
            ff::ChannelLayout::STEREO,
        );
        Ok(Self { encoder, frame, samples: 0 })
    }

    /// Encodes 960 interleaved stereo samples (little-endian i16); returns the packets
    /// that came out (one per call once the encoder is primed).
    pub fn encode(&mut self, pcm: &[u8]) -> Result<Vec<Vec<u8>>, String> {
        if pcm.len() != BYTES {
            return Err(format!("expected {BYTES} bytes of PCM, got {}", pcm.len()));
        }
        self.frame.data_mut(0)[..BYTES].copy_from_slice(pcm);
        self.frame.set_pts(Some(self.samples));
        self.samples += FRAME as i64;
        self.encoder.send_frame(&self.frame).map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        let mut packet = ff::Packet::empty();
        while self.encoder.receive_packet(&mut packet).is_ok() {
            if let Some(d) = packet.data() {
                out.push(d.to_vec());
            }
        }
        Ok(out)
    }
}

fn encode_loop(mut pcm: impl Read, out: Sender<Packet>, bitrate: u32, stop: &AtomicBool) -> Result<(), String> {
    let mut encoder = OpusEncoder::new(bitrate)?;
    let mut block = vec![0u8; BYTES];
    let mut silent: u32 = 0;
    while !stop.load(Ordering::Relaxed) {
        pcm.read_exact(&mut block).map_err(|e| e.to_string())?;
        // The block just finished arriving: its first sample was captured 20 ms of
        // samples and the recorder's 20 ms latency ago.
        let pts_us = monotonic_us().saturating_sub(40_000);
        if block.iter().all(|b| *b == 0) {
            silent = silent.saturating_add(1);
            if silent > SILENT_PACKETS_SENT {
                continue;
            }
        } else {
            silent = 0;
        }
        for data in encoder.encode(&block)? {
            if out.send(Packet { pts_us, data }).is_err() {
                return Ok(());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn twenty_milliseconds_of_stereo_encode_to_stereo_opus() {
        let mut enc = OpusEncoder::new(128_000).unwrap();
        let mut packets = Vec::new();
        for n in 0..10 {
            // A 440 Hz tone.
            let pcm: Vec<u8> = (0..FRAME)
                .flat_map(|i| {
                    let t = (n * FRAME + i) as f64 / RATE as f64;
                    let v = ((t * 440.0 * std::f64::consts::TAU).sin() * 8000.0) as i16;
                    [v.to_le_bytes(), v.to_le_bytes()].concat()
                })
                .collect();
            packets.extend(enc.encode(&pcm).unwrap());
        }
        assert!(packets.len() >= 8, "one packet per 20 ms once primed: {}", packets.len());
        for p in &packets {
            let toc = p[0];
            assert_eq!((toc >> 2) & 1, 1, "stereo");
            assert_eq!(toc & 3, 0, "one frame per packet");
        }
    }

    #[test]
    fn wrong_sized_blocks_are_rejected() {
        let mut enc = OpusEncoder::new(64_000).unwrap();
        assert!(enc.encode(&[0u8; 100]).is_err());
    }
}
