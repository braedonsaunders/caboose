use caboose_windows::{run, wsl};
use std::time::Duration;
fn main() {
    if let Err(error) = execute() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
fn execute() -> Result<(), String> {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "status".into());
    match mode.as_str() {
        "run-keepalive" => {
            let script = std::env::current_exe()
                .map_err(|e| e.to_string())?
                .parent()
                .unwrap()
                .join("start-wsl.ps1");
            // The scheduled task owns this supervisor and its unbounded keepalive child.
            let status = std::process::Command::new("powershell.exe")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                ])
                .arg(script)
                .args(["-Distro", "Caboose", "-Service", "docker,caboose-host"])
                .status()
                .map_err(|e| e.to_string())?;
            if status.success() {
                Ok(())
            } else {
                Err("WSL keepalive failed; see ProgramData/Caboose/start-wsl.log".into())
            }
        }
        "start" => {
            run(
                "schtasks.exe",
                &["/Run", "/TN", "Caboose-Start"],
                Duration::from_secs(30),
            )?;
            Ok(())
        }
        "stop" => {
            run(
                "schtasks.exe",
                &["/End", "/TN", "Caboose-Start"],
                Duration::from_secs(30),
            )?;
            wsl(&["systemctl", "stop", "caboose-host"])?;
            Ok(())
        }
        "status" => {
            println!("{}", wsl(&["systemctl", "is-active", "caboose-host"])?);
            Ok(())
        }
        _ => Err("Usage: caboose-agent [status|start|stop|run-keepalive]".into()),
    }
}
