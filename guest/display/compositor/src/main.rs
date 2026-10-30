//! caboose-display: Caboose's headless Wayland compositor. See docs/display.md.

mod audio;
mod devices;
mod clipboard;
mod config;
mod control;
mod displays;
mod encode;
mod game;
mod gpu_supervisor;
mod input;
mod keymap;
mod motion;
mod net;
mod pencil;
mod render;
mod session;
mod state;
mod stream;
mod text_input;
mod video;
mod windows;
mod x11_focus;
mod xauth;
mod xwm;

use config::{Config, Parsed, RendererChoice};
use encode::Encoders;
use smithay::backend::renderer::pixman::PixmanRenderer;
use smithay::backend::renderer::ImportDma;
use smithay::input::keyboard::{xkb, XkbConfig};
use smithay::reexports::calloop::channel::{channel, Event as ChannelEvent};
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::calloop::{EventLoop, Interest, Mode, PostAction};
use smithay::reexports::wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration_manager::Mode as KdeDecorationMode;
use smithay::reexports::wayland_server::Display;
use smithay::utils::Clock;
use smithay::wayland::compositor::CompositorState;
use smithay::wayland::cursor_shape::CursorShapeManagerState;
use smithay::wayland::dmabuf::DmabufState;
use smithay::wayland::fractional_scale::FractionalScaleManagerState;
use smithay::wayland::output::OutputManagerState;
use smithay::wayland::selection::data_device::DataDeviceState;
use smithay::wayland::selection::primary_selection::PrimarySelectionState;
use smithay::wayland::shell::kde::decoration::KdeDecorationState;
use smithay::wayland::shell::xdg::decoration::XdgDecorationState;
use smithay::wayland::shell::xdg::XdgShellState;
use smithay::wayland::shm::ShmState;
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::viewporter::ViewporterState;
use smithay::wayland::xwayland_shell::XWaylandShellState;
use smithay::xwayland::{X11Wm, XWayland, XWaylandEvent};
use state::{ClientState, State};
use std::sync::Arc;
use std::time::Duration;

/// Environment for applications started under the compositor. Toolkits are pointed at
/// Wayland first, X11 (through Xwayland) second, and GTK 3 at the desktop portal, which
/// answers file choosing and appearance from the phone (docs/native-bridge.md).
const TOOLKIT_ENV: &[(&str, &str)] = &[
    ("GDK_BACKEND", "wayland,x11"),
    ("GTK_USE_PORTAL", "1"),
    ("GTK_CSD", "0"),
    ("QT_QPA_PLATFORM", "wayland;xcb"),
    ("MOZ_ENABLE_WAYLAND", "1"),
    ("SDL_VIDEODRIVER", "wayland,x11"),
    ("ELECTRON_OZONE_PLATFORM_HINT", "auto"),
];

fn main() {
    xauth::shim_if_invoked();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CABOOSE_DISPLAY_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();
    let config = match config::parse(std::env::args().skip(1)) {
        Ok(Parsed::Run(c)) => *c,
        Ok(Parsed::Help) => {
            print!("{}", config::USAGE);
            return;
        }
        Err(e) => {
            eprintln!("caboose-display: {e}\n\n{}", config::USAGE);
            std::process::exit(2);
        }
    };
    if let Err(e) = run(config) {
        eprintln!("caboose-display: {e}");
        std::process::exit(1);
    }
}

/// The compositor's own GPU selection, passed on so applications render the same way
/// (Mesa's D3D12 driver on WSL, a VA-API driver choice).
const PASSED_ENV: &[&str] = &["GALLIUM_DRIVER", "MESA_D3D12_DEFAULT_ADAPTER_NAME", "LIBVA_DRIVER_NAME"];

/// Whether the Caboose VA-API driver is installed where libva looks.
fn passthrough_driver_installed() -> bool {
    let dirs = std::env::var("LIBVA_DRIVERS_PATH").unwrap_or_else(|_| "/usr/lib/x86_64-linux-gnu/dri".into());
    dirs.split(':').any(|d| std::path::Path::new(d).join("caboose_drv_video.so").is_file())
}

fn launch_env(
    config: &Config,
    x_display: Option<u32>,
    xauthority: Option<&std::path::Path>,
    video_socket: Option<&std::path::Path>,
) -> Vec<(String, String)> {
    let mut env = vec![("WAYLAND_DISPLAY".to_owned(), config.socket.clone())];
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        env.push(("XDG_RUNTIME_DIR".into(), dir));
    }
    if let Some(n) = x_display {
        env.push(("DISPLAY".into(), format!(":{n}")));
        if let Some(a) = xauthority {
            env.push(("XAUTHORITY".into(), a.display().to_string()));
        }
    }
    // Agent application state and IPC must follow its private home on every launch.
    // The owner keeps the existing environment contract.
    if std::env::var("CABOOSE_SEAT").as_deref() == Ok("agent") {
        for key in [
            "HOME",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_STATE_HOME",
            "CABOOSE_SEAT",
            "MOZ_NO_REMOTE",
            "DBUS_SESSION_BUS_ADDRESS",
            "VSCODE_PORTABLE",
            "CHROME_CONFIG_HOME",
            "CHROME_USER_DATA_DIR",
            "PATH",
        ] {
            if let Ok(value) = std::env::var(key) {
                env.push((key.into(), value));
            }
        }
        env.push(("VSCODE_IPC_HOOK_CLI".into(), String::new()));
    }
    env.extend(TOOLKIT_ENV.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    // Video passthrough: players decode through the Caboose VA-API driver, which hands the
    // bitstream to this compositor. Only here: without the compositor's socket the driver
    // does not initialise, so the variable must not leak into other sessions.
    let passthrough = video_socket.filter(|_| passthrough_driver_installed());
    if let Some(socket) = passthrough {
        env.push(("LIBVA_DRIVER_NAME".into(), "caboose".into()));
        env.push(("GST_VA_ALL_DRIVERS".into(), "1".into()));
        env.push(("CABOOSE_VIDEO_SOCKET".into(), socket.display().to_string()));
    }
    env.extend(
        PASSED_ENV
            .iter()
            .filter(|k| !(passthrough.is_some() && **k == "LIBVA_DRIVER_NAME"))
            .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v))),
    );
    env
}

/// Once the compositor (and Xwayland) are up: the env file for launchers, and the
/// command to run, if any.
fn ready(state: &mut State, x_display: Option<u32>, xauthority: Option<&std::path::Path>) {
    let mut env = launch_env(&state.config, x_display, xauthority, state.videos.socket.as_deref());
    if let Some(audio) = &state.audio {
        // Applications play into the compositor's PulseAudio, whose sound goes to the phone.
        env.push(("PULSE_SERVER".into(), audio.server_address()));
    }
    if let Some(socket) = &state.games.socket {
        // Game handoff: caboose-game-run finds the compositor here (game.rs).
        env.push(("CABOOSE_GAME_SOCKET".into(), socket.display().to_string()));
    }
    if let Some(socket) = &state.control.socket {
        // The seat for local tools: windows, input and pictures (control.rs).
        env.push(("CABOOSE_DISPLAY_CONTROL".into(), socket.display().to_string()));
    }
    if let Some(path) = &state.config.env_file {
        // KEY=VALUE lines, values single-quoted for sh. Written in place: the file may
        // be pre-created by root in a directory the compositor cannot write, and
        // readers wait for readiness before reading it.
        let body: String = env.iter().map(|(k, v)| format!("{k}='{}'\n", v.replace('\'', "'\\''"))).collect();
        if let Err(e) = std::fs::write(path, body) {
            tracing::warn!("cannot write {}: {e}", path.display());
        }
    }
    tracing::info!(
        "ready: WAYLAND_DISPLAY={}{}",
        state.config.socket,
        x_display.map(|n| format!(" DISPLAY=:{n}")).unwrap_or_default()
    );
    if let Some((program, args)) = state.config.command.split_first() {
        let mut command = std::process::Command::new(program);
        command.args(args).envs(env);
        match command.spawn() {
            Ok(mut child) => {
                let (tx, rx) = channel::<std::process::ExitStatus>();
                std::thread::spawn(move || {
                    if let Ok(status) = child.wait() {
                        let _ = tx.send(status);
                    }
                });
                let _ = state.handle.insert_source(rx, |event, _, state: &mut State| {
                    if let ChannelEvent::Msg(status) = event {
                        tracing::info!("command exited: {status}");
                        state.signal.stop();
                    }
                });
            }
            Err(e) => {
                tracing::error!("cannot start {program}: {e}");
                state.signal.stop();
            }
        }
    }
}

static SIGNAL_PIPE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

extern "C" fn on_signal(_: libc::c_int) {
    let fd = SIGNAL_PIPE.load(std::sync::atomic::Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; a full pipe already means "stop".
        unsafe { libc::write(fd, b"x".as_ptr().cast(), 1) };
    }
}

/// SIGTERM and SIGINT stop the loop cleanly (Xwayland and clients are told, the
/// summary is logged).
fn stop_on_signals(handle: &smithay::reexports::calloop::LoopHandle<'static, State>) -> Result<(), String> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills the two descriptors it is given.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    // SAFETY: fds[0] is a new descriptor owned from here on.
    let read = unsafe { <std::os::fd::OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(fds[0]) };
    SIGNAL_PIPE.store(fds[1], std::sync::atomic::Ordering::Relaxed);
    for sig in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: the handler only performs an async-signal-safe write.
        unsafe { libc::signal(sig, on_signal as *const () as libc::sighandler_t) };
    }
    handle
        .insert_source(Generic::new(read, Interest::READ, Mode::Level), |_, _, state: &mut State| {
            tracing::info!("signal received, stopping");
            state.signal.stop();
            Ok(PostAction::Remove)
        })
        .map(|_| ())
        .map_err(|e| e.to_string())
}

fn run(config: Config) -> Result<(), String> {
    let encoders = Encoders::probe(config.encoder, config.settings.clone());
    if config.list_encoders {
        for b in &encoders.backends {
            println!("{}", b.describe());
        }
        return Ok(());
    }
    if encoders.backends.is_empty() {
        return Err("no usable encoder".into());
    }
    for b in &encoders.backends {
        tracing::info!("encoder: {}", b.describe());
    }
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        return Err("XDG_RUNTIME_DIR is not set".into());
    }

    let mut event_loop: EventLoop<'static, State> = EventLoop::try_new().map_err(|e| e.to_string())?;
    let display: Display<State> = Display::new().map_err(|e| e.to_string())?;
    let dh = display.handle();

    let renderer = match config.renderer {
        RendererChoice::Pixman => render::Renderer::Pixman(PixmanRenderer::new().map_err(|e| format!("pixman: {e}"))?),
    };
    tracing::info!("renderer: {}", renderer.name());

    let compositor = CompositorState::new::<State>(&dh);
    let xdg_shell = XdgShellState::new::<State>(&dh);
    let shm = ShmState::new::<State>(&dh, vec![]);
    let mut dmabuf = DmabufState::new();
    // linux-dmabuf: the pixman renderer maps linear dmabufs, so clients that allocate
    // GPU buffers can hand them over without a copy into shm.
    let render::Renderer::Pixman(r) = &renderer;
    let formats: Vec<_> = r.dmabuf_formats().into_iter().collect();
    if !formats.is_empty() {
        dmabuf.create_global::<State>(&dh, formats);
    }
    OutputManagerState::new_with_xdg_output::<State>(&dh);
    XdgDecorationState::new::<State>(&dh);
    // GTK 3 uses this legacy protocol, not xdg-decoration, for ordinary windows.
    let kde_decoration = KdeDecorationState::new::<State>(&dh, KdeDecorationMode::Server);
    ViewporterState::new::<State>(&dh);
    FractionalScaleManagerState::new::<State>(&dh);
    CursorShapeManagerState::new::<State>(&dh);
    smithay::wayland::relative_pointer::RelativePointerManagerState::new::<State>(&dh);
    let mut seat_state = smithay::input::SeatState::new();
    let mut seat = seat_state.new_wl_seat(&dh, "seat0");
    seat.add_keyboard(XkbConfig::default(), 400, 30).map_err(|e| format!("keyboard: {e}"))?;
    seat.add_pointer();
    seat.add_touch();
    let tablet = pencil::advertise(&dh, &seat);
    let data_device = DataDeviceState::new::<State>(&dh);
    let primary_selection = PrimarySelectionState::new::<State>(&dh);
    let xwayland_shell = XWaylandShellState::new::<State>(&dh);
    let text_inputs = text_input::TextInputs::new(&dh);

    // The same keymap the seat compiled from the default names.
    let xkb_context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let keymap = xkb::Keymap::new_from_names(&xkb_context, "", "", "", "", None, xkb::KEYMAP_COMPILE_NO_FLAGS)
        .ok_or("cannot compile the default keymap")?;
    let mut input = input::InputState::default();
    input.keysyms = keymap::Keysyms::from_keymap(&keymap);
    input.pencil.tablet = tablet;

    let handle = event_loop.handle();
    let net = net::Net::listen(config.listen, &handle).map_err(|e| format!("listen on {}: {e}", config.listen))?;
    tracing::info!("listening on ws://{}", net.local);

    let (audio_tx, audio_rx) = channel::<audio::Packet>();
    handle
        .insert_source(audio_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(packet) = event {
                state.on_audio_packet(packet);
            }
        })
        .map_err(|e| e.to_string())?;
    let (devices_tx, devices_rx) = channel::<caboose_display_protocol::Message>();
    handle
        .insert_source(devices_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(message) = event {
                state.on_device_message(message);
            }
        })
        .map_err(|e| e.to_string())?;
    let (clip_tx, clip_rx) = channel::<Vec<u8>>();
    handle
        .insert_source(clip_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(data) = event {
                state.clipboard_read(data);
            }
        })
        .map_err(|e| e.to_string())?;
    let (done_tx, done_rx) = channel();
    handle
        .insert_source(done_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(done) = event {
                state.on_encoded(done);
            }
        })
        .map_err(|e| e.to_string())?;
    handle
        .insert_source(Timer::from_duration(Duration::from_secs(1)), |_, _, state: &mut State| {
            state.slow_tick();
            TimeoutAction::ToDuration(Duration::from_secs(1))
        })
        .map_err(|e| e.to_string())?;

    let socket =
        ListeningSocketSource::with_name(&config.socket).map_err(|e| format!("socket {}: {e}", config.socket))?;
    handle
        .insert_source(socket, |stream, _, state: &mut State| {
            if let Err(e) = state.dh.insert_client(stream, Arc::new(ClientState::default())) {
                tracing::warn!("cannot add a Wayland client: {e}");
            }
        })
        .map_err(|e| e.to_string())?;
    handle
        .insert_source(Generic::new(display, Interest::READ, Mode::Level), |_, display, state: &mut State| {
            // SAFETY: the display is not dropped while the loop runs.
            unsafe {
                display.get_mut().dispatch_clients(state).map_err(std::io::Error::other)?;
            }
            Ok(PostAction::Continue)
        })
        .map_err(|e| e.to_string())?;

    let spec = &config.display;
    let mut displays = displays::Displays::default();
    displays.replace(
        &dh,
        &[caboose_display_protocol::Display {
            id: 0,
            width: spec.width,
            height: spec.height,
            scale: spec.scale,
            refresh_hz: spec.refresh_hz,
            hdr: false,
        }],
    );

    let x_display = config.x_display;
    let mut state = State {
        dh: dh.clone(),
        handle: handle.clone(),
        signal: event_loop.get_signal(),
        clock: Clock::new(),
        config,
        compositor,
        xdg_shell,
        kde_decoration,
        shm,
        dmabuf,
        seat_state,
        data_device,
        primary_selection,
        xwayland_shell,
        seat,
        xwm: None,
        x11_foreground: None,
        text_inputs,
        windows: Default::default(),
        displays,
        renderer,
        encoders,
        net,
        session: None,
        done_tx,
        input,
        focus_history: Vec::new(),
        videos: Default::default(),
        games: Default::default(),
        control: Default::default(),
        clipboard: clipboard::Clipboard { done: clip_tx, last_sent: None },
        audio: None,
        audio_tx,
        devices: None,
        devices_tx,
        generation: 0,
        epoch: session::new_epoch(),
        stats: Default::default(),
        cursor: None,
        refine_timer: None,
    };

    if state.config.audio {
        let runtime_dir = std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
        state.audio = audio::Audio::start(&state.config.instance_dir(&runtime_dir));
    }
    if state.config.devices {
        match std::env::var_os("XDG_RUNTIME_DIR").map(std::path::PathBuf::from) {
            Some(runtime_dir) => {
                let config = devices::Config {
                    pulse_server: state.audio.as_ref().map(|a| a.server_address()),
                    state_dir: state.config.instance_dir(&runtime_dir),
                    status_file: runtime_dir.join("caboose-devices.json"),
                };
                match devices::Hub::spawn(config, state.devices_tx.clone()) {
                    Ok(hub) => state.devices = Some(hub),
                    Err(e) => tracing::warn!("no phone devices: {e}"),
                }
            }
            None => tracing::info!("no phone devices: XDG_RUNTIME_DIR is not set"),
        }
    }
    match video::server::socket_path() {
        Some(path) => match video::server::Videos::listen(&path, &handle) {
            Ok(v) => {
                tracing::info!("video socket: {}", path.display());
                state.videos = v;
            }
            Err(e) => tracing::warn!("no video passthrough: cannot listen on {}: {e}", path.display()),
        },
        None => tracing::info!("no video passthrough: XDG_RUNTIME_DIR is not set"),
    }
    match game::socket_path().filter(|_| state.config.games) {
        Some(path) => match game::Games::listen(&path, &handle) {
            Ok(g) => {
                tracing::info!("game socket: {}", path.display());
                state.games = g;
            }
            Err(e) => tracing::warn!("no game handoff: cannot listen on {}: {e}", path.display()),
        },
        None => tracing::info!("no game handoff"),
    }
    let instance_dir = std::env::var_os("XDG_RUNTIME_DIR").map(|d| state.config.instance_dir(std::path::Path::new(&d)));
    if let Some(dir) = &instance_dir {
        let path = dir.join("control.sock");
        let ready = std::fs::create_dir_all(dir)
            .and_then(|_| {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            })
            .and_then(|_| control::Control::listen(&path, &handle));
        match ready {
            Ok(c) => {
                tracing::info!("control socket: {}", path.display());
                state.control = c;
            }
            Err(e) => tracing::warn!("no control socket: cannot listen on {}: {e}", path.display()),
        }
    }
    let spawned = x_display.and_then(|number| {
        // Xwayland's socket directory; systemd-tmpfiles makes it on a booted system.
        let dir = std::path::Path::new("/tmp/.X11-unix");
        if !dir.exists() {
            use std::os::unix::fs::PermissionsExt;
            if std::fs::create_dir(dir)
                .and_then(|_| std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o1777)))
                .is_err()
            {
                tracing::warn!("cannot create {}", dir.display());
            }
        }
        let prepared = match xauth::prepare(instance_dir.as_deref()?, number) {
            Ok(p) => p,
            Err(e) => {
                tracing::error!("cannot prepare X11 authorization: {e}; continuing without X11");
                return None;
            }
        };
        match XWayland::spawn(
            &dh,
            Some(number),
            prepared.env.clone(),
            true,
            std::process::Stdio::null(),
            std::process::Stdio::inherit(),
            |_| (),
        ) {
            Ok((x, client)) => Some((x, client, prepared.authority, prepared.cookie)),
            Err(e) => {
                tracing::error!("cannot start Xwayland on :{number}: {e}; continuing without X11");
                None
            }
        }
    });
    match spawned {
        Some((xwayland, client, authority, cookie)) => {
            handle
                .insert_source(xwayland, move |event, _, state: &mut State| match event {
                    XWaylandEvent::Ready { x11_socket, display_number } => {
                        match X11Wm::start_wm(state.handle.clone(), x11_socket, client.clone()) {
                            Ok(wm) => {
                                state.xwm = Some(wm);
                                if let Err(error) = x11_focus::Foreground::install(state, display_number, &cookie) {
                                    tracing::error!("X11 foreground initialization: {error}");
                                }
                                ready(state, Some(display_number), Some(&authority));
                            }
                            Err(e) => {
                                tracing::error!("X11 window manager: {e}");
                                ready(state, None, None);
                            }
                        }
                    }
                    XWaylandEvent::Error => {
                        tracing::error!("Xwayland failed to start; continuing without X11");
                        ready(state, None, None);
                    }
                })
                .map_err(|e| e.to_string())?;
        }
        None => ready(&mut state, None, None),
    }

    stop_on_signals(&handle)?;
    event_loop.run(None, &mut state, |state| state.tick()).map_err(|e| e.to_string())?;
    tracing::info!("exiting: {}", state.stats.summary());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(args: &[&str]) -> Config {
        match config::parse(args.iter().map(|s| s.to_string())).unwrap() {
            Parsed::Run(c) => *c,
            Parsed::Help => panic!("help"),
        }
    }

    fn get<'a>(env: &'a [(String, String)], key: &str) -> Option<&'a str> {
        env.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    #[test]
    fn applications_prefer_wayland_by_default() {
        let env = launch_env(&config(&[]), Some(110), None, None);
        assert_eq!(get(&env, "WAYLAND_DISPLAY"), Some("wayland-caboose-0"));
        assert_eq!(get(&env, "DISPLAY"), Some(":110"));
        assert_eq!(get(&env, "GDK_BACKEND"), Some("wayland,x11"));
    }

    #[test]
    fn each_instance_names_its_own_sockets() {
        let auth = std::path::Path::new("/run/user/1000/caboose-display/wayland-caboose-agent/Xauthority");
        let env = launch_env(
            &config(&["--socket", "wayland-caboose-agent", "--x-display", "101"]),
            Some(101),
            Some(auth),
            None,
        );
        assert_eq!(get(&env, "WAYLAND_DISPLAY"), Some("wayland-caboose-agent"));
        assert_eq!(get(&env, "DISPLAY"), Some(":101"));
        assert_eq!(get(&env, "XAUTHORITY"), auth.to_str());
    }
}
