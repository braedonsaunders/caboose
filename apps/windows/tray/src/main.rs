//! Notification-area entry point for opening the local Caboose console.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod windows_tray;

#[cfg(windows)]
fn main() {
    if let Err(error) = windows_tray::run() {
        eprintln!("Caboose tray: {error}");
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Caboose tray runs on Windows.");
}
