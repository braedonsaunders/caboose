//! Command line.

use crate::encode::{Choice, Settings};
use std::net::SocketAddr;
use std::path::PathBuf;

pub const USAGE: &str = "\
caboose-display: Caboose's headless Wayland compositor and per-window stream server

USAGE:
    caboose-display [OPTIONS] [-- COMMAND [ARGS...]]

OPTIONS:
    --listen ADDR          WebSocket listen address [default: 0.0.0.0:14600]
    --token-file PATH      per-wake token, re-read on every hello [default: /run/caboose/xpra-token]
    --no-auth              accept any token (development only)
    --socket NAME          Wayland socket name in $XDG_RUNTIME_DIR [default: wayland-caboose-0]
    --x-display N          Xwayland display number [default: 110]
    --no-xwayland          do not start Xwayland
    --no-audio             do not run PulseAudio or send sound
    --audio-bitrate BPS    Opus bitrate [default: 128000]
    --env-file PATH        write WAYLAND_DISPLAY/DISPLAY for launchers here once ready
    --renderer KIND        pixman [default: pixman]
    --always-compose       compose every window, never copy a shm buffer directly (for
                           comparisons)
    --no-motion            keep regions that update at video rates in the window picture
                           instead of sending them as their own video stream
    --encoder KIND         auto | software | nvenc [default: auto]
    --crf N                encoder quality, lower is better [default: 23]
    --preset NAME          x264 preset [default: ultrafast]
    --refine-qp N          code areas that went quiet once more at this QP, so text
                           sharpens (H.264 software); 0 turns it off [default: 12]
    --refine-after MS      how long an area must be quiet first [default: 300]
    --encoder-threads N    threads per software encoder; 0 = 1 up to 2560x1600, 2 above
                           [default: 0]
    --display WxH@HZxS     the display used before a client connects [default: 1920x1080@60x1]
    --list-encoders        print the usable encoders and exit
    -h, --help             print this help

A COMMAND after `--` is started once the compositor is ready, with WAYLAND_DISPLAY and
DISPLAY set, and the compositor exits when it does.
";

/// The renderer that composes each window's surface tree. Pixman (CPU) is the one this
/// version has; a GPU renderer that composes into dmabufs for the zero-copy encoders
/// is the next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RendererChoice {
    Pixman,
}

#[derive(Debug, Clone)]
pub struct DisplaySpec {
    pub width: i32,
    pub height: i32,
    pub refresh_hz: f64,
    pub scale: f64,
}

impl DisplaySpec {
    pub fn parse(s: &str) -> Option<Self> {
        let (size, rest) = s.split_once('@').unwrap_or((s, "60x1"));
        let (w, h) = size.split_once('x')?;
        let (hz, scale) = rest.split_once('x').unwrap_or((rest, "1"));
        let spec = Self {
            width: w.parse().ok()?,
            height: h.parse().ok()?,
            refresh_hz: hz.parse().ok()?,
            scale: scale.parse().ok()?,
        };
        (spec.width > 0 && spec.height > 0 && spec.refresh_hz > 0.0 && spec.scale >= 1.0).then_some(spec)
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub listen: SocketAddr,
    pub token_file: Option<PathBuf>,
    pub socket: String,
    pub x_display: Option<u32>,
    pub audio: bool,
    pub audio_bitrate: u32,
    pub env_file: Option<PathBuf>,
    pub renderer: RendererChoice,
    pub always_compose: bool,
    /// Send regions that update at video rates as their own video stream (layer 3).
    pub motion: bool,
    pub encoder: Choice,
    pub settings: Settings,
    pub display: DisplaySpec,
    pub list_encoders: bool,
    pub command: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: "0.0.0.0:14600".parse().unwrap(),
            token_file: Some("/run/caboose/xpra-token".into()),
            socket: "wayland-caboose-0".into(),
            x_display: Some(110),
            audio: true,
            audio_bitrate: 128_000,
            env_file: None,
            renderer: RendererChoice::Pixman,
            always_compose: false,
            motion: true,
            encoder: Choice::Auto,
            settings: Settings::default(),
            display: DisplaySpec { width: 1920, height: 1080, refresh_hz: 60.0, scale: 1.0 },
            list_encoders: false,
            command: Vec::new(),
        }
    }
}

pub enum Parsed {
    Run(Box<Config>),
    Help,
}

pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Parsed, String> {
    let mut config = Config::default();
    let mut args = args.into_iter();
    fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
        args.next().ok_or_else(|| format!("{flag} needs a value"))
    }
    fn number<T: std::str::FromStr>(text: String, flag: &str) -> Result<T, String> {
        text.parse().map_err(|_| format!("{flag}: not a number: {text}"))
    }
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => {
                let v = value(&mut args, &arg)?;
                config.listen = v.parse().map_err(|_| format!("--listen: not an address: {v}"))?;
            }
            "--token-file" => config.token_file = Some(value(&mut args, &arg)?.into()),
            "--no-auth" => config.token_file = None,
            "--socket" => config.socket = value(&mut args, &arg)?,
            "--x-display" => config.x_display = Some(number(value(&mut args, &arg)?, &arg)?),
            "--no-xwayland" => config.x_display = None,
            "--no-audio" => config.audio = false,
            "--audio-bitrate" => config.audio_bitrate = number(value(&mut args, &arg)?, &arg)?,
            "--env-file" => config.env_file = Some(value(&mut args, &arg)?.into()),
            "--renderer" => {
                config.renderer = match value(&mut args, &arg)?.as_str() {
                    "pixman" => RendererChoice::Pixman,
                    other => return Err(format!("--renderer: unknown {other}")),
                }
            }
            "--encoder" => {
                config.encoder = match value(&mut args, &arg)?.as_str() {
                    "auto" => Choice::Auto,
                    "software" => Choice::Software,
                    "nvenc" => Choice::Nvenc,
                    other => return Err(format!("--encoder: unknown {other}")),
                }
            }
            "--crf" => config.settings.crf = number(value(&mut args, &arg)?, &arg)?,
            "--preset" => config.settings.preset = value(&mut args, &arg)?,
            "--refine-qp" => config.settings.refine_qp = number(value(&mut args, &arg)?, &arg)?,
            "--refine-after" => config.settings.refine_after_ms = number(value(&mut args, &arg)?, &arg)?,
            "--encoder-threads" => config.settings.threads = number(value(&mut args, &arg)?, &arg)?,
            "--display" => {
                let v = value(&mut args, &arg)?;
                config.display =
                    DisplaySpec::parse(&v).ok_or_else(|| format!("--display: expected WxH@HZxSCALE, got {v}"))?;
            }
            "--always-compose" => config.always_compose = true,
            "--no-motion" => config.motion = false,
            "--list-encoders" => config.list_encoders = true,
            "-h" | "--help" => return Ok(Parsed::Help),
            "--" => {
                config.command = args.collect();
                break;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Parsed::Run(Box::new(config)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> Config {
        match parse(args.iter().map(|s| s.to_string())).unwrap() {
            Parsed::Run(c) => *c,
            Parsed::Help => panic!("help"),
        }
    }

    #[test]
    fn defaults_match_the_contract() {
        let c = run(&[]);
        assert_eq!(c.listen.port(), 14600);
        assert_eq!(c.socket, "wayland-caboose-0");
        assert_eq!(c.x_display, Some(110));
        assert_eq!(c.token_file.as_deref(), Some(std::path::Path::new("/run/caboose/xpra-token")));
    }

    #[test]
    fn parses_a_command_after_the_separator() {
        let c = run(&["--no-auth", "--display", "3840x2160@60x2", "--", "weston-terminal", "--fullscreen"]);
        assert!(c.token_file.is_none());
        assert_eq!((c.display.width, c.display.height, c.display.scale), (3840, 2160, 2.0));
        assert_eq!(c.command, ["weston-terminal", "--fullscreen"]);
    }

    #[test]
    fn display_spec_defaults_rate_and_scale() {
        let d = DisplaySpec::parse("1179x2556").unwrap();
        assert_eq!((d.refresh_hz, d.scale), (60.0, 1.0));
        assert!(DisplaySpec::parse("0x10").is_none());
        assert!(DisplaySpec::parse("10x10@60x0.5").is_none());
    }

    #[test]
    fn refinement_is_on_by_default_and_tunable() {
        let c = run(&[]);
        assert_eq!((c.settings.refine_qp, c.settings.refine_after_ms), (12, 300));
        let c = run(&["--refine-qp", "0", "--refine-after", "1000"]);
        assert_eq!((c.settings.refine_qp, c.settings.refine_after_ms), (0, 1000));
    }

    #[test]
    fn rejects_unknown_flags() {
        assert!(parse(["--nope".to_string()]).is_err());
    }
}
