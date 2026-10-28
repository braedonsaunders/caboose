//! Where Caboose keeps its files on Windows, all under `%LOCALAPPDATA%\Caboose`, and what
//! setup records about the install.

use crate::status::Networking;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const SETUP_EXE: &str = "CabooseSetup.exe";
pub const SERVICE_EXE: &str = "caboose-service.exe";
pub const TRAY_EXE: &str = "caboose-tray.exe";
pub const ICON: &str = "caboose.ico";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    pub root: PathBuf,
}

impl Layout {
    /// `<LOCALAPPDATA>\Caboose`.
    pub fn new(local_app_data: impl AsRef<Path>) -> Layout {
        Layout { root: local_app_data.as_ref().join("Caboose") }
    }

    /// The programs: setup (which also uninstalls), the service, the tray and the icon.
    pub fn bin(&self) -> PathBuf {
        self.root.join("bin")
    }
    pub fn setup_exe(&self) -> PathBuf {
        self.bin().join(SETUP_EXE)
    }
    pub fn service_exe(&self) -> PathBuf {
        self.bin().join(SERVICE_EXE)
    }
    pub fn tray_exe(&self) -> PathBuf {
        self.bin().join(TRAY_EXE)
    }
    pub fn icon(&self) -> PathBuf {
        self.bin().join(ICON)
    }
    /// The distribution's virtual disk (`ext4.vhdx`), where `wsl --import` puts it.
    pub fn wsl(&self) -> PathBuf {
        self.root.join("wsl")
    }
    pub fn downloads(&self) -> PathBuf {
        self.root.join("downloads")
    }
    pub fn logs(&self) -> PathBuf {
        self.root.join("logs")
    }
    /// What setup recorded ([`InstallConfig`]).
    pub fn config(&self) -> PathBuf {
        self.root.join("config.json")
    }
    /// What caboose-service reports ([`crate::status::ServiceStatus`]).
    pub fn service_status(&self) -> PathBuf {
        self.root.join("service.json")
    }
}

/// What setup chose and changed, so the service knows how to forward the port and uninstall
/// can put things back.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallConfig {
    #[serde(default)]
    pub networking: Networking,
    /// The release the distribution was installed or last upgraded from.
    #[serde(default)]
    pub version: Option<String>,
    /// Whether setup turned on mirrored networking in `.wslconfig`.
    #[serde(default)]
    pub changed_wslconfig: bool,
    /// `[wsl2] networkingMode` before setup changed it; `None` when it was not set.
    #[serde(default)]
    pub previous_networking_mode: Option<String>,
}

impl InstallConfig {
    pub fn parse(text: &str) -> Result<InstallConfig, String> {
        serde_json::from_str(text).map_err(|error| format!("config.json is not valid: {error}"))
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("plain data") + "\n"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lays_out_the_install() {
        let layout = Layout::new("/home/ann/AppData/Local");
        assert_eq!(layout.service_exe(), Path::new("/home/ann/AppData/Local/Caboose/bin/caboose-service.exe"));
        assert_eq!(layout.wsl(), Path::new("/home/ann/AppData/Local/Caboose/wsl"));
        assert_eq!(layout.config(), Path::new("/home/ann/AppData/Local/Caboose/config.json"));
    }

    #[test]
    fn round_trips_the_install_config() {
        let config = InstallConfig {
            networking: Networking::Mirrored,
            version: Some("v0.3.0".into()),
            changed_wslconfig: true,
            previous_networking_mode: Some("nat".into()),
        };
        assert_eq!(InstallConfig::parse(&config.to_json()).unwrap(), config);
        assert_eq!(InstallConfig::parse("{}").unwrap(), InstallConfig::default());
        assert!(InstallConfig::parse("{").is_err());
    }
}
