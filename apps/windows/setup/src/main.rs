//! CabooseSetup.exe: installs Caboose on Windows, upgrades it when run again, and uninstalls
//! it. See apps/windows/README.md for what it does and why.
//!
//! ```text
//! CabooseSetup.exe                     install, or upgrade and repair an install
//!   --yes                              accept the recommended answers and show no dialogs
//!                                      but progress; failures go to the exit code and setup.log
//!   --distro <file> [--sha256 <hex>]   install this rootfs instead of downloading one
//!   --release <tag>                    install from this release instead of the newest
//!   --resume                           continue after the restart WSL's installation needed
//! CabooseSetup.exe --uninstall [--yes] [--delete-data]
//! ```
//!
//! It runs as the signed-in user, because WSL distributions belong to a user. The few steps
//! that need an administrator (installing WSL, firewall rules, the startup task, port
//! forwarding) run in a second copy of itself, started elevated with `--elevated`.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod download;
#[cfg(windows)]
mod elevated;
#[cfg(windows)]
mod install;
#[cfg(windows)]
mod shell;
#[cfg(windows)]
mod ui;
#[cfg(windows)]
mod uninstall;
#[cfg(windows)]
mod wslctl;

#[cfg(windows)]
mod embedded {
    include!(concat!(env!("OUT_DIR"), "/embedded.rs"));
}

/// Command-line options.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Options {
    pub uninstall: bool,
    pub yes: bool,
    pub resume: bool,
    pub delete_data: bool,
    pub distro: Option<String>,
    pub sha256: Option<String>,
    pub release: Option<String>,
    /// `--elevated <action> <arguments…>`: the administrator half (see `elevated`).
    pub elevated: Option<Vec<String>>,
}

pub fn parse_options(arguments: &[String]) -> Result<Options, String> {
    let mut options = Options::default();
    let mut rest = arguments.iter();
    while let Some(argument) = rest.next() {
        let mut value = |name: &str| rest.next().cloned().ok_or_else(|| format!("{name} needs a value"));
        match argument.as_str() {
            "--uninstall" => options.uninstall = true,
            "--yes" => options.yes = true,
            "--resume" => options.resume = true,
            "--delete-data" => options.delete_data = true,
            "--distro" => options.distro = Some(value("--distro")?),
            "--sha256" => options.sha256 = Some(value("--sha256")?),
            "--release" => options.release = Some(value("--release")?),
            "--elevated" => {
                options.elevated = Some(rest.cloned().collect());
                break;
            }
            other => return Err(format!("Unknown option {other}")),
        }
    }
    Ok(options)
}

#[cfg(windows)]
fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let code = match parse_options(&arguments) {
        Err(error) => {
            ui::error("CabooseSetup cannot start", &error);
            2
        }
        Ok(Options { elevated: Some(action), .. }) => elevated::main(&action),
        Ok(options) if options.uninstall => uninstall::run(&options),
        Ok(options) => install::run(&options),
    };
    std::process::exit(code);
}

#[cfg(not(windows))]
fn main() {
    let _ = parse_options(&std::env::args().skip(1).collect::<Vec<_>>());
    eprintln!("CabooseSetup installs Caboose on Windows and runs only there.");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(arguments: &[&str]) -> Result<Options, String> {
        parse_options(&arguments.iter().map(|argument| argument.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn parses_the_command_line() {
        assert_eq!(parse(&[]).unwrap(), Options::default());
        let options = parse(&["--yes", "--distro", r"C:\x.tar.gz", "--sha256", "ab"]).unwrap();
        assert!(options.yes);
        assert_eq!(options.distro.as_deref(), Some(r"C:\x.tar.gz"));
        assert_eq!(options.sha256.as_deref(), Some("ab"));
        let elevated = parse(&["--elevated", "configure", "--yes"]).unwrap();
        assert_eq!(elevated.elevated, Some(vec!["configure".to_string(), "--yes".to_string()]));
        assert!(!elevated.yes);
        assert!(parse(&["--distro"]).is_err());
        assert!(parse(&["--frobnicate"]).is_err());
    }
}
