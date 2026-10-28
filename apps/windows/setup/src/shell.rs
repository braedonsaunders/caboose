//! What setup asks of Windows itself: the folders, the version, the processor, the registry
//! entries that make Caboose an installed program, the Start menu shortcut, and the tray.

use caboose_win_core::layout::{Layout, SETUP_EXE};
use caboose_win_core::task::quote_argument;
use caboose_win_core::winver::WindowsBuild;
use std::path::{Path, PathBuf};
use windows::core::{Interface, HSTRING, PCWSTR};
use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::SystemInformation::{IMAGE_FILE_MACHINE, IMAGE_FILE_MACHINE_AMD64};
use windows::Win32::System::Threading::{
    GetCurrentProcess, IsProcessorFeaturePresent, IsWow64Process2, PF_VIRT_FIRMWARE_ENABLED,
};
use windows::Win32::UI::Shell::{IShellLinkW, ShellExecuteW, ShellLink};
use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, PostMessageW, SW_SHOWNORMAL, WM_CLOSE};
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
use winreg::RegKey;

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_ONCE_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\RunOnce";
const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Caboose";
const RUN_VALUE: &str = "Caboose";
const RUN_ONCE_VALUE: &str = "CabooseSetup";

fn folder(variable: &str) -> Result<PathBuf, String> {
    std::env::var_os(variable).map(PathBuf::from).ok_or_else(|| format!("Windows did not set %{variable}%."))
}

/// `%LOCALAPPDATA%\Caboose`.
pub fn layout() -> Result<Layout, String> {
    Ok(Layout::new(folder("LOCALAPPDATA")?))
}

/// `%USERPROFILE%\.wslconfig`.
pub fn wslconfig_path() -> Result<PathBuf, String> {
    Ok(folder("USERPROFILE")?.join(".wslconfig"))
}

/// The Start menu shortcut: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Caboose.lnk`.
pub fn shortcut_path() -> Result<PathBuf, String> {
    Ok(folder("APPDATA")?.join(r"Microsoft\Windows\Start Menu\Programs\Caboose.lnk"))
}

/// This Windows' version, from the registry (which, unlike `GetVersionEx`, does not lie to
/// programs without a compatibility manifest).
pub fn windows_build() -> Result<WindowsBuild, String> {
    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")
        .map_err(|error| format!("Could not read the Windows version: {error}"))?;
    let major: u32 = key.get_value("CurrentMajorVersionNumber").unwrap_or(10);
    let minor: u32 = key.get_value("CurrentMinorVersionNumber").unwrap_or(0);
    let build: String =
        key.get_value("CurrentBuildNumber").map_err(|error| format!("Could not read the Windows build: {error}"))?;
    let build = build.trim().parse().map_err(|_| format!("Windows reported an unreadable build number, {build}."))?;
    Ok(WindowsBuild { major, minor, build })
}

/// Whether this is an x64 PC (the distribution is amd64), even when setup runs emulated.
pub fn is_x64() -> bool {
    let mut process = IMAGE_FILE_MACHINE(0);
    let mut native = IMAGE_FILE_MACHINE(0);
    // SAFETY: plain out-parameters for the current process.
    match unsafe { IsWow64Process2(GetCurrentProcess(), &mut process, Some(&mut native)) } {
        Ok(()) => native == IMAGE_FILE_MACHINE_AMD64,
        Err(_) => cfg!(target_arch = "x86_64"),
    }
}

/// Whether the processor's virtualization is on: either firmware reports it enabled, or a
/// hypervisor (Hyper-V, which WSL 2 uses) is already running, which hides that report.
pub fn virtualization_enabled() -> bool {
    // SAFETY: a feature query with no side effects.
    let firmware = unsafe { IsProcessorFeaturePresent(PF_VIRT_FIRMWARE_ENABLED) }.as_bool();
    firmware || hypervisor_present()
}

#[cfg(target_arch = "x86_64")]
fn hypervisor_present() -> bool {
    // SAFETY: CPUID leaf 1 exists on every x86-64 processor; bit 31 of ECX means a hypervisor.
    // (Newer Rust no longer marks __cpuid unsafe.)
    #[allow(unused_unsafe)]
    let leaf = unsafe { std::arch::x86_64::__cpuid(1) };
    leaf.ecx & (1 << 31) != 0
}

#[cfg(not(target_arch = "x86_64"))]
fn hypervisor_present() -> bool {
    false
}

/// The signed-in user's `DOMAIN\name` and SID.
pub fn current_user() -> Result<(String, String), String> {
    let whoami = caboose_win_core::process::system32("whoami.exe");
    let output = caboose_win_core::process::run_checked(whoami, &["/user", "/fo", "csv", "/nh"])?;
    caboose_win_core::task::parse_whoami_user(&output.stdout)
        .ok_or_else(|| format!("whoami gave no user: {}", output.stdout.trim()))
}

/// Opens a URL in the default browser.
pub fn open_url(url: &str) {
    // SAFETY: plain strings that live until the call returns.
    unsafe {
        ShellExecuteW(None, &HSTRING::from("open"), &HSTRING::from(url), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

/// Asks a running tray to quit, and gives it a moment.
pub fn close_tray() {
    // SAFETY: looks up a window by class and posts it a message.
    unsafe {
        if let Ok(window) = FindWindowW(&HSTRING::from(caboose_win_core::TRAY_WINDOW_CLASS), PCWSTR::null()) {
            let _ = PostMessageW(Some(window), WM_CLOSE, WPARAM(0), LPARAM(0));
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }
}

/// Starts the tray as this user.
pub fn start_tray(layout: &Layout) -> Result<(), String> {
    std::process::Command::new(layout.tray_exe())
        .current_dir(layout.bin())
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("Could not start the tray: {error}"))
}

fn hkcu() -> RegKey {
    RegKey::predef(HKEY_CURRENT_USER)
}

/// Starts the tray when the user signs in (the tray's "Start with Windows" changes this).
pub fn set_tray_autostart(layout: &Layout) -> Result<(), String> {
    let (key, _) = hkcu().create_subkey(RUN_KEY).map_err(|error| format!("Could not open the Run key: {error}"))?;
    key.set_value(RUN_VALUE, &quote_argument(&layout.tray_exe().to_string_lossy()))
        .map_err(|error| format!("Could not start the tray with Windows: {error}"))
}

/// Continues setup at the next sign-in, after the restart WSL's installation needs.
pub fn set_resume(layout: &Layout) -> Result<(), String> {
    let (key, _) =
        hkcu().create_subkey(RUN_ONCE_KEY).map_err(|error| format!("Could not open the RunOnce key: {error}"))?;
    let command = format!("{} --resume", quote_argument(&layout.setup_exe().to_string_lossy()));
    key.set_value(RUN_ONCE_VALUE, &command)
        .map_err(|error| format!("Could not schedule setup after the restart: {error}"))
}

/// Removes the Run and RunOnce entries; absent ones are fine.
pub fn remove_autostart() {
    for (path, value) in [(RUN_KEY, RUN_VALUE), (RUN_ONCE_KEY, RUN_ONCE_VALUE)] {
        if let Ok(key) = hkcu().open_subkey_with_flags(path, winreg::enums::KEY_SET_VALUE) {
            let _ = key.delete_value(value);
        }
    }
}

/// Lists Caboose in Settings › Apps, with an uninstaller that runs this program.
pub fn register_uninstaller(layout: &Layout, version: &str) -> Result<(), String> {
    let fail = |error: std::io::Error| format!("Could not register the uninstaller: {error}");
    let (key, _) = hkcu().create_subkey(UNINSTALL_KEY).map_err(fail)?;
    let setup = quote_argument(&layout.setup_exe().to_string_lossy());
    let size_kb = std::fs::read_dir(layout.bin())
        .map(|entries| {
            entries.filter_map(|entry| entry.ok()?.metadata().ok()).map(|meta| meta.len()).sum::<u64>() / 1024
        })
        .unwrap_or(0);
    key.set_value("DisplayName", &"Caboose").map_err(fail)?;
    key.set_value("DisplayVersion", &version.trim_start_matches('v')).map_err(fail)?;
    key.set_value("Publisher", &"Caboose").map_err(fail)?;
    key.set_value("URLInfoAbout", &"https://github.com/braedonsaunders/caboose").map_err(fail)?;
    key.set_value("DisplayIcon", &layout.icon().to_string_lossy().into_owned()).map_err(fail)?;
    key.set_value("InstallLocation", &layout.root.to_string_lossy().into_owned()).map_err(fail)?;
    key.set_value("UninstallString", &format!("{setup} --uninstall")).map_err(fail)?;
    key.set_value("QuietUninstallString", &format!("{setup} --uninstall --yes")).map_err(fail)?;
    key.set_value("EstimatedSize", &(size_kb.min(u32::MAX as u64) as u32)).map_err(fail)?;
    key.set_value("NoModify", &1u32).map_err(fail)?;
    key.set_value("NoRepair", &1u32).map_err(fail)?;
    Ok(())
}

pub fn remove_uninstaller() {
    let _ = hkcu().delete_subkey_all(UNINSTALL_KEY);
}

/// The Start menu shortcut to the tray.
pub fn create_shortcut(layout: &Layout) -> Result<(), String> {
    let path = shortcut_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("Could not create the Start menu folder: {error}"))?;
    }
    let fail = |error: windows::core::Error| format!("Could not create the Start menu shortcut: {error}");
    // SAFETY: COM calls on this thread with strings that live until each call returns.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(fail)?;
        link.SetPath(&HSTRING::from(layout.tray_exe().as_os_str())).map_err(fail)?;
        link.SetWorkingDirectory(&HSTRING::from(layout.bin().as_os_str())).map_err(fail)?;
        link.SetIconLocation(&HSTRING::from(layout.icon().as_os_str()), 0).map_err(fail)?;
        link.SetDescription(&HSTRING::from("Caboose: your phone's computer")).map_err(fail)?;
        let file: IPersistFile = link.cast().map_err(fail)?;
        file.Save(&HSTRING::from(path.as_os_str()), true).map_err(fail)?;
    }
    Ok(())
}

pub fn remove_shortcut() {
    if let Ok(path) = shortcut_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// Writes `bytes` to `path`, even while an older copy of it is running: Windows lets a running
/// program's file be renamed, so the old one moves aside to `<name>.old` and is deleted when
/// it can be.
pub fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let fail = |error: std::io::Error| format!("Could not write {}: {error}", path.display());
    let fresh = path.with_extension("new");
    let old = path.with_extension("old");
    std::fs::write(&fresh, bytes).map_err(fail)?;
    let _ = std::fs::remove_file(&old);
    if path.exists() {
        std::fs::rename(path, &old).map_err(fail)?;
    }
    std::fs::rename(&fresh, path).map_err(fail)?;
    let _ = std::fs::remove_file(&old);
    Ok(())
}

/// Puts setup itself in `bin`, so the uninstaller and the resume after a restart have a copy
/// that stays put. A no-op when setup already runs from there.
pub fn install_self(layout: &Layout) -> Result<(), String> {
    let current = std::env::current_exe().map_err(|error| format!("Could not find CabooseSetup.exe: {error}"))?;
    std::fs::create_dir_all(layout.bin())
        .map_err(|error| format!("Could not create {}: {error}", layout.bin().display()))?;
    let target = layout.bin().join(SETUP_EXE);
    let same = std::fs::canonicalize(&current).ok() == std::fs::canonicalize(&target).ok();
    if !same {
        let bytes =
            std::fs::read(&current).map_err(|error| format!("Could not read {}: {error}", current.display()))?;
        replace_file(&target, &bytes)?;
    }
    Ok(())
}

/// The service and tray executables: embedded in a release build of setup, or next to setup.
pub fn program_bytes(name: &str, embedded: Option<&'static [u8]>) -> Result<std::borrow::Cow<'static, [u8]>, String> {
    if let Some(bytes) = embedded {
        return Ok(std::borrow::Cow::Borrowed(bytes));
    }
    let beside = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join(name)))
        .filter(|path| path.is_file())
        .ok_or_else(|| format!("This CabooseSetup.exe does not include {name}, and there is none beside it."))?;
    std::fs::read(&beside)
        .map(std::borrow::Cow::Owned)
        .map_err(|error| format!("Could not read {}: {error}", beside.display()))
}

/// Deletes the program folder once this process has exited, since a running program cannot
/// delete itself, and then Caboose's folder if nothing else is left in it.
pub fn delete_after_exit(layout: &Layout) {
    let cmd = caboose_win_core::process::system32("cmd.exe");
    let script = format!(
        "/c ping -n 4 127.0.0.1 >NUL & rmdir /s /q \"{}\" & rmdir \"{}\"",
        layout.bin().display(),
        layout.root.display()
    );
    // cmd.exe reads its command line itself, so it is passed as written rather than quoted.
    use std::os::windows::process::CommandExt;
    let _ = caboose_win_core::process::command(cmd).raw_arg(script).current_dir(std::env::temp_dir()).spawn();
}
