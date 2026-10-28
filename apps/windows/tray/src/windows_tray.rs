use caboose_win_core::process::{run_checked, system32};
use caboose_win_core::status::{console_entry, local_url, parse_ready};
use caboose_win_core::wsl::exec_as_root;
use caboose_win_core::{PORT, TRAY_WINDOW_CLASS};
use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    ShellExecuteW, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::*;

const TRAY_MESSAGE: u32 = WM_APP + 1;
const OPEN: usize = 1;
const QUIT: usize = 2;

fn open_console() {
    // Read the code at the time of the click, so a claim immediately removes it from links.
    let result = (|| -> Result<String, String> {
        let wsl = system32("wsl.exe");
        let ready = run_checked(&wsl, &exec_as_root("/usr/local/bin/caboose-wsl-ready", &[]))?;
        let ready = parse_ready(&ready.stdout)?;
        let code = match ready.setup_code_path.as_deref() {
            Some(path) => Some(run_checked(&wsl, &exec_as_root("/bin/cat", &[path]))?.stdout),
            None => None,
        };
        Ok(console_entry(&local_url(ready.port.unwrap_or(PORT)), code.as_deref(), None))
    })();
    unsafe {
        match result {
            Ok(url) => {
                let url = HSTRING::from(url);
                ShellExecuteW(None, w!("open"), &url, PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
            }
            Err(error) => {
                let message = HSTRING::from(format!("Could not open Caboose: {error}"));
                MessageBoxW(None, &message, w!("Caboose"), MB_OK | MB_ICONERROR);
            }
        }
    }
}

unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        TRAY_MESSAGE if lparam.0 as u32 == WM_LBUTTONDBLCLK => {
            std::thread::spawn(open_console);
            LRESULT(0)
        }
        TRAY_MESSAGE if lparam.0 as u32 == WM_RBUTTONUP => {
            unsafe {
                if let Ok(menu) = CreatePopupMenu() {
                    let _ = AppendMenuW(menu, MF_STRING, OPEN, w!("Open Caboose"));
                    let _ = AppendMenuW(menu, MF_STRING, QUIT, w!("Quit"));
                    let mut point = POINT::default();
                    let _ = GetCursorPos(&mut point);
                    let _ = SetForegroundWindow(hwnd);
                    let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, None, hwnd, None);
                    let _ = DestroyMenu(menu);
                }
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            match wparam.0 & 0xffff {
                OPEN => {
                    std::thread::spawn(open_console);
                }
                QUIT => unsafe {
                    let _ = DestroyWindow(hwnd);
                },
                _ => {}
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe {
                PostQuitMessage(0);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

pub fn run() -> Result<(), String> {
    unsafe {
        let class = HSTRING::from(TRAY_WINDOW_CLASS);
        if FindWindowW(&class, PCWSTR::null()).is_ok() {
            return Ok(());
        }
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?.into();
        let icon = LoadIconW(Some(instance), PCWSTR(1 as *const u16)).map_err(|e| e.to_string())?;
        let wc = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: PCWSTR(class.as_ptr()),
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 {
            return Err("Could not register tray window".into());
        }
        let hwnd = CreateWindowExW(
            Default::default(),
            &class,
            w!("Caboose"),
            Default::default(),
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        )
        .map_err(|e| e.to_string())?;
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: TRAY_MESSAGE,
            hIcon: icon,
            ..Default::default()
        };
        for (slot, ch) in data.szTip.iter_mut().zip("Caboose\0".encode_utf16()) {
            *slot = ch;
        }
        if !Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
            let _ = DestroyWindow(hwnd);
            return Err("Could not add notification icon".into());
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let _ = Shell_NotifyIconW(NIM_DELETE, &data);
    }
    Ok(())
}
