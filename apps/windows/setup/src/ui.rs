//! Setup's dialogs, all Windows task dialogs: messages, questions, and a progress dialog that
//! stays up while a step runs on another thread.

use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use windows::core::{BOOL, HRESULT, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, S_FALSE, S_OK, WPARAM};
use windows::Win32::UI::Controls::{
    TaskDialogIndirect, TASKDIALOGCONFIG, TASKDIALOG_BUTTON, TASKDIALOG_COMMON_BUTTON_FLAGS, TASKDIALOG_NOTIFICATIONS,
    TDCBF_CANCEL_BUTTON, TDCBF_OK_BUTTON, TDE_CONTENT, TDF_ALLOW_DIALOG_CANCELLATION, TDF_CALLBACK_TIMER,
    TDF_SHOW_MARQUEE_PROGRESS_BAR, TDF_SHOW_PROGRESS_BAR, TDF_SIZE_TO_CONTENT, TDM_CLICK_BUTTON, TDM_ENABLE_BUTTON,
    TDM_SET_ELEMENT_TEXT, TDM_SET_MARQUEE_PROGRESS_BAR, TDM_SET_PROGRESS_BAR_MARQUEE, TDM_SET_PROGRESS_BAR_POS,
    TDN_BUTTON_CLICKED, TDN_CREATED, TDN_TIMER, TD_ERROR_ICON, TD_INFORMATION_ICON,
};
use windows::Win32::UI::WindowsAndMessaging::{SendMessageW, IDCANCEL, IDOK};

pub const TITLE: &str = "Caboose Setup";

/// Whether setup runs unattended (`--yes`): questions take their recommended answer and
/// messages go only to the log.
static UNATTENDED: AtomicBool = AtomicBool::new(false);

pub fn set_unattended(value: bool) {
    UNATTENDED.store(value, Ordering::Relaxed);
}

pub fn unattended() -> bool {
    UNATTENDED.load(Ordering::Relaxed)
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

#[derive(Clone, Copy)]
pub enum Icon {
    None,
    Information,
    Error,
}

impl Icon {
    fn resource(self) -> PCWSTR {
        match self {
            Icon::None => PCWSTR::null(),
            Icon::Information => TD_INFORMATION_ICON,
            Icon::Error => TD_ERROR_ICON,
        }
    }
}

/// A task dialog's contents. Buttons are `(id, label)`; ids from 100 up are free.
pub struct Dialog<'a> {
    pub main: &'a str,
    pub content: &'a str,
    pub icon: Icon,
    pub buttons: &'a [(i32, &'a str)],
    pub common: TASKDIALOG_COMMON_BUTTON_FLAGS,
    pub verification: Option<&'a str>,
}

/// Shows the dialog and returns the button pressed and whether the checkbox was ticked.
pub fn show(dialog: &Dialog<'_>) -> (i32, bool) {
    let title = wide(TITLE);
    let main = wide(dialog.main);
    let content = wide(dialog.content);
    let verification = dialog.verification.map(wide);
    let labels: Vec<Vec<u16>> = dialog.buttons.iter().map(|(_, label)| wide(label)).collect();
    let buttons: Vec<TASKDIALOG_BUTTON> = dialog
        .buttons
        .iter()
        .zip(&labels)
        .map(|((id, _), label)| TASKDIALOG_BUTTON { nButtonID: *id, pszButtonText: PCWSTR(label.as_ptr()) })
        .collect();
    let mut config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT,
        dwCommonButtons: dialog.common,
        pszWindowTitle: PCWSTR(title.as_ptr()),
        pszMainInstruction: PCWSTR(main.as_ptr()),
        pszContent: PCWSTR(content.as_ptr()),
        cButtons: buttons.len() as u32,
        pButtons: if buttons.is_empty() { std::ptr::null() } else { buttons.as_ptr() },
        nDefaultButton: dialog.buttons.first().map(|(id, _)| *id).unwrap_or(0),
        pszVerificationText: verification.as_ref().map(|text| PCWSTR(text.as_ptr())).unwrap_or(PCWSTR::null()),
        ..Default::default()
    };
    config.Anonymous1.pszMainIcon = dialog.icon.resource();
    let mut button = 0;
    let mut checked = BOOL(0);
    // SAFETY: every pointer in `config` refers to a buffer that lives until this call returns.
    let shown = unsafe { TaskDialogIndirect(&config, Some(&mut button), None, Some(&mut checked)) };
    if shown.is_err() {
        return (IDCANCEL.0, false);
    }
    (button, checked.as_bool())
}

/// A message with an OK button; skipped when unattended.
pub fn message(icon: Icon, main: &str, content: &str) {
    if unattended() {
        return;
    }
    show(&Dialog { main, content, icon, buttons: &[], common: TDCBF_OK_BUTTON, verification: None });
}

pub fn info(main: &str, content: &str) {
    message(Icon::Information, main, content);
}

pub fn error(main: &str, content: &str) {
    message(Icon::Error, main, content);
}

/// A question with two answers. Unattended, the answer is `recommended`.
pub fn ask(main: &str, content: &str, yes: &str, no: &str, recommended: bool) -> bool {
    if unattended() {
        return recommended;
    }
    let buttons = [(100, yes), (101, no)];
    let (button, _) = show(&Dialog {
        main,
        content,
        icon: Icon::None,
        buttons: &buttons,
        common: TASKDIALOG_COMMON_BUTTON_FLAGS(0),
        verification: None,
    });
    button == 100
}

/// What a step running under [`progress`] reports, and how it learns it was cancelled.
pub struct Progress {
    state: Mutex<ProgressState>,
    cancelled: AtomicBool,
    window: AtomicIsize,
}

struct ProgressState {
    text: String,
    /// 0–100, or `None` for a marquee.
    percent: Option<u32>,
    shown_text: String,
    shown_percent: Option<u32>,
    finished: bool,
    /// The text currently in the dialog, kept alive while the dialog points at it.
    buffer: Vec<u16>,
}

impl Progress {
    pub fn set(&self, text: impl Into<String>, percent: Option<u32>) {
        let mut state = self.state.lock().expect("progress state");
        state.text = text.into();
        state.percent = percent.map(|value| value.min(100));
    }

    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    /// The dialog's window, to own the prompts a step raises (UAC's, for one).
    pub fn window(&self) -> Option<HWND> {
        match self.window.load(Ordering::Relaxed) {
            0 => None,
            handle => Some(HWND(handle as *mut _)),
        }
    }
}

/// Runs `step` on another thread while a progress dialog shows what it reports. With
/// `cancellable`, the dialog's Cancel button sets [`Progress::cancelled`] and the step decides
/// when to stop; otherwise the dialog cannot be closed until the step ends.
pub fn progress<T: Send + 'static>(
    main: &str,
    text: &str,
    cancellable: bool,
    step: impl FnOnce(&Progress) -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let shared = Arc::new(Progress {
        state: Mutex::new(ProgressState {
            text: text.to_string(),
            percent: None,
            shown_text: String::new(),
            shown_percent: None,
            finished: false,
            buffer: Vec::new(),
        }),
        cancelled: AtomicBool::new(false),
        window: AtomicIsize::new(0),
    });
    let worker = {
        let shared = shared.clone();
        thread::spawn(move || {
            let result = step(&shared);
            shared.state.lock().expect("progress state").finished = true;
            result
        })
    };

    let context = Context { progress: shared.clone(), cancellable };
    let title = wide(TITLE);
    let main = wide(main);
    let initial = wide(text);
    let config = TASKDIALOGCONFIG {
        cbSize: std::mem::size_of::<TASKDIALOGCONFIG>() as u32,
        dwFlags: TDF_CALLBACK_TIMER
            | TDF_SHOW_PROGRESS_BAR
            | TDF_SHOW_MARQUEE_PROGRESS_BAR
            | TDF_ALLOW_DIALOG_CANCELLATION,
        dwCommonButtons: TDCBF_CANCEL_BUTTON,
        pszWindowTitle: PCWSTR(title.as_ptr()),
        pszMainInstruction: PCWSTR(main.as_ptr()),
        pszContent: PCWSTR(initial.as_ptr()),
        pfCallback: Some(progress_callback),
        lpCallbackData: &context as *const Context as isize,
        cxWidth: 300,
        ..Default::default()
    };
    // SAFETY: `config` and `context` outlive the call, which returns only when the dialog closes.
    let shown = unsafe { TaskDialogIndirect(&config, None, None, None) };
    if shown.is_err() {
        // No dialog (for example, without Common Controls 6): wait for the step all the same.
        shared.state.lock().expect("progress state").finished = true;
    }
    worker.join().unwrap_or_else(|_| Err("The setup step stopped unexpectedly.".to_string()))
}

struct Context {
    progress: Arc<Progress>,
    cancellable: bool,
}

unsafe extern "system" fn progress_callback(
    window: HWND,
    notification: TASKDIALOG_NOTIFICATIONS,
    wparam: WPARAM,
    _lparam: LPARAM,
    data: isize,
) -> HRESULT {
    // SAFETY: `data` is the `Context` that `progress` keeps alive while the dialog is open.
    let context = unsafe { &*(data as *const Context) };
    let send = |message: i32, wparam: usize, lparam: isize| {
        // SAFETY: a message to the dialog this callback belongs to.
        unsafe { SendMessageW(window, message as u32, Some(WPARAM(wparam)), Some(LPARAM(lparam))) };
    };
    match notification {
        TDN_CREATED => {
            context.progress.window.store(window.0 as isize, Ordering::Relaxed);
            send(TDM_SET_PROGRESS_BAR_MARQUEE.0, 1, 30);
            if !context.cancellable {
                send(TDM_ENABLE_BUTTON.0, IDCANCEL.0 as usize, 0);
            }
            S_OK
        }
        TDN_TIMER => {
            let mut state = context.progress.state.lock().expect("progress state");
            if state.finished {
                drop(state);
                send(TDM_CLICK_BUTTON.0, IDOK.0 as usize, 0);
                send(TDM_CLICK_BUTTON.0, IDCANCEL.0 as usize, 0);
                return S_OK;
            }
            if state.text != state.shown_text {
                state.shown_text = state.text.clone();
                state.buffer = wide(&state.text);
                send(TDM_SET_ELEMENT_TEXT.0, TDE_CONTENT.0 as usize, state.buffer.as_ptr() as isize);
            }
            if state.percent != state.shown_percent {
                match state.percent {
                    Some(percent) => {
                        if state.shown_percent.is_none() {
                            send(TDM_SET_MARQUEE_PROGRESS_BAR.0, 0, 0);
                        }
                        send(TDM_SET_PROGRESS_BAR_POS.0, percent as usize, 0);
                    }
                    None => {
                        send(TDM_SET_MARQUEE_PROGRESS_BAR.0, 1, 0);
                        send(TDM_SET_PROGRESS_BAR_MARQUEE.0, 1, 30);
                    }
                }
                state.shown_percent = state.percent;
            }
            S_OK
        }
        TDN_BUTTON_CLICKED => {
            let finished = context.progress.state.lock().expect("progress state").finished;
            if finished {
                return S_OK;
            }
            if context.cancellable && wparam.0 as i32 == IDCANCEL.0 {
                context.progress.cancelled.store(true, Ordering::Relaxed);
                send(TDM_ENABLE_BUTTON.0, IDCANCEL.0 as usize, 0);
            }
            // Keep the dialog open until the step has stopped.
            S_FALSE
        }
        _ => S_OK,
    }
}
