//! Command line.

use std::net::SocketAddr;
use std::path::PathBuf;

pub const USAGE: &str = "\
caboose-display: Caboose's headless Wayland compositor, which renders each window on the phone's GPU

USAGE:
    caboose-display [OPTIONS] [-- COMMAND [ARGS...]]

OPTIONS:
    --listen ADDR          WebSocket listen address [default: 0.0.0.0:14600]
    --token-file PATH      per-wake token, re-read on every hello [default: /run/caboose/display-token]
    --no-auth              accept any token (development only)
    --socket NAME          Wayland socket name in $XDG_RUNTIME_DIR [default: wayland-caboose-0]
    --x-display N          Xwayland display number [default: 110]
    --no-xwayland          do not start Xwayland
    --no-audio             do not run PulseAudio or send sound
    --no-games             do not listen for game launchers (the agent seat)
    --no-devices           do not accept the phone's hardware as devices (the agent seat)
    --private-gpu-stream-socket PATH   private live GPU stream socket (owner only)
    --private-gpu-surface-socket PATH  private live GPU surface socket (owner only)
    --private-gpu-indexed  select the private indexed v4 transport
    --private-gpu-broker PATH  join the computer's shared GPU broker at this seat's control
                           socket (DIR/SEAT/control.sock) instead of starting one; the stream
                           and surface sockets are then DIR/SEAT/gpu.sock and surface.sock,
                           and the agent seat may use its own (DIR/agent)
    --audio-bitrate BPS    Opus bitrate [default: 128000]
    --env-file PATH        write WAYLAND_DISPLAY/DISPLAY for launchers here once ready
    --client-timeout SECS  close a client that has sent nothing for this long; 0 = never
                           [default: 30]
    --display WxH@HZxS     the display used before a client connects [default: 1920x1080@60x1]
    --host-pads            on a container computer's host: make the gamepads its owner
                           display asks for over standard input (docs/devices.md)
    --pad-link             in a container computer: join the owner display's gamepad
                           socket to standard input and output, for the host
    -h, --help             print this help

A COMMAND after `--` is started once the compositor is ready, with WAYLAND_DISPLAY and
DISPLAY set, and the compositor exits when it does.
";

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
    pub private_gpu_stream: Option<PathBuf>,
    pub private_gpu_surface: Option<PathBuf>,
    pub private_gpu_indexed: bool,
    /// The shared broker's control socket for this seat: the compositor is its client and
    /// starts none of its own.
    pub private_gpu_broker: Option<PathBuf>,
    pub socket: String,
    pub x_display: Option<u32>,
    pub audio: bool,
    pub audio_bitrate: u32,
    /// Listen on the game socket and hand games off to clients that run them.
    pub games: bool,
    /// Make the phone's hardware the computer's devices (docs/devices.md).
    pub devices: bool,
    pub env_file: Option<PathBuf>,
    /// Close a client that has sent nothing for this long.
    pub client_timeout: Option<std::time::Duration>,
    pub display: DisplaySpec,
    pub command: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: "0.0.0.0:14600".parse().unwrap(),
            token_file: Some("/run/caboose/display-token".into()),
            private_gpu_stream: None,
            private_gpu_surface: None,
            private_gpu_indexed: false,
            private_gpu_broker: None,
            socket: "wayland-caboose-0".into(),
            x_display: Some(110),
            audio: true,
            audio_bitrate: 128_000,
            games: true,
            devices: true,
            env_file: None,
            client_timeout: Some(std::time::Duration::from_secs(30)),
            display: DisplaySpec { width: 1920, height: 1080, refresh_hz: 60.0, scale: 1.0 },
            command: Vec::new(),
        }
    }
}

impl Config {
    /// The agent launch environment starts no GPU broker. It may join the computer's shared
    /// broker with its own seat's sockets (DIR/agent), never the owner's; the owner seat
    /// never takes the agent's.
    pub fn validate_private_gpu_seat(&self, is_agent: bool) -> Result<(), &'static str> {
        if self.private_gpu_stream.is_none() && self.private_gpu_surface.is_none() { return Ok(()); }
        let seat = self.private_gpu_broker.as_ref().and_then(|broker| broker.parent()).and_then(|dir| dir.file_name());
        let agent_sockets = seat == Some(std::ffi::OsStr::new("agent"));
        if is_agent && !agent_sockets {
            return Err("the agent seat takes only the shared broker's agent sockets");
        }
        if !is_agent && agent_sockets {
            return Err("the owner seat cannot take the agent's GPU sockets");
        }
        Ok(())
    }

    /// The shared broker's seat this compositor takes (its sockets' directory name), if any.
    pub fn gpu_seat(&self) -> Option<&str> {
        self.private_gpu_broker.as_ref()?.parent()?.file_name()?.to_str()
    }

    /// Whether this compositor joins the computer's shared broker.
    pub fn joins_gpu_broker(&self) -> bool { self.private_gpu_broker.is_some() }
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
    HostPads,
    PadLink,
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
            "--private-gpu-stream-socket" => config.private_gpu_stream = Some(value(&mut args, &arg)?.into()),
            "--private-gpu-surface-socket" => config.private_gpu_surface = Some(value(&mut args, &arg)?.into()),
            "--private-gpu-indexed" => config.private_gpu_indexed = true,
            "--private-gpu-broker" => config.private_gpu_broker = Some(value(&mut args, &arg)?.into()),
            "--socket" => config.socket = value(&mut args, &arg)?,
            "--x-display" => config.x_display = Some(number(value(&mut args, &arg)?, &arg)?),
            "--no-xwayland" => config.x_display = None,
            "--no-audio" => config.audio = false,
            "--no-games" => config.games = false,
            "--no-devices" => config.devices = false,
            "--audio-bitrate" => config.audio_bitrate = number(value(&mut args, &arg)?, &arg)?,
            "--env-file" => config.env_file = Some(value(&mut args, &arg)?.into()),
            "--display" => {
                let v = value(&mut args, &arg)?;
                config.display =
                    DisplaySpec::parse(&v).ok_or_else(|| format!("--display: expected WxH@HZxSCALE, got {v}"))?;
            }
            "--client-timeout" => {
                let secs: u64 = number(value(&mut args, &arg)?, &arg)?;
                config.client_timeout = (secs > 0).then(|| std::time::Duration::from_secs(secs));
            }
            "-h" | "--help" => return Ok(Parsed::Help),
            "--host-pads" => return Ok(Parsed::HostPads),
            "--pad-link" => return Ok(Parsed::PadLink),
            "--" => {
                config.command = args.collect();
                break;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    let safe_path = |path: &std::path::Path| path.is_absolute() && path.file_name().is_some() &&
        path.components().all(|part| matches!(part, std::path::Component::RootDir | std::path::Component::Normal(_)));
    // A shared broker's seat has its control socket beside its stream and surface sockets; a
    // compositor's own broker (no --private-gpu-broker) is the owner seat's alone.
    let joined = config.private_gpu_broker.as_deref();
    let beside = |stream: &std::path::Path| joined.map_or(true, |broker| safe_path(broker) && broker != stream && broker.parent() == stream.parent());
    let owner_only = joined.is_some() || (config.games && config.socket != "wayland-caboose-agent");
    match (&config.private_gpu_stream, &config.private_gpu_surface) {
        (None, None) if !config.private_gpu_indexed && joined.is_none() => {},
        (Some(stream), Some(surface)) if owner_only &&
            config.token_file.is_some() && safe_path(stream) && safe_path(surface) && stream != surface &&
            stream.parent().is_some() && stream.parent() == surface.parent() && beside(stream) => {},
        _ => return Err("private GPU requires an authenticated owner seat (or a shared broker's seat) and distinct absolute sockets in one private directory".into()),
    }
    Ok(Parsed::Run(Box::new(config)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(args: &[&str]) -> Config {
        match parse(args.iter().map(|s| s.to_string())).unwrap() {
            Parsed::Run(c) => *c,
            _ => panic!("not a run"),
        }
    }

    #[test]
    fn a_shared_brokers_seat_sockets_are_its_own() {
        let seat = |dir: &str, extra: &[&str]| {
            let control = format!("/run/user/1000/caboose-gpu/{dir}/control.sock");
            let stream = format!("/run/user/1000/caboose-gpu/{dir}/gpu.sock");
            let surface = format!("/run/user/1000/caboose-gpu/{dir}/surface.sock");
            let mut args: Vec<String> = ["--private-gpu-broker", &control, "--private-gpu-stream-socket", &stream,
                "--private-gpu-surface-socket", &surface].iter().map(|s| s.to_string()).collect();
            args.extend(extra.iter().map(|s| s.to_string()));
            parse(args.into_iter())
        };
        let agent = ["--socket", "wayland-caboose-agent", "--no-games", "--no-devices"];
        let Ok(Parsed::Run(config)) = seat("agent", &agent) else { panic!("agent seat") };
        assert!(config.joins_gpu_broker());
        assert!(config.validate_private_gpu_seat(true).is_ok());
        assert!(config.validate_private_gpu_seat(false).is_err());
        let Ok(Parsed::Run(config)) = seat("owner", &[]) else { panic!("owner seat") };
        assert!(config.validate_private_gpu_seat(false).is_ok());
        // The agent seat never takes the owner's sockets.
        let Ok(Parsed::Run(config)) = seat("owner", &agent) else { panic!("parses") };
        assert!(config.validate_private_gpu_seat(true).is_err());
        // The control socket is the seat's, beside its other sockets.
        assert!(parse(["--private-gpu-broker", "/run/a/agent/control.sock", "--private-gpu-stream-socket", "/run/a/owner/gpu.sock",
            "--private-gpu-surface-socket", "/run/a/owner/surface.sock"].iter().map(|s| s.to_string())).is_err());
        assert!(parse(["--private-gpu-broker", "/run/a/agent/control.sock"].iter().map(|s| s.to_string())).is_err());
    }

    #[test]
    fn private_gpu_requires_authenticated_owner_and_both_private_paths() {
        let parse_args = |args: &[&str]| parse(args.iter().map(|s| s.to_string()));
        assert!(run(&[]).private_gpu_stream.is_none());
        assert!(!run(&[]).private_gpu_indexed);
        assert!(parse_args(&["--private-gpu-indexed"]).is_err());
        let paths = ["--private-gpu-stream-socket", "/tmp/private/stream", "--private-gpu-surface-socket", "/tmp/private/surface"];
        assert!(parse_args(&paths).is_ok());
        let mut indexed = paths.to_vec(); indexed.push("--private-gpu-indexed");
        assert!(run(&indexed).private_gpu_indexed);
        assert!(run(&paths).validate_private_gpu_seat(true).is_err());
        assert!(run(&paths).validate_private_gpu_seat(false).is_ok());
        assert!(run(&[]).validate_private_gpu_seat(true).is_ok());
        assert!(parse_args(&paths[..2]).is_err());
        for extra in [&["--no-auth"][..], &["--no-games"][..], &["--socket", "wayland-caboose-agent"][..]] {
            let mut args = paths.to_vec(); args.extend_from_slice(extra);
            assert!(parse_args(&args).is_err());
        }
        assert!(parse_args(&["--private-gpu-stream-socket", "/tmp/p/a", "--private-gpu-surface-socket", "/tmp/q/b"]).is_err());
        assert!(parse_args(&["--private-gpu-stream-socket", "/tmp/p/a", "--private-gpu-surface-socket", "/tmp/p/a"]).is_err());
        assert!(parse_args(&["--private-gpu-stream-socket", "/tmp/p/../a", "--private-gpu-surface-socket", "/tmp/p/../b"]).is_err());
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
        let agent = run(&["--socket", "wayland-caboose-agent", "--x-display", "101"]);
        assert_eq!(owner.instance_dir(runtime), runtime.join("caboose-display/wayland-caboose-0"));
        assert_ne!(owner.instance_dir(runtime), agent.instance_dir(runtime));
        assert!(owner.games);
        assert!(!run(&["--no-games"]).games);
        assert!(owner.devices);
        assert!(!run(&["--no-devices"]).devices);
    }

    #[test]
    fn display_spec_defaults_rate_and_scale() {
        let d = DisplaySpec::parse("1179x2556").unwrap();
        assert_eq!((d.refresh_hz, d.scale), (60.0, 1.0));
        assert!(DisplaySpec::parse("0x10").is_none());
        assert!(DisplaySpec::parse("10x10@60x0.5").is_none());
    }

    #[test]
    fn rejects_unknown_flags() {
        assert!(parse(["--nope".to_string()]).is_err());
        // The picture streaming options are gone with the pipeline they tuned.
        for gone in ["--renderer", "--encoder", "--crf", "--tile-max-px", "--always-compose", "--list-encoders"] {
            assert!(parse([gone.to_string(), "1".to_string()]).is_err(), "{gone}");
        }
    }
}
