//! Uninstalling Caboose. Everything setup added goes: the startup task, firewall rules, port
//! forwarding, programs, shortcut, sign-in entries and uninstaller entry, and the
//! `.wslconfig` change if setup made it. The Caboose distribution, which holds the computers
//! and their files, stays registered (with caboose-host turned off) unless the user chooses to
//! delete it, so installing again picks up where it left off.

use crate::{elevated, shell, ui, wslctl, Options};
use caboose_win_core::layout::{InstallConfig, Layout};
use caboose_win_core::logfile::Log;
use caboose_win_core::wslconfig::{self, NETWORKING_MODE, SECTION};
use windows::Win32::UI::Controls::TDCBF_CANCEL_BUTTON;

pub fn run(options: &Options) -> i32 {
    ui::set_unattended(options.yes);
    let layout = match shell::layout() {
        Ok(layout) => layout,
        Err(error) => {
            ui::error("Caboose could not be uninstalled", &error);
            return 1;
        }
    };
    let delete_data = if options.yes {
        options.delete_data
    } else {
        let buttons = [(100, "Uninstall")];
        let (button, checked) = ui::show(&ui::Dialog {
            main: "Uninstall Caboose?",
            content: "Setup removes Caboose's programs, startup task, firewall rules and shortcuts. Your computers, their files and Caboose's settings stay in its WSL distribution, so installing Caboose again brings them back.",
            icon: ui::Icon::None,
            buttons: &buttons,
            common: TDCBF_CANCEL_BUTTON,
            verification: Some("Also delete the Caboose distribution and everything in it"),
        });
        if button != 100 {
            return 1602;
        }
        checked
    };
    let log = Log::new(layout.logs(), "setup");
    log.line(format!("uninstalling (delete data: {delete_data})"));
    match uninstall(&layout, delete_data, &log) {
        Ok(notes) => {
            let kept = if delete_data {
                String::new()
            } else {
                format!(
                    "\n\nThe Caboose distribution and its data are kept in {}. Run CabooseSetup to use them again, or delete them with: wsl --unregister Caboose",
                    layout.wsl().display()
                )
            };
            ui::info("Caboose is uninstalled.", &format!("{}{kept}", notes.join("\n")).trim().to_string());
            0
        }
        Err(error) => {
            log.line(format!("uninstall failed: {error}"));
            ui::error("Caboose could not be uninstalled", &error);
            1
        }
    }
}

fn uninstall(layout: &Layout, delete_data: bool, log: &Log) -> Result<Vec<String>, String> {
    let mut notes = Vec::new();
    shell::close_tray();
    let home = layout.root.to_string_lossy().into_owned();
    let step = layout.clone();
    ui::progress("Uninstalling Caboose", "Removing the startup task and firewall rules…", false, move |progress| {
        elevated::run_elevated(&step, &["remove", "--home", &home], Some(progress))
    })?;

    if wslctl::installed() {
        if delete_data {
            ui::progress("Uninstalling Caboose", "Deleting the Caboose distribution…", false, |_| {
                wslctl::unregister()
            })?;
            log.line("unregistered the distribution");
        } else {
            if let Err(error) = wslctl::disable_host() {
                log.line(format!("could not turn caboose-host off: {error}"));
            }
            wslctl::terminate();
        }
    }

    // Put .wslconfig back if setup changed it and it still says what setup wrote.
    let config = std::fs::read_to_string(layout.config()).ok().and_then(|text| InstallConfig::parse(&text).ok());
    if let Some(config) = config.filter(|config| config.changed_wslconfig) {
        if let Ok(path) = shell::wslconfig_path() {
            let text = std::fs::read(&path).map(|bytes| wslconfig::decode(&bytes)).unwrap_or_default();
            if wslconfig::is_mirrored(&text) {
                let restored =
                    wslconfig::set(&text, SECTION, NETWORKING_MODE, config.previous_networking_mode.as_deref());
                match std::fs::write(&path, restored) {
                    Ok(()) => notes.push(
                        "WSL's networking is back to how it was; it applies the next time WSL starts.".to_string(),
                    ),
                    Err(error) => log.line(format!("could not restore {}: {error}", path.display())),
                }
            }
        }
    }

    shell::remove_autostart();
    shell::remove_shortcut();
    shell::remove_uninstaller();
    for path in [layout.config(), layout.service_status()] {
        let _ = std::fs::remove_file(path);
    }
    let _ = std::fs::remove_dir_all(layout.downloads());
    if delete_data {
        let _ = std::fs::remove_dir_all(layout.wsl());
    }
    log.line("uninstalled");
    let _ = std::fs::remove_dir_all(layout.logs());
    // The programs, setup included, go once this process has exited; then the folder itself
    // if nothing (such as a kept distribution) is left in it.
    shell::delete_after_exit(layout);
    Ok(notes)
}
