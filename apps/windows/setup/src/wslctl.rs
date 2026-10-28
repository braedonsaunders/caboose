//! `wsl.exe`, for setup: whether WSL works, and importing, upgrading, querying and removing
//! the Caboose distribution.

use caboose_win_core::process::{run, run_checked, system32, Output};
use caboose_win_core::status::{parse_ready, WslReady};
use caboose_win_core::winver::{parse_wsl_version, Version};
use caboose_win_core::wsl::{exec_as_root, has_distribution, status_needs_install, to_linux_path};
use caboose_win_core::DISTRO;
use std::path::{Path, PathBuf};

pub fn wsl() -> PathBuf {
    system32("wsl.exe")
}

/// Whether WSL is installed and can run WSL 2 distributions.
pub fn works() -> bool {
    match run(wsl(), &["--status"]) {
        Ok(output) => !status_needs_install(output.code, &format!("{}\n{}", output.stdout, output.stderr)),
        Err(_) => false,
    }
}

/// WSL's version, or `None` for the WSL built into Windows, which predates `--version`.
pub fn version() -> Option<Version> {
    run(wsl(), &["--version"]).ok().filter(Output::success).and_then(|output| parse_wsl_version(&output.stdout))
}

/// Whether the Caboose distribution is registered for this user.
pub fn installed() -> bool {
    // With no distributions at all, `--list` fails; that also means Caboose is not there.
    run(wsl(), &["--list", "--quiet"]).is_ok_and(|output| has_distribution(&output.stdout, DISTRO))
}

/// `wsl --import Caboose <directory> <rootfs> --version 2`.
pub fn import(directory: &Path, rootfs: &Path) -> Result<(), String> {
    std::fs::create_dir_all(directory).map_err(|error| format!("Could not create {}: {error}", directory.display()))?;
    let directory = directory.to_string_lossy();
    let rootfs = rootfs.to_string_lossy();
    run_checked(wsl(), &["--import", DISTRO, &directory, &rootfs, "--version", "2"]).map(|_| ())
}

/// Runs a program as root in the distribution (starting it if it is stopped).
pub fn exec_root(program: &str, arguments: &[&str]) -> Result<Output, String> {
    run_checked(wsl(), &exec_as_root(program, arguments))
}

/// Upgrades the distribution in place from a newer rootfs, with the `caboose-upgrade` that
/// the new rootfs carries (deploy/windows/distro/rootfs/usr/lib/caboose/caboose-upgrade).
/// Returns its report, such as `caboose-host v0.2.0 -> v0.3.0`.
pub fn upgrade(rootfs: &Path) -> Result<String, String> {
    let path = to_linux_path(&rootfs.to_string_lossy())
        .ok_or_else(|| format!("{} is not on a drive the distribution can read.", rootfs.display()))?;
    const SCRIPT: &str = r#"set -eu
work=$(mktemp -d /var/tmp/caboose-setup.XXXXXX)
trap 'rm -rf "$work"' EXIT
tar -xzf "$1" -C "$work" usr/lib/caboose/caboose-upgrade
"$work/usr/lib/caboose/caboose-upgrade" "$1""#;
    let output = exec_root("/bin/sh", &["-c", SCRIPT, "caboose-upgrade", &path])?;
    Ok(output.stdout.lines().last().unwrap_or("").trim().to_string())
}

/// The installed caboose-host version, from `/opt/caboose/current/VERSION`.
pub fn installed_version() -> Option<String> {
    exec_root("/bin/cat", &["/opt/caboose/current/VERSION"]).ok().map(|output| output.stdout.trim().to_string())
}

/// `caboose-wsl-ready`'s report.
pub fn ready() -> Result<WslReady, String> {
    let output = run(wsl(), &exec_as_root("/usr/local/bin/caboose-wsl-ready", &[]))
        .map_err(|error| format!("Could not run wsl.exe: {error}"))?;
    parse_ready(&output.stdout)
}

/// Starts caboose-host now and at every boot of the distribution.
pub fn enable_host() -> Result<(), String> {
    exec_root("/usr/bin/systemctl", &["enable", "--now", "docker.service", "caboose-host.service"]).map(|_| ())
}

/// Stops caboose-host and keeps it from starting with the distribution.
pub fn disable_host() -> Result<(), String> {
    exec_root("/usr/bin/systemctl", &["disable", "--now", "caboose-host.service"]).map(|_| ())
}

pub fn terminate() {
    let _ = run(wsl(), &["--terminate", DISTRO]);
}

/// Stops every distribution and WSL's VM, so `.wslconfig` changes apply.
pub fn shutdown() -> Result<(), String> {
    run_checked(wsl(), &["--shutdown"]).map(|_| ())
}

/// Deletes the distribution and its disk.
pub fn unregister() -> Result<(), String> {
    run_checked(wsl(), &["--unregister", DISTRO]).map(|_| ())
}
