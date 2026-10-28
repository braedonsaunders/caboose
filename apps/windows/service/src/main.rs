//! caboose-service.exe: keeps the Caboose WSL distribution running.
//!
//! ```text
//! caboose-service.exe [--home <%LOCALAPPDATA%\Caboose>]
//! ```
//!
//! The "Caboose" scheduled task starts it at boot as the user who installed Caboose, without
//! a sign-in (S4U). It runs `wsl.exe -d Caboose -u root --exec /usr/local/bin/caboose-keepalive`,
//! which blocks, so WSL keeps the distribution (and systemd, Docker and caboose-host in it)
//! running; when it exits, the service starts it again after a backoff of 1 s doubling to a
//! minute. With WSL's NAT networking it also keeps Windows' port 7310 forwarded to the
//! distribution's address, which changes when WSL restarts. It logs to `<home>\logs\service.log`
//! and reports its state in `<home>\service.json` for the tray.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod service;

#[cfg(windows)]
fn main() {
    std::process::exit(service::main());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("caboose-service keeps Caboose's WSL distribution running on Windows, and runs only there.");
    std::process::exit(1);
}
