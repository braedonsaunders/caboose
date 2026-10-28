//! The logic behind Caboose on Windows, kept free of Windows APIs so it is unit-tested on any
//! machine: `.wslconfig` editing, Windows and WSL version checks, `netsh` port forwarding,
//! release selection and verification, the distribution's health reports, pairing links,
//! the boot task, and the install layout. `process` is the one piece that starts programs.

pub mod backoff;
pub mod firewall;
pub mod layout;
pub mod logfile;
pub mod pairing;
pub mod portproxy;
pub mod process;
pub mod release;
pub mod status;
pub mod task;
pub mod winver;
pub mod wsl;
pub mod wslconfig;

/// The WSL distribution Caboose installs and runs.
pub const DISTRO: &str = "Caboose";
/// The port caboose-host listens on, in the distribution and on Windows.
pub const PORT: u16 = 7310;
/// The GitHub repository whose releases carry the distribution.
pub const REPOSITORY: &str = "braedonsaunders/caboose";
/// The distribution's rootfs in a release, with `<name>.sha256` beside it.
pub const DISTRO_ASSET: &str = "caboose-wsl-amd64.tar.gz";
/// The scheduled task that keeps Caboose running.
pub const TASK_NAME: &str = "Caboose";
/// The window class of the tray, so setup can find it and ask it to close.
pub const TRAY_WINDOW_CLASS: &str = "CabooseTray";
