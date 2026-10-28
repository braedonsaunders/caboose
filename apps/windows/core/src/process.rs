//! Running the Windows tools Caboose drives (`wsl.exe`, `netsh`, `schtasks`, PowerShell)
//! without a console window flashing up, and reading their output whatever its encoding.

use crate::wsl::decode_output;
use std::ffi::OsStr;
use std::io;
use std::process::{Command, Stdio};

/// A finished program's exit code and output.
#[derive(Debug, Clone)]
pub struct Output {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl Output {
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }

    /// The output to show when it failed: stderr, else stdout, trimmed.
    pub fn message(&self) -> String {
        let text = if self.stderr.trim().is_empty() { &self.stdout } else { &self.stderr };
        text.trim().to_string()
    }
}

/// A command that opens no console window, and asks WSL for UTF-8 messages.
pub fn command(program: impl AsRef<OsStr>) -> Command {
    let mut command = Command::new(program);
    command.env("WSL_UTF8", "1").stdin(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// Runs `program` to completion and collects its output.
pub fn run<S: AsRef<OsStr>>(program: impl AsRef<OsStr>, arguments: &[S]) -> io::Result<Output> {
    let output = command(program).args(arguments).output()?;
    Ok(Output {
        code: output.status.code(),
        stdout: decode_output(&output.stdout),
        stderr: decode_output(&output.stderr),
    })
}

/// Runs `program` and fails with its message unless it exits 0.
pub fn run_checked<S: AsRef<OsStr>>(program: impl AsRef<OsStr>, arguments: &[S]) -> Result<Output, String> {
    let name = program.as_ref().to_string_lossy().into_owned();
    let output = run(&program, arguments).map_err(|error| format!("Could not run {name}: {error}"))?;
    if output.success() {
        Ok(output)
    } else {
        let message = output.message();
        Err(match output.code {
            Some(code) if message.is_empty() => format!("{name} failed (exit code {code})."),
            Some(code) => format!("{name} failed (exit code {code}): {message}"),
            None => format!("{name} was stopped: {message}"),
        })
    }
}

/// The program `name` in Windows' System32 (`%SystemRoot%\System32\<name>`), so a file of the
/// same name elsewhere on `PATH` is never run instead.
pub fn system32(name: &str) -> std::path::PathBuf {
    let root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    std::path::Path::new(&root).join("System32").join(name)
}

/// `powershell.exe` from System32, with a script and no profile.
pub fn powershell(script: &str) -> Result<Output, String> {
    let program = system32(r"WindowsPowerShell\v1.0\powershell.exe");
    run_checked(program, &["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explains_failures() {
        let output = Output { code: Some(1), stdout: "out\n".into(), stderr: " \n".into() };
        assert!(!output.success());
        assert_eq!(output.message(), "out");
    }

    #[cfg(unix)]
    #[test]
    fn runs_programs() {
        let output = run("/bin/sh", &["-c", "printf hello; exit 3"]).unwrap();
        assert_eq!((output.code, output.stdout.as_str()), (Some(3), "hello"));
        assert!(run_checked("/bin/sh", &["-c", "echo nope >&2; exit 2"]).unwrap_err().ends_with("(exit code 2): nope"));
    }
}
