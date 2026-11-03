use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

static NEXT: AtomicU32 = AtomicU32::new(0);

/// A running `caboose-display` with its own runtime directory, Wayland socket and port.
pub struct Server {
    child: Child,
    pub runtime: PathBuf,
    pub socket: String,
    pub port: u16,
    pub x_display: Option<u32>,
    log: PathBuf,
}

pub fn docs_path(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs").join(name)
}

fn runtime_ready() -> Result<(), String> {
    // The compositor loads libEGL at start; without it nothing here can run.
    let egl = ["/usr/lib/x86_64-linux-gnu/libEGL.so.1", "/usr/lib/aarch64-linux-gnu/libEGL.so.1", "/usr/lib64/libEGL.so.1"];
    if !egl.iter().any(|p| Path::new(p).exists()) {
        return Err("libEGL.so.1 is not installed".into());
    }
    Ok(())
}

fn has_xwayland() -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join("Xwayland").is_file()))
}

impl Server {
    /// Starts the compositor, with Xwayland when `xwayland`. `None` (after saying why) when
    /// the machine lacks the runtime the compositor needs.
    pub fn start(xwayland: bool) -> Option<Server> {
        if let Err(why) = runtime_ready() {
            eprintln!("SKIPPED: {why}; run this test in the runtime image (guest/display/Dockerfile)");
            return None;
        }
        if xwayland && !has_xwayland() {
            eprintln!("SKIPPED: Xwayland is not installed; run this test in the runtime image");
            return None;
        }
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let runtime = std::env::temp_dir().join(format!("caboose-adv-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::set_permissions(&runtime, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
        let port = {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        let socket = format!("adv-{n}");
        let log = runtime.join("compositor.log");
        let x_display = xwayland.then_some(130 + (std::process::id() % 40) * 4 + n);
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_caboose-display"));
        cmd.args(["--no-auth", "--no-audio", "--no-games", "--no-devices", "--listen"])
            .arg(format!("127.0.0.1:{port}"))
            .args(["--socket", &socket, "--env-file"])
            .arg(runtime.join("env"));
        match x_display {
            Some(d) => cmd.args(["--x-display", &d.to_string()]),
            None => cmd.arg("--no-xwayland"),
        };
        cmd.env("XDG_RUNTIME_DIR", &runtime)
            .env("CABOOSE_DISPLAY_LOG", "caboose_display=debug,info")
            .env("HOME", &runtime)
            .env_remove("WAYLAND_DISPLAY")
            .env_remove("DISPLAY")
            .stdin(Stdio::null())
            .stdout(std::fs::File::create(&log).unwrap())
            .stderr(std::fs::File::create(&log).unwrap());
        if xwayland {
            // Xwayland's own log of the globals it was sent (see `wire_log`).
            cmd.env("WAYLAND_DEBUG", "1");
        }
        let child = cmd.spawn().expect("start caboose-display");
        let mut server = Server { child, runtime, socket, port, x_display, log };
        let deadline = Instant::now() + Duration::from_secs(40);
        while !server.runtime.join("env").exists() {
            if let Ok(Some(status)) = server.child.try_wait() {
                panic!("caboose-display exited: {status}\n{}", server.log_text());
            }
            assert!(Instant::now() < deadline, "caboose-display never became ready\n{}", server.log_text());
            std::thread::sleep(Duration::from_millis(50));
        }
        Some(server)
    }

    pub fn wayland_socket(&self) -> PathBuf {
        self.runtime.join(&self.socket)
    }

    pub fn log_text(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// The Wayland traffic the compositor logged under `WAYLAND_DEBUG` (Xwayland only).
    pub fn wire_log(&self) -> String {
        self.log_text()
    }

    /// A value from the application environment file (`NAME='value'`).
    pub fn env_value(&self, name: &str) -> Option<String> {
        let env = std::fs::read_to_string(self.runtime.join("env")).ok()?;
        env.lines().find_map(|l| {
            let l = l.strip_prefix("export ").unwrap_or(l);
            let rest = l.strip_prefix(name)?.strip_prefix('=')?;
            Some(rest.trim_matches('\'').trim_matches('"').to_owned())
        })
    }

    pub fn x_socket_exists(&self) -> bool {
        self.x_display.is_some_and(|d| Path::new(&format!("/tmp/.X11-unix/X{d}")).exists())
    }

    pub fn pulse_socket_exists(&self) -> bool {
        self.env_value("PULSE_SERVER")
            .map(|s| s.trim_start_matches("unix:").to_owned())
            .is_some_and(|p| Path::new(&p).exists())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // SAFETY: SIGTERM to our own child, which the compositor handles as a clean stop.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.child.try_wait().ok().flatten().is_none() {
            if Instant::now() > deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = std::fs::remove_dir_all(&self.runtime);
    }
}
