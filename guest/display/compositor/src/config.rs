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
    --token-file PATH      per-wake token, re-read on every hello [default: /run/caboose/display-token]
    --no-auth              accept any token (development only)
    --socket NAME          Wayland socket name in $XDG_RUNTIME_DIR [default: wayland-caboose-0]
    --x-display N          Xwayland display number [default: 110]
    --no-xwayland          do not start Xwayland
    --x11-only             point applications at Xwayland alone: the env file names DISPLAY
                           and X11 toolkit backends, not WAYLAND_DISPLAY (for a seat driven
                           by X11 tools, such as the agent seat)
    --no-audio             do not run PulseAudio or send sound
    --audio-bitrate BPS    Opus bitrate [default: 128000]
    --env-file PATH        write WAYLAND_DISPLAY/DISPLAY for launchers here once ready
    --renderer KIND        pixman [default: pixman]
    --always-compose       compose every window, never copy a shm buffer directly (for
                           comparisons)
    --no-motion            keep regions that update at video rates in the window picture
                           instead of sending them as their own video stream
    --client-timeout SECS  close a client that has sent nothing for this long; 0 = never
                           [default: 30]
    --encoder KIND         auto | software | nvenc [default: auto]
    --crf N                encoder quality, lower is better [default: 23]
    --preset NAME          x264 preset [default: ultrafast]
    --refine-qp N          code areas that went quiet once more at this QP, so text
                           sharpens (H.264 software); 0 turns it off [default: 12]
    --refine-after MS      how long an area must be quiet first [default: 300]
    --tile-max-px N        send changes of at most N pixels as lossless PNG tiles instead
                           of a picture (software encoders); 0 turns tiles off
                           [default: 65536]
    --encoder-threads N    threads per software encoder; 0 = 1 up to 2560x1600, 2 above
                           [default: 0]
    --display WxH@HZxS     the display used before a client connects [default: 1920x1080@60x1]
    --list-encoders        print the usable encoders and exit
    -h, --help             print this help

A COMMAND after `--` is started once the compositor is ready, with WAYLAND_DISPLAY and
DISPLAY set, and the compositor exits when it does.
";

/// The renderer that composes each window's surface tree: Pixman, on the CPU.
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
    /// Applications are pointed at Xwayland alone.
    pub x11_only: bool,
    pub audio: bool,
    pub audio_bitrate: u32,
    pub env_file: Option<PathBuf>,
    pub renderer: RendererChoice,
    pub always_compose: bool,
    /// Send regions that update at video rates as their own video stream.
    pub motion: bool,
    /// Close a client that has sent nothing for this long.
    pub client_timeout: Option<std::time::Duration>,
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
            token_file: Some("/run/caboose/display-token".into()),
            socket: "wayland-caboose-0".into(),
            x_display: Some(110),
            x11_only: false,
            audio: true,
            audio_bitrate: 128_000,
            env_file: None,
            renderer: RendererChoice::Pixman,
            always_compose: false,
            motion: true,
            client_timeout: Some(std::time::Duration::from_secs(30)),
            encoder: Choice::Auto,
            settings: Settings::default(),
            display: DisplaySpec { width: 1920, height: 1080, refresh_hz: 60.0, scale: 1.0 },
            list_encoders: false,
            command: Vec::new(),
        }
    }
}

impl Config {
    /// This instance's private state (X11 authority, the Xwayland shim, PulseAudio) under
    /// `runtime_dir`, named after its Wayland socket so that two instances (the owner's
    /// display and the agent seat) never share it.
    pub fn instance_dir(&self, runtime_dir: &std::path::Path) -> PathBuf {
        runtime_dir.join("caboose-display").join(&self.socket)
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
            "--x11-only" => config.x11_only = true,
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
            "--tile-max-px" => config.settings.tile_max_px = number(value(&mut args, &arg)?, &arg)?,
            "--encoder-threads" => config.settings.threads = number(value(&mut args, &arg)?, &arg)?,
            "--display" => {
                let v = value(&mut args, &arg)?;
                config.display =
                    DisplaySpec::parse(&v).ok_or_else(|| format!("--display: expected WxH@HZxSCALE, got {v}"))?;
            }
            "--always-compose" => config.always_compose = true,
            "--no-motion" => config.motion = false,
            "--client-timeout" => {
                let secs: u64 = number(value(&mut args, &arg)?, &arg)?;
                config.client_timeout = (secs > 0).then(|| std::time::Duration::from_secs(secs));
            }
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
        assert_eq!(c.token_file.as_deref(), Some(std::path::Path::new("/run/caboose/display-token")));
    }

    #[test]
    fn parses_a_command_after_the_separator() {
        let c = run(&["--no-auth", "--display", "3840x2160@60x2", "--", "weston-terminal", "--fullscreen"]);
        assert!(c.token_file.is_none());
        assert_eq!((c.display.width, c.display.height, c.display.scale), (3840, 2160, 2.0));
        assert_eq!(c.command, ["weston-terminal", "--fullscreen"]);
    }

    #[test]
    fn instances_are_kept_apart_by_socket() {
        let runtime = std::path::Path::new("/run/user/1000");
        let owner = run(&[]);
        let agent = run(&["--socket", "wayland-caboose-agent", "--x-display", "101", "--x11-only"]);
        assert!(!owner.x11_only && agent.x11_only);
        assert_eq!(owner.instance_dir(runtime), runtime.join("caboose-display/wayland-caboose-0"));
        assert_ne!(owner.instance_dir(runtime), agent.instance_dir(runtime));
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
