//! Installing Caboose, and upgrading or repairing an install when setup runs again.
//!
//! 1. Checks the PC: x64, Windows 10 22H2 or later, virtualization on.
//! 2. Installs WSL if it is missing (elevated), and if Windows must restart for it, schedules
//!    setup to continue at the next sign-in. Updates a WSL too old for mirrored networking.
//! 3. On the first install, offers mirrored networking (`.wslconfig`), which applies to all of
//!    the user's WSL distributions.
//! 4. Downloads and verifies the distribution, then imports it as "Caboose", or upgrades the
//!    existing one in place with the new rootfs's `caboose-upgrade`, which keeps /var/lib.
//! 5. Puts the service, tray and icon in `%LOCALAPPDATA%\Caboose\bin`, and (elevated) adds the
//!    firewall rules and the "Caboose" startup task and starts it.
//! 6. Adds the Start menu shortcut, the tray's sign-in start and the uninstaller, waits for
//!    caboose-host to answer, and starts the tray.

use crate::{download, elevated, embedded, shell, ui, wslctl, Options};
use caboose_win_core::firewall::{any_public_network, NETWORK_CATEGORIES_SCRIPT};
use caboose_win_core::layout::{InstallConfig, Layout, SERVICE_EXE, TRAY_EXE};
use caboose_win_core::logfile::Log;
use caboose_win_core::pairing::{address_urls, phone_addresses, primary_ipv4, Interface};
use caboose_win_core::process::powershell;
use caboose_win_core::status::{console_entry, local_url, Networking, WslReady};
use caboose_win_core::winver::WSL_MIRRORED;
use caboose_win_core::wslconfig::{self, MIRRORED, NETWORKING_MODE, SECTION};
use caboose_win_core::PORT;
use std::path::PathBuf;
use std::time::{Duration, Instant};

const ICON_BYTES: &[u8] = include_bytes!("../../assets/caboose.ico");
/// How long caboose-host may take to answer after the distribution starts.
const START_TIMEOUT: Duration = Duration::from_secs(300);

enum Outcome {
    Installed,
    RestartNeeded,
    Cancelled,
}

pub fn run(options: &Options) -> i32 {
    ui::set_unattended(options.yes);
    let layout = match shell::layout() {
        Ok(layout) => layout,
        Err(error) => {
            ui::error("Caboose could not be installed", &error);
            return 1;
        }
    };
    let log = Log::new(layout.logs(), "setup");
    log.line(format!("CabooseSetup {} installing ({options:?})", env!("CARGO_PKG_VERSION")));
    match install(options, &layout, &log) {
        Ok(Outcome::Installed) => 0,
        // ERROR_SUCCESS_REBOOT_REQUIRED and ERROR_INSTALL_USEREXIT, as installers report them.
        Ok(Outcome::RestartNeeded) => 3010,
        Ok(Outcome::Cancelled) => {
            log.line("cancelled");
            1602
        }
        Err(error) => {
            log.line(format!("failed: {error}"));
            ui::error(
                "Caboose could not be installed",
                &format!("{error}\n\nSetup's log is {}.", log.path().display()),
            );
            1
        }
    }
}

fn install(options: &Options, layout: &Layout, log: &Log) -> Result<Outcome, String> {
    if !shell::is_x64() {
        return Err("Caboose needs a PC with an x64 (Intel or AMD) processor.".to_string());
    }
    let build = shell::windows_build()?;
    log.line(format!("{build}"));
    if !build.is_supported() {
        return Err(format!("Caboose needs Windows 10 22H2 or Windows 11, and this PC runs {build}. Update Windows, then run setup again."));
    }
    if !shell::virtualization_enabled() {
        return Err("Virtualization is turned off in this PC's firmware, and WSL needs it. Restart into the UEFI (BIOS) settings, turn on Intel VT-x or AMD-V (SVM), then run setup again.".to_string());
    }

    let existing = std::fs::read_to_string(layout.config()).ok().and_then(|text| match InstallConfig::parse(&text) {
        Ok(config) => Some(config),
        Err(error) => {
            log.line(format!("ignoring {}: {error}", layout.config().display()));
            None
        }
    });
    if !options.resume {
        let (main, content, button) = match &existing {
            None => (
                "Install Caboose on this PC?",
                "Caboose runs your phone's Linux computer here, in its own WSL distribution with Docker and your GPU. It starts with Windows, even before anyone signs in, and your iPhone reaches it on your local network on port 7310.\n\nSetup downloads about 250 MB and asks for administrator permission to set up the firewall and the startup task.",
                "Install",
            ),
            Some(_) => (
                "Update Caboose?",
                "Setup installs the newest Caboose and repairs its startup task, firewall rules and shortcuts. Your computers, their files and Caboose's settings are kept.",
                "Update",
            ),
        };
        if !ui::ask(main, content, button, "Cancel", true) {
            return Ok(Outcome::Cancelled);
        }
    }
    shell::install_self(layout)?;
    let home = layout.root.to_string_lossy().into_owned();

    // WSL itself.
    if !wslctl::works() {
        log.line("WSL is missing");
        if !ui::ask(
            "Caboose needs the Windows Subsystem for Linux",
            "Caboose runs in WSL, which is not set up on this PC. Setup installs it now; this needs administrator permission and usually a restart of Windows. Setup continues by itself after you sign in again.",
            "Install WSL",
            "Cancel",
            true,
        ) {
            return Ok(Outcome::Cancelled);
        }
        let step = layout.clone();
        let home = home.clone();
        ui::progress("Installing WSL", "Installing the Windows Subsystem for Linux…", false, move |progress| {
            elevated::run_elevated(&step, &["install-wsl", "--home", &home], Some(progress))
        })?;
        if !wslctl::works() {
            shell::set_resume(layout)?;
            log.line("WSL needs a restart; setup resumes at the next sign-in");
            if ui::ask(
                "Restart Windows to finish installing WSL",
                "WSL is installed and starts working after Windows restarts. Caboose Setup continues by itself when you sign in again.",
                "Restart now",
                "Restart later",
                false,
            ) {
                let shutdown = caboose_win_core::process::system32("shutdown.exe");
                caboose_win_core::process::run_checked(shutdown, &["/r", "/t", "5", "/c", "Restarting to finish installing WSL for Caboose."])?;
            }
            return Ok(Outcome::RestartNeeded);
        }
    }
    let mut wsl_version = wslctl::version();
    if wsl_version.is_none_or(|version| version < WSL_MIRRORED) {
        log.line(format!("updating WSL ({wsl_version:?})"));
        let step = layout.clone();
        let home = home.clone();
        ui::progress("Updating WSL", "Updating the Windows Subsystem for Linux…", false, move |progress| {
            elevated::run_elevated(&step, &["update-wsl", "--home", &home], Some(progress))
        })?;
        wsl_version = wslctl::version();
    }
    log.line(format!("WSL {wsl_version:?}"));

    // Networking.
    let wslconfig_path = shell::wslconfig_path()?;
    let wslconfig_text = std::fs::read(&wslconfig_path).map(|bytes| wslconfig::decode(&bytes)).unwrap_or_default();
    let mut config = existing.clone().unwrap_or_default();
    let mut restart_wsl = false;
    if wslconfig::is_mirrored(&wslconfig_text) {
        config.networking = Networking::Mirrored;
    } else if existing.is_none()
        && build.supports_mirrored()
        && wsl_version.is_some_and(|version| version >= WSL_MIRRORED)
    {
        if ui::ask(
            "Let WSL share Windows' network?",
            "With mirrored networking, Caboose listens on this PC's own addresses, so your iPhone reaches it directly and nothing has to forward the port. This is recommended.\n\nIt is a WSL setting (in .wslconfig) that applies to all of your WSL distributions, and setup restarts WSL to apply it, stopping any distribution that is running now.",
            "Use mirrored networking",
            "Keep WSL's networking as it is",
            true,
        ) {
            if wslconfig_path.exists() {
                let backup = wslconfig_path.with_extension("wslconfig.caboose-backup");
                if !backup.exists() {
                    let _ = std::fs::copy(&wslconfig_path, &backup);
                }
            }
            let updated = wslconfig::set(&wslconfig_text, SECTION, NETWORKING_MODE, Some(MIRRORED));
            std::fs::write(&wslconfig_path, updated).map_err(|error| format!("Could not write {}: {error}", wslconfig_path.display()))?;
            config.changed_wslconfig = true;
            config.previous_networking_mode = wslconfig::get(&wslconfig_text, SECTION, NETWORKING_MODE);
            config.networking = Networking::Mirrored;
            restart_wsl = true;
        } else {
            config.networking = Networking::Nat;
        }
    } else {
        config.networking = Networking::Nat;
    }
    log.line(format!("networking: {:?}", config.networking));
    if restart_wsl {
        ui::progress("Restarting WSL", "Restarting WSL with mirrored networking…", false, |_| wslctl::shutdown())?;
    }

    // The distribution.
    let installed = wslctl::installed();
    let (rootfs, version) = match &options.distro {
        Some(path) => {
            let path = PathBuf::from(path);
            let sha256 = options.sha256.clone();
            let label = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            let checked = ui::progress("Checking the distribution", "Checking the file…", false, move |progress| {
                download::local_distro(&path, sha256.as_deref(), progress)
            })?;
            (Some(checked), label)
        }
        None => {
            let tag = options.release.clone();
            let selected = ui::progress("Finding Caboose", "Looking for the newest release…", false, move |_| {
                download::choose_release(tag.as_deref())
            })?;
            let tag = selected.tag.as_str();
            let current = installed
                && (config.version.as_deref() == Some(tag) || wslctl::installed_version().as_deref() == Some(tag));
            if current {
                log.line(format!("{} is already installed", selected.tag));
                (None, selected.tag)
            } else {
                let downloads = layout.downloads();
                let tag = selected.tag.clone();
                let path = ui::progress(
                    "Downloading Caboose",
                    &format!("Downloading Caboose {tag}…"),
                    true,
                    move |progress| download::fetch_distro(&selected, &downloads, progress),
                )?;
                (Some(path), tag)
            }
        }
    };
    if let Some(rootfs) = &rootfs {
        let rootfs = rootfs.clone();
        if installed {
            let report = ui::progress(
                "Updating Caboose",
                "Updating the Caboose distribution; your computers and data stay…",
                false,
                move |_| wslctl::upgrade(&rootfs),
            )?;
            log.line(format!("upgraded: {report}"));
        } else {
            let directory = layout.wsl();
            ui::progress("Installing Caboose", "Importing the Caboose distribution into WSL…", false, move |_| {
                wslctl::import(&directory, &rootfs)
            })?;
            log.line(format!("imported {version}"));
        }
        config.version = Some(version.clone());
    }
    ui::progress("Starting Caboose", "Starting the Caboose distribution…", false, |_| wslctl::enable_host())?;

    // The programs, then the administrator steps that start the service.
    shell::close_tray();
    std::fs::create_dir_all(layout.bin())
        .map_err(|error| format!("Could not create {}: {error}", layout.bin().display()))?;
    shell::replace_file(&layout.service_exe(), &shell::program_bytes(SERVICE_EXE, embedded::SERVICE)?)?;
    shell::replace_file(&layout.tray_exe(), &shell::program_bytes(TRAY_EXE, embedded::TRAY)?)?;
    shell::replace_file(&layout.icon(), ICON_BYTES)?;
    std::fs::write(layout.config(), config.to_json())
        .map_err(|error| format!("Could not write {}: {error}", layout.config().display()))?;

    let (user, sid) = shell::current_user()?;
    log.line(format!("startup task for {user} ({sid})"));
    let networking = match config.networking {
        Networking::Mirrored => "mirrored",
        Networking::Nat => "nat",
    };
    let step = layout.clone();
    let home_for_step = home.clone();
    ui::progress(
        "Setting up startup",
        "Adding the firewall rules and the Caboose startup task…",
        false,
        move |progress| {
            elevated::run_elevated(
                &step,
                &["configure", "--sid", &sid, "--home", &home_for_step, "--networking", networking],
                Some(progress),
            )
        },
    )?;

    if existing.is_none() {
        shell::set_tray_autostart(layout)?;
    }
    shell::create_shortcut(layout)?;
    shell::register_uninstaller(layout, config.version.as_deref().unwrap_or("0"))?;

    let ready = ui::progress("Starting Caboose", "Waiting for Caboose to answer…", false, |progress| {
        wait_until_ready(progress)
    })?;
    log.line(format!("ready: {ready:?}"));
    if rootfs.is_some() && options.distro.is_none() {
        let _ = std::fs::remove_dir_all(layout.downloads());
    }
    shell::start_tray(layout)?;
    finish(&config, &ready)?;
    Ok(Outcome::Installed)
}

/// Polls `caboose-wsl-ready` until caboose-host answers.
fn wait_until_ready(progress: &ui::Progress) -> Result<WslReady, String> {
    let started = Instant::now();
    let mut last = String::from("caboose-wsl-ready did not run");
    while started.elapsed() < START_TIMEOUT {
        match wslctl::ready() {
            Ok(ready) if ready.healthy => return Ok(ready),
            Ok(ready) => {
                last = format!("caboose-host.service is {}", ready.service.as_deref().unwrap_or("unknown"));
                progress.set(format!("Waiting for Caboose to answer ({last})…"), None);
            }
            Err(error) => last = error,
        }
        std::thread::sleep(Duration::from_secs(3));
    }
    Err(format!(
        "Caboose did not answer within {} minutes ({last}). Its log is in the distribution: wsl -d Caboose journalctl -u caboose-host",
        START_TIMEOUT.as_secs() / 60
    ))
}

/// The PC's LAN addresses for Caboose, best first.
fn lan_urls() -> Vec<String> {
    let primary = primary_ipv4();
    let interfaces: Vec<Interface> =
        primary.map(|address| Interface { name: String::new(), address }).into_iter().collect();
    address_urls(&phone_addresses(&interfaces, primary), PORT)
}

fn finish(config: &InstallConfig, ready: &WslReady) -> Result<(), String> {
    let mut content = String::from("Caboose starts with Windows, whether or not anyone signs in. Its icon in the notification area opens the console, where you can pair your iPhone.");
    if let Some(url) = lan_urls().first() {
        content.push_str(&format!("\n\nOn your local network it is at {url}."));
    }
    if config.networking == Networking::Nat {
        content.push_str(" Windows forwards that port to WSL.");
    }
    if powershell(NETWORK_CATEGORIES_SCRIPT).is_ok_and(|output| any_public_network(&output.stdout)) {
        content.push_str("\n\nWindows treats your current network as Public, so other devices cannot reach Caboose. If this is your home or office network, set it to Private in Settings › Network & internet.");
    }
    let code = ready
        .setup_code_path
        .as_deref()
        .map(|path| wslctl::exec_root("/bin/cat", &[path]).map(|output| output.stdout))
        .transpose()?;
    let base = if ready.url.is_empty() { local_url(PORT) } else { ready.url.clone() };
    let entry = console_entry(&base, code.as_deref(), None);
    let first_run = entry.contains("/setup");
    let (main, button) = if first_run {
        ("Caboose is installed. Finish setting it up in the console.", "Open the console")
    } else {
        ("Caboose is installed and running.", "Open the console")
    };
    if ui::ask(main, &content, button, "Close", true) && !ui::unattended() {
        shell::open_url(&entry);
    }
    Ok(())
}
