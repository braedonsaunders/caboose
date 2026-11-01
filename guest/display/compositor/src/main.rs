//! caboose-display: Caboose's headless Wayland compositor. See docs/display.md.

mod audio;
mod devices;
mod clipboard;
mod config;
mod control;
mod dbus;
mod displays;
mod dnd;
mod frame_trace;
mod game;
#[allow(dead_code)] // Private live GPU remains disabled until its bridge is validated.
mod gpu_supervisor;
#[allow(dead_code)] // Grant handling remains disabled until CGB IPC is connected.
mod gpu_grant;
#[allow(dead_code)] // Control handling is unavailable until the private bridge is connected.
mod gpu_control;
mod gpu_peer;
mod gpu_x11;
mod icons;
mod ibus;
mod ibus_portal;
mod input;
mod keymap;
mod launch;
mod net;
mod pencil;
mod picture;
mod pipes;
mod present;
mod remote_buffers;
mod render;
mod render_node;
mod session;
mod state;
mod targets;
mod text_input;
mod transfers;
mod upload;
mod windows;
mod x11_focus;
mod x11_identity;
mod x11sel;
mod xauth;
mod xdnd;
mod x11_scale;
mod xwm;

use config::{Config, Parsed};
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
use smithay::wayland::dmabuf::{DmabufFeedbackBuilder, DmabufState};
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
    ("OZONE_PLATFORM", "wayland"),
    ("CHROMIUM_USER_FLAGS", "--ozone-platform-hint=auto"),
];

fn main() {
    xauth::shim_if_invoked();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("CABOOSE_DISPLAY_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,smithay=warn")),
        )
        .with_writer(std::io::stderr)
        .init();
    let config = match config::parse(std::env::args().skip(1)) {
        Ok(Parsed::Run(c)) => *c,
        Ok(Parsed::Help) => {
            print!("{}", config::USAGE);
            return;
        }
        Ok(Parsed::HostPads) => return exit_with("--host-pads", devices::serve_host_pads()),
        Ok(Parsed::PadLink) => return exit_with("--pad-link", devices::pad_link()),
        Err(e) => {
            eprintln!("caboose-display: {e}\n\n{}", config::USAGE);
            std::process::exit(2);
        }
    };
    // What applications inherit from the compositor's own environment, read before the
    // compositor sets up its own GPU stack.
    let _ = INHERITED.set(
        PASSED_ENV.iter().filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v))).collect(),
    );
    let icd = std::path::Path::new(GPU_LIVE_ICD);
    render::configure_process(
        icd.is_file().then_some(icd),
        config.private_gpu_stream.as_deref(),
        config.private_gpu_surface.as_deref(),
    );
    if let Err(e) = run(config) {
        eprintln!("caboose-display: {e}");
        std::process::exit(1);
    }
}

fn exit_with(mode: &str, result: std::io::Result<()>) {
    if let Err(e) = result {
        eprintln!("caboose-display {mode}: {e}");
        std::process::exit(1);
    }
}

/// udev's control socket, there when udevd runs.
const UDEV_CONTROL: &str = "/run/udev/control";

/// The GPU selection the compositor was started with, passed on so applications render the
/// same way (Mesa's D3D12 driver on WSL, a VA-API driver choice).
const PASSED_ENV: &[&str] = &["GALLIUM_DRIVER", "MESA_D3D12_DEFAULT_ADAPTER_NAME", "LIBVA_DRIVER_NAME"];

/// [`PASSED_ENV`] as the compositor's environment had it at start.
static INHERITED: std::sync::OnceLock<Vec<(String, String)>> = std::sync::OnceLock::new();

/// Whether the Caboose VA-API driver is installed where libva looks.
fn va_driver_installed() -> bool {
    let dirs = std::env::var("LIBVA_DRIVERS_PATH").unwrap_or_else(|_| "/usr/lib/x86_64-linux-gnu/dri".into());
    dirs.split(':').any(|d| std::path::Path::new(d).join("caboose_drv_video.so").is_file())
}

fn launch_env(config: &Config, x_display: Option<u32>, xauthority: Option<&std::path::Path>) -> Vec<(String, String)> {
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
    // Without udev (a container computer), SDL finds gamepads by watching /dev/input, as
    // it does in Flatpak and pressure-vessel sandboxes (docs/devices.md).
    if !std::path::Path::new(UDEV_CONTROL).exists() {
        env.push(("SDL_JOYSTICK_DISABLE_UDEV".into(), "1".into()));
    }
    env.extend(INHERITED.get().cloned().unwrap_or_default());
    env
}

/// The Vulkan loader manifest of the phone's GPU driver (guest/gpu/gfxstream), as the
/// image installs it.
const GPU_LIVE_ICD: &str = "/usr/local/lib/caboose-gpu-live/icd.json";

/// Toolkit switches for the seat that renders on the phone's GPU (docs/gpu-live.md,
/// "Applications"). GTK 4 and Qt 6 Quick draw with Vulkan; Electron runs as an X11 client,
/// where its input methods and windows behave as Chromium's do. OpenGL reaches the phone
/// through Zink, which Mesa tries before llvmpipe when no other driver serves the display
/// (`LIBGL_KOPPER_DRI2`); it presents through the driver's X11 windows (Kopper) but, without a DRM
/// render node, not through Wayland: toolkits that draw with OpenGL (Qt 5 Quick, SDL games,
/// Firefox) run as X11 clients. The phone has no geometry shaders or transform feedback, so
/// Zink would offer only OpenGL 2.1; the version override offers what the computer's own
/// renderer offers when no phone is attached, and only those two features are missing.
const GPU_LIVE_TOOLKIT_ENV: &[(&str, &str)] = &[
    ("GSK_RENDERER", "vulkan"),
    ("QSG_RHI_BACKEND", "vulkan"),
    ("ELECTRON_OZONE_PLATFORM_HINT", "x11"),
    ("QT_QPA_PLATFORM", "xcb;wayland"),
    ("SDL_VIDEODRIVER", "x11,wayland"),
    ("MOZ_ENABLE_WAYLAND", "0"),
    ("LIBGL_KOPPER_DRI2", "1"),
    // EGL's software path takes no Zink unless named, and prefers Mesa D3D12 (WSL's
    // /dev/dxg) to it: named here, OpenGL always reaches the phone, or the routing layer's
    // presented CPU device when no phone is attached.
    ("GALLIUM_DRIVER", "zink"),
    ("MESA_GL_VERSION_OVERRIDE", "4.5COMPAT"),
    ("MESA_GLSL_VERSION_OVERRIDE", "450"),
];

/// Launch-environment entries the GPU seat drops (none beyond those it replaces).
const GPU_LIVE_REMOVED_ENV: &[&str] = &[];

/// On the seat that renders on the phone's GPU: every application's Vulkan loader also
/// loads the phone's driver, which reaches the phone through the broker's sockets; they
/// exist only while a phone's GPU is attached. Without one the driver fails its instance and the
/// loader keeps the computer's own drivers, so applications draw on the computer and
/// reach the phone as pictures.
fn apply_gpu_live(env: &mut Vec<(String, String)>, config: &Config, icd: &std::path::Path, va_installed: bool) {
    let (Some(stream), Some(surface)) = (&config.private_gpu_stream, &config.private_gpu_surface) else {
        return;
    };
    if !icd.is_file() {
        tracing::warn!("no GPU driver at {}; applications draw on the computer", icd.display());
        return;
    }
    // The toolkit settings replace the seat's defaults.
    env.retain(|(k, _)| !GPU_LIVE_TOOLKIT_ENV.iter().any(|(t, _)| t == k) && !GPU_LIVE_REMOVED_ENV.contains(&k.as_str()));
    // The driver for 32-bit applications, where installed, beside it: each process's loader
    // passes over the manifest whose library is of the other architecture.
    let mut drivers = icd.display().to_string();
    if let Some(icd32) = icd.parent().map(|d| d.join("i386").join("icd.json")).filter(|p| p.is_file()) {
        drivers = format!("{drivers}:{}", icd32.display());
    }
    env.push(("VK_ADD_DRIVER_FILES".into(), drivers));
    env.push(("CABOOSE_GFXSTREAM_SOCKET".into(), stream.display().to_string()));
    env.push(("CABOOSE_GFXSTREAM_SURFACE_SOCKET".into(), surface.display().to_string()));
    // Steam's container runtime (pressure-vessel) shares only the paths it is told to.
    if let Some(dir) = stream.parent() {
        env.push(("PRESSURE_VESSEL_FILESYSTEMS_RW".into(), dir.display().to_string()));
    }
    // The executor-switch layer (guest/gpu/executor-switch): devices made on the computer's
    // CPU while no phone was attached are lost once one is, so applications move to it.
    env.push(("CABOOSE_GPU_EXECUTOR_SWITCH".into(), "1".into()));
    // The routing layer (guest/gpu/routing-layer) lists the phone's GPU first, in place of
    // Mesa's device-select layer, which orders by the computer's own GPUs, and settles
    // each process's device-loss policy: whether the driver reports the phone's departure
    // as device loss (applications that recover from it) or pauses the application.
    env.push(("CABOOSE_GPU_ROUTING".into(), "1".into()));
    env.push(("NODEVICE_SELECT".into(), "1".into()));
    env.push(("CABOOSE_GPU_ON_LOSS".into(), "auto".into()));
    env.extend(GPU_LIVE_TOOLKIT_ENV.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    // Video decodes on the phone through the Caboose VA-API driver (docs/gpu-media.md),
    // which reaches the phone through the broker's socket named above.
    if va_installed {
        env.retain(|(k, _)| k != "LIBVA_DRIVER_NAME" && k != "GST_VA_ALL_DRIVERS");
        env.push(("LIBVA_DRIVER_NAME".into(), "caboose".into()));
        env.push(("GST_VA_ALL_DRIVERS".into(), "1".into()));
    }
}

/// Once the compositor (and Xwayland) are up: the env file for launchers, and the
/// command to run, if any.
fn ready(state: &mut State, x_display: Option<u32>, xauthority: Option<&std::path::Path>) {
    let mut env = launch_env(&state.config, x_display, xauthority);
    apply_gpu_live(&mut env, &state.config, std::path::Path::new(GPU_LIVE_ICD), va_driver_installed());
    if let Some(audio) = &state.audio {
        // Applications play into the compositor's PulseAudio, whose sound goes to the phone.
        env.push(("PULSE_SERVER".into(), audio.server_address()));
    }
    if let Some(socket) = &state.games.socket {
        // Game handoff: caboose-game-run finds the compositor here (game.rs).
        env.push(("CABOOSE_GAME_SOCKET".into(), socket.display().to_string()));
    }
    if let Some(ibus) = &state.ibus {
        // Applications without text-input-v3 reach the phone's keyboard through IBus:
        // Qt by its module setting, GTK on X11 by the window manager's XSETTINGS, SDL by itself.
        env.push(("IBUS_ADDRESS".into(), ibus.address()));
        env.push(("IBUS_ADDRESS_FILE".into(), ibus.address_file().display().to_string()));
        env.push(("QT_IM_MODULE".into(), "ibus".into()));
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
    // The touch-target provider runs with the same environment, while a client wants it.
    state.targets.env = env.clone();
    if let Some((program, args)) = state.config.command.split_first() {
        let mut command = std::process::Command::new(program);
        // The compositor's own GPU settings stay its own.
        for key in render::OWN_ENV {
            command.env_remove(key);
        }
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
    config.validate_private_gpu_seat(std::env::var_os("CABOOSE_SEAT").as_deref() == Some(std::ffi::OsStr::new("agent")))?;
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        return Err("XDG_RUNTIME_DIR is not set".into());
    }

    let mut event_loop: EventLoop<'static, State> = EventLoop::try_new().map_err(|e| e.to_string())?;
    let display: Display<State> = Display::new().map_err(|e| e.to_string())?;
    let dh = display.handle();

    let render_node = render_node::find();
    // The first renderer: on the computer's device until a phone executor is ready.
    let gpu = match render::Gpu::new(render_node.as_ref().map(|(_, path)| path.as_path())) {
        Ok(gpu) => {
            tracing::info!("renderer 1: {}", gpu.name);
            Some(gpu)
        }
        Err(e) => {
            tracing::error!("no renderer: {e}");
            None
        }
    };

    let compositor = CompositorState::new::<State>(&dh);
    let xdg_shell = XdgShellState::new::<State>(&dh);
    let shm = ShmState::new::<State>(&dh, vec![]);
    let mut dmabuf = DmabufState::new();
    // linux-dmabuf: the renderer imports what its device can sample, so clients that
    // allocate GPU buffers hand them over without a copy into shm.
    let mut formats: Vec<_> = gpu.as_ref().map(|g| g.dmabuf_formats()).unwrap_or_default();
    // With the phone GPU, clients may also hand over buffers whose pixels are on the phone.
    if config.private_gpu_stream.is_some() {
        formats.extend(remote_buffers::formats());
    }
    if !formats.is_empty() {
        // With a render node, its dma-buf feedback names it as the device to allocate on.
        let feedback = render_node.clone().and_then(|(device, path)| {
            match DmabufFeedbackBuilder::new(device, formats.iter().copied()).build() {
                Ok(feedback) => {
                    tracing::info!("render node: {}", path.display());
                    Some(feedback)
                }
                Err(e) => {
                    tracing::warn!("render node {}: no dma-buf feedback: {e}", path.display());
                    None
                }
            }
        });
        match feedback {
            Some(feedback) => { dmabuf.create_global_with_default_feedback::<State>(&dh, &feedback); }
            None => { dmabuf.create_global::<State>(&dh, formats); }
        }
    }
    OutputManagerState::new_with_xdg_output::<State>(&dh);
    XdgDecorationState::new::<State>(&dh);
    // GTK 3 uses this legacy protocol, not xdg-decoration, for ordinary windows.
    let kde_decoration = KdeDecorationState::new::<State>(&dh, KdeDecorationMode::Server);
    ViewporterState::new::<State>(&dh);
    FractionalScaleManagerState::new::<State>(&dh);
    CursorShapeManagerState::new::<State>(&dh);
    smithay::wayland::xdg_toplevel_icon::XdgToplevelIconManager::new::<State>(&dh).add_icon_size(128);
    smithay::wayland::relative_pointer::RelativePointerManagerState::new::<State>(&dh);
    // Games lock the pointer and read relative motion for mouse look (input.rs).
    smithay::wayland::pointer_constraints::PointerConstraintsState::new::<State>(&dh);
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
    let (clip_tx, clip_rx) = channel::<clipboard::Read>();
    handle
        .insert_source(clip_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(read) = event {
                state.clipboard_read(read);
            }
        })
        .map_err(|e| e.to_string())?;
    let (xdnd_tx, xdnd_rx) = channel::<(u64, xdnd::Report)>();
    handle
        .insert_source(xdnd_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg((serial, report)) = event {
                state.on_xdnd_report(serial, report);
            }
        })
        .map_err(|e| e.to_string())?;
    let (drag_tx, drag_rx) = channel::<clipboard::Read>();
    handle
        .insert_source(drag_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(read) = event {
                state.on_drag_read(read);
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
            let gpu_peer = if state.net.gpu_enabled() { gpu_peer::GpuPeer::capture(&stream).ok() } else { None };
            let client = ClientState { gpu_peer, ..ClientState::default() };
            if let Err(e) = state.dh.insert_client(stream, Arc::new(client)) {
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
        xwayland_client: None,
        x11_scale: 1.0,
        x11_foreground: None,
        gpu_x11: None,
        gpu_bind_larger: false,
        x11_identity: None,
        ibus: None,
        ibus_shown: None,
        text_inputs,
        windows: Default::default(),
        displays,
        gpu,
        gpu_generation: 1,
        next_canvas: 0,
        render_node: render_node.map(|(_, path)| path),
        net,
        session: None,
        input,
        focus_history: Vec::new(),
        games: Default::default(),
        control: Default::default(),
        targets: Default::default(),
        clipboard: clipboard::Clipboard::new(clip_tx),
        x11: None,
        dnd: dnd::Dnd::new(xdnd_tx, drag_tx),
        audio: None,
        audio_tx,
        devices: None,
        devices_tx,
        generation: 0,
        epoch: session::new_epoch(),
        gpu_grants: None,
        gpu_restart_pending: false,
        gpu_restart_delay: Duration::from_secs(1),
        gpu_started_at: std::time::Instant::now(),
        remote_presents: Default::default(),
        stats: Default::default(),
        input_trace: Default::default(),
        cursor: None,
    };

    if let (Some(stream), Some(surface)) = (&state.config.private_gpu_stream, &state.config.private_gpu_surface) {
        let grants = gpu_grant::Grants::new().map_err(|e| format!("private GPU entropy: {e}"))?;
        let token = state.config.token_file.as_ref().ok_or("private GPU requires authentication")?;
        state.net.enable_private_gpu(token, stream, surface, state.config.private_gpu_indexed, &handle)
            .map_err(|e| format!("private GPU supervisor: {e}"))?;
        state.gpu_grants = Some(grants);
    }

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
                    pads_socket: devices::pads_socket(&runtime_dir),
                };
                match devices::Hub::spawn(config, state.devices_tx.clone()) {
                    Ok(hub) => state.devices = Some(hub),
                    Err(e) => tracing::warn!("no phone devices: {e}"),
                }
            }
            None => tracing::info!("no phone devices: XDG_RUNTIME_DIR is not set"),
        }
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
        let path = dir.join("ibus");
        match ibus::Ibus::listen(&path, &handle) {
            Ok(service) => {
                // Sandboxed applications reach it through the session bus.
                if let Ok(address) = std::env::var("DBUS_SESSION_BUS_ADDRESS") {
                    if let Err(e) = ibus::Ibus::serve_portal(address, &handle) {
                        tracing::warn!("input method: no IBus portal: {e}");
                    }
                }
                state.ibus = Some(service);
            }
            Err(e) => tracing::warn!("no input-method service: cannot listen on {}: {e}", path.display()),
        }
    }
    // On the seat that renders on the phone's GPU, Xwayland's DRI3 opens the render node
    // (guest/xwayland): X11 clients such as Chromium get their GBM device from it.
    let dri3_node = state.config.private_gpu_stream.as_ref().and_then(|_| state.render_node.clone());
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
        let mut env = prepared.env.clone();
        if let Some(node) = &dri3_node {
            env.push(("CABOOSE_XWAYLAND_RENDER_NODE".into(), node.clone().into_os_string()));
        }
        match XWayland::spawn(
            &dh,
            Some(number),
            env,
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
                            Ok(mut wm) => {
                                // GTK on X11 (and Chromium and Electron, which use its input
                                // methods) selects its input-method module from XSETTINGS,
                                // which Wayland clients do not read: X11 clients reach the
                                // IBus service (ibus.rs), Wayland clients keep text-input-v3.
                                let settings = [("Gtk/IMModule".to_owned(), "ibus".to_owned().into())];
                                if let Err(error) = wm.set_xsettings(settings.into_iter()) {
                                    tracing::warn!("XSETTINGS for X11 clients: {error}");
                                }
                                state.xwm = Some(wm);
                                state.xwayland_client = Some(client.clone());
                                state.apply_x11_scale();
                                if let Err(error) = x11_focus::Foreground::install(state, display_number, &cookie) {
                                    tracing::error!("X11 foreground initialization: {error}");
                                }
                                if let Err(error) = x11_identity::X11Identity::install(state, display_number, &cookie) {
                                    tracing::error!("X11 window icons and processes unavailable: {error}");
                                }
                                state.x11 = Some(x11sel::Access { display: display_number, cookie });
                                input::xwayland::set_pixel_distance(
                                    x11sel::Access { display: display_number, cookie },
                                    state.x11_scale,
                                );
                                if state.gpu_grants.is_some() {
                                    match gpu_x11::X11Windows::connect(display_number, &cookie) {
                                        Ok(windows) => state.gpu_x11 = Some(windows),
                                        Err(error) => tracing::error!("GPU X11 window lookup unavailable: {error}"),
                                    }
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
            _ => panic!("not a run"),
        }
    }

    fn get<'a>(env: &'a [(String, String)], key: &str) -> Option<&'a str> {
        env.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    #[test]
    fn applications_prefer_wayland_by_default() {
        let env = launch_env(&config(&[]), Some(110), None);
        assert_eq!(get(&env, "WAYLAND_DISPLAY"), Some("wayland-caboose-0"));
        assert_eq!(get(&env, "DISPLAY"), Some(":110"));
        assert_eq!(get(&env, "GDK_BACKEND"), Some("wayland,x11"));
        assert_eq!(get(&env, "OZONE_PLATFORM"), Some("wayland"));
        assert_eq!(get(&env, "CHROMIUM_USER_FLAGS"), Some("--ozone-platform-hint=auto"));
    }

    #[test]
    fn each_instance_names_its_own_sockets() {
        let auth = std::path::Path::new("/run/user/1000/caboose-display/wayland-caboose-agent/Xauthority");
        let env = launch_env(
            &config(&["--socket", "wayland-caboose-agent", "--x-display", "101", "--no-games"]),
            Some(101),
            Some(auth),
        );
        assert_eq!(get(&env, "WAYLAND_DISPLAY"), Some("wayland-caboose-agent"));
        assert_eq!(get(&env, "DISPLAY"), Some(":101"));
        assert_eq!(get(&env, "XAUTHORITY"), auth.to_str());
    }

    const GPU_ARGS: &[&str] = &[
        "--token-file",
        "/run/caboose/display-token",
        "--private-gpu-stream-socket",
        "/run/user/1000/caboose-gpu/gpu.sock",
        "--private-gpu-surface-socket",
        "/run/user/1000/caboose-gpu/surface.sock",
        "--private-gpu-indexed",
    ];

    #[test]
    fn the_gpu_seat_routes_vulkan_and_opengl_to_the_phone() {
        let icd = tempfile_icd();
        let mut env = vec![
            ("GALLIUM_DRIVER".to_owned(), "d3d12".to_owned()),
            ("ELECTRON_OZONE_PLATFORM_HINT".to_owned(), "auto".to_owned()),
        ];
        apply_gpu_live(&mut env, &config(GPU_ARGS), &icd, false);
        assert_eq!(env.iter().filter(|(k, _)| k == "ELECTRON_OZONE_PLATFORM_HINT").count(), 1);
        assert_eq!(get(&env, "VK_ADD_DRIVER_FILES"), icd.to_str());
        assert_eq!(get(&env, "CABOOSE_GFXSTREAM_SOCKET"), Some("/run/user/1000/caboose-gpu/gpu.sock"));
        assert_eq!(get(&env, "CABOOSE_GFXSTREAM_SURFACE_SOCKET"), Some("/run/user/1000/caboose-gpu/surface.sock"));
        assert_eq!(get(&env, "LIBGL_KOPPER_DRI2"), Some("1"));
        // Forcing Zink would leave OpenGL without a renderer when no phone is attached.
        assert_eq!(get(&env, "MESA_LOADER_DRIVER_OVERRIDE"), None);
        assert_eq!(get(&env, "MESA_GL_VERSION_OVERRIDE"), Some("4.5COMPAT"));
        assert_eq!(get(&env, "QT_QPA_PLATFORM"), Some("xcb;wayland"));
        assert_eq!(get(&env, "SDL_VIDEODRIVER"), Some("x11,wayland"));
        assert_eq!(get(&env, "MOZ_ENABLE_WAYLAND"), Some("0"));
        assert_eq!(get(&env, "GSK_RENDERER"), Some("vulkan"));
        assert_eq!(get(&env, "QSG_RHI_BACKEND"), Some("vulkan"));
        assert_eq!(get(&env, "CABOOSE_GPU_EXECUTOR_SWITCH"), Some("1"));
        assert_eq!(get(&env, "CABOOSE_GPU_ROUTING"), Some("1"));
        assert_eq!(get(&env, "NODEVICE_SELECT"), Some("1"));
        assert_eq!(get(&env, "CABOOSE_GPU_ON_LOSS"), Some("auto"));
        assert_eq!(get(&env, "ELECTRON_OZONE_PLATFORM_HINT"), Some("x11"));
        assert_eq!(get(&env, "PRESSURE_VESSEL_FILESYSTEMS_RW"), Some("/run/user/1000/caboose-gpu"));
        assert_eq!(get(&env, "GALLIUM_DRIVER"), Some("zink"), "OpenGL goes through Zink, never Mesa D3D12");
        assert_eq!(get(&env, "LIBVA_DRIVER_NAME"), None, "no VA-API driver installed");
        let mut env = vec![("LIBVA_DRIVER_NAME".to_owned(), "d3d12".to_owned())];
        apply_gpu_live(&mut env, &config(GPU_ARGS), &icd, true);
        assert_eq!(env.iter().filter(|(k, _)| k == "LIBVA_DRIVER_NAME").count(), 1);
        assert_eq!(get(&env, "LIBVA_DRIVER_NAME"), Some("caboose"), "video decodes on the phone");
        assert_eq!(get(&env, "GST_VA_ALL_DRIVERS"), Some("1"));
        std::fs::remove_file(&icd).unwrap();
    }

    #[test]
    fn other_seats_and_missing_drivers_keep_the_computers_gpu() {
        let icd = tempfile_icd();
        let before = vec![("GALLIUM_DRIVER".to_owned(), "d3d12".to_owned())];
        let mut env = before.clone();
        apply_gpu_live(&mut env, &config(&[]), &icd, true);
        assert_eq!(env, before);
        apply_gpu_live(&mut env, &config(GPU_ARGS), std::path::Path::new("/nonexistent/icd.json"), true);
        assert_eq!(env, before);
        std::fs::remove_file(&icd).unwrap();
    }

    #[test]
    fn the_gpu_seat_also_names_the_driver_for_32_bit_applications() {
        let dir = std::env::temp_dir().join(format!("caboose-icd32-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("i386")).unwrap();
        let icd = dir.join("icd.json");
        std::fs::write(&icd, "{}").unwrap();
        let mut env = Vec::new();
        apply_gpu_live(&mut env, &config(GPU_ARGS), &icd, false);
        assert_eq!(get(&env, "VK_ADD_DRIVER_FILES"), icd.to_str(), "only drivers that are installed");
        std::fs::write(dir.join("i386/icd.json"), "{}").unwrap();
        let mut env = Vec::new();
        apply_gpu_live(&mut env, &config(GPU_ARGS), &icd, false);
        let expected = format!("{}:{}", icd.display(), dir.join("i386/icd.json").display());
        assert_eq!(get(&env, "VK_ADD_DRIVER_FILES"), Some(expected.as_str()));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn tempfile_icd() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "caboose-icd-{}-{}.json",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&path, "{}").unwrap();
        path
    }
}
