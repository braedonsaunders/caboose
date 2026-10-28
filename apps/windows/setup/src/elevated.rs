//! The steps that need an administrator. Setup runs as the signed-in user and starts a second
//! copy of itself elevated (`CabooseSetup.exe --elevated <action> …`) for these:
//!
//! ```text
//! install-wsl  --result <file>         wsl --install --no-distribution
//! update-wsl   --result <file>         wsl --update
//! configure    --result <file> --sid <SID> --home <dir> --networking mirrored|nat
//!              firewall rules, port forwarding for mirrored mode, the "Caboose" task, and (re)starting it
//! remove       --result <file>         the task, the firewall rules and port forwarding
//! ```
//!
//! The elevated copy shows no windows. It exits 0 on success; otherwise it writes what went
//! wrong to the result file, which the unelevated setup shows.

use crate::ui::Progress;
use caboose_win_core::firewall;
use caboose_win_core::layout::Layout;
use caboose_win_core::logfile::Log;
use caboose_win_core::portproxy::{self, Rule};
use caboose_win_core::process::{powershell, run, run_checked, system32};
use caboose_win_core::status::ServiceStatus;
use caboose_win_core::task::{quote_argument, task_xml, utf16le_with_bom, TaskSpec};
use caboose_win_core::{PORT, TASK_NAME};
use std::path::{Path, PathBuf};
use windows::core::{HSTRING, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, ERROR_CANCELLED, HWND};
use windows::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE};
use windows::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOASYNC, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

/// Runs `action` elevated and waits for it. UAC asks the user first.
pub fn run_elevated(layout: &Layout, action: &[&str], progress: Option<&Progress>) -> Result<(), String> {
    let result = layout.logs().join(format!("elevated-{}.txt", std::process::id()));
    std::fs::create_dir_all(layout.logs())
        .map_err(|error| format!("Could not create {}: {error}", layout.logs().display()))?;
    let _ = std::fs::remove_file(&result);
    let exe = std::env::current_exe().map_err(|error| format!("Could not find CabooseSetup.exe: {error}"))?;
    let mut arguments = vec!["--elevated".to_string()];
    arguments.extend(action.iter().map(|part| part.to_string()));
    arguments.extend(["--result".to_string(), result.to_string_lossy().into_owned()]);
    let parameters = arguments.iter().map(|argument| quote_argument(argument)).collect::<Vec<_>>().join(" ");

    let verb = HSTRING::from("runas");
    let file = HSTRING::from(exe.as_os_str());
    let parameters = HSTRING::from(parameters);
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
        hwnd: progress.and_then(Progress::window).unwrap_or(HWND::default()),
        lpVerb: PCWSTR(verb.as_ptr()),
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: PCWSTR(parameters.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    // SAFETY: `info` and the strings it points to live until the call returns; the process
    // handle it returns is waited on and closed here.
    unsafe {
        if let Err(error) = ShellExecuteExW(&mut info) {
            let error: windows::core::Error = error;
            return Err(if error.code() == ERROR_CANCELLED.to_hresult() {
                "Caboose needs administrator permission for this step, and it was declined.".to_string()
            } else {
                format!("Could not start the administrator step: {error}")
            });
        }
        if info.hProcess.is_invalid() {
            return Err("The administrator step did not start.".to_string());
        }
        WaitForSingleObject(info.hProcess, INFINITE);
        let mut code = 1u32;
        let _ = GetExitCodeProcess(info.hProcess, &mut code);
        let _ = CloseHandle(info.hProcess);
        if code == 0 {
            let _ = std::fs::remove_file(&result);
            return Ok(());
        }
    }
    let message = std::fs::read_to_string(&result).unwrap_or_default();
    let _ = std::fs::remove_file(&result);
    Err(if message.trim().is_empty() {
        "The administrator step failed.".to_string()
    } else {
        message.trim().to_string()
    })
}

/// The elevated copy's entry point.
pub fn main(arguments: &[String]) -> i32 {
    let value = |name: &str| arguments.windows(2).find(|pair| pair[0] == name).map(|pair| pair[1].clone());
    let result_file = value("--result").map(PathBuf::from);
    let home = value("--home").map(PathBuf::from);
    let log = home.as_ref().map(|home| Log::new(home.join("logs"), "setup"));
    let note = |message: &str| {
        if let Some(log) = &log {
            log.line(format!("[elevated] {message}"));
        }
    };
    let outcome = match arguments.first().map(String::as_str) {
        Some("install-wsl") => run_checked(system32("wsl.exe"), &["--install", "--no-distribution"]).map(|_| ()),
        Some("update-wsl") => run_checked(system32("wsl.exe"), &["--update"]).map(|_| ()),
        Some("configure") => match (value("--sid"), home.as_deref(), value("--networking")) {
            (Some(sid), Some(home), Some(networking)) => configure(&sid, home, networking == "mirrored", &note),
            _ => Err("configure needs --sid, --home and --networking.".to_string()),
        },
        Some("remove") => match home.as_deref() {
            Some(home) => remove(home, &note),
            None => Err("remove needs --home.".into()),
        },
        other => Err(format!("Unknown administrator step {other:?}.")),
    };
    match outcome {
        Ok(()) => 0,
        Err(message) => {
            note(&format!("failed: {message}"));
            if let Some(file) = result_file {
                let _ = std::fs::write(file, &message);
            }
            1
        }
    }
}

fn netsh(arguments: &[String]) -> Result<(), String> {
    run_checked(system32("netsh.exe"), arguments).map(|_| ())
}

fn schtasks(arguments: &[&str]) -> Result<(), String> {
    run_checked(system32("schtasks.exe"), arguments).map(|_| ())
}

/// The rules for port 7310 that `netsh interface portproxy show v4tov4` lists.
fn port_rules() -> Vec<Rule> {
    run(system32("netsh.exe"), &["interface", "portproxy", "show", "v4tov4"])
        .map(|output| portproxy::parse_show(&output.stdout))
        .unwrap_or_default()
}

fn owned_rule(layout: &Layout) -> Option<Rule> {
    let status = std::fs::read_to_string(layout.service_status()).ok()?;
    let status: ServiceStatus = serde_json::from_str(&status).ok()?;
    status.distro_address.map(|address| Rule::to_distro(&address, PORT))
}

fn configure(sid: &str, home: &Path, mirrored: bool, note: &dyn Fn(&str)) -> Result<(), String> {
    let layout = Layout { root: home.to_path_buf() };

    note("adding the Windows Firewall rule");
    let _ = netsh(&firewall::delete_rule());
    netsh(&firewall::add_rule(PORT))?;

    note("adding the Hyper-V firewall rule");
    if let Err(error) = powershell(&firewall::hyperv_rule_script(PORT)) {
        if mirrored {
            return Err(format!("Could not let the network reach WSL through the Hyper-V firewall: {error}"));
        }
        note(&format!("no Hyper-V firewall rule (not needed with NAT networking): {error}"));
    }

    if mirrored {
        // The distribution listens on Windows' own port 7310, so no forwarding rule may hold it
        // (one from a hand-made setup, or from NAT networking before).
        for command in portproxy::plan(None, &port_rules(), owned_rule(&layout).as_ref())? {
            note(&format!("netsh {}", command.join(" ")));
            netsh(&command)?;
        }
    }

    note("registering the Caboose task");
    let xml = task_xml(&TaskSpec {
        user_sid: sid,
        command: &layout.service_exe().to_string_lossy(),
        arguments: &format!("--home {}", quote_argument(&home.to_string_lossy())),
        working_directory: &layout.bin().to_string_lossy(),
    });
    let xml_path = home.join("caboose-task.xml");
    std::fs::write(&xml_path, utf16le_with_bom(&xml))
        .map_err(|error| format!("Could not write {}: {error}", xml_path.display()))?;
    let created = schtasks(&["/Create", "/TN", TASK_NAME, "/XML", &xml_path.to_string_lossy(), "/F"]);
    let _ = std::fs::remove_file(&xml_path);
    created.map_err(|error| format!("Could not register the Caboose startup task: {error}"))?;

    note("starting the Caboose task");
    let _ = schtasks(&["/End", "/TN", TASK_NAME]);
    schtasks(&["/Run", "/TN", TASK_NAME])
}

fn remove(home: &Path, note: &dyn Fn(&str)) -> Result<(), String> {
    let layout = Layout { root: home.to_path_buf() };
    note("removing the Caboose task, firewall rules and port forwarding");
    let _ = schtasks(&["/End", "/TN", TASK_NAME]);
    let _ = schtasks(&["/Delete", "/TN", TASK_NAME, "/F"]);
    let _ = netsh(&firewall::delete_rule());
    let _ = powershell(&firewall::remove_hyperv_rule_script());
    for command in portproxy::plan(None, &port_rules(), owned_rule(&layout).as_ref())? {
        let _ = netsh(&command);
    }
    Ok(())
}
