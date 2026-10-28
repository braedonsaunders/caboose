//! Which Windows and which WSL this is, and what they can do.

use std::fmt;

/// Windows 10 22H2, the oldest Windows Caboose supports.
pub const MIN_BUILD: u32 = 19045;
/// Windows 11 22H2, the first with WSL's mirrored networking.
pub const MIRRORED_BUILD: u32 = 22621;
/// Windows 11 starts at this build; it still reports itself as version 10.0.
const WINDOWS_11_BUILD: u32 = 22000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowsBuild {
    pub major: u32,
    pub minor: u32,
    pub build: u32,
}

impl WindowsBuild {
    /// Windows 10 22H2 or later.
    pub fn is_supported(&self) -> bool {
        self.major > 10 || (self.major == 10 && self.build >= MIN_BUILD)
    }

    /// Whether WSL can mirror Windows' network interfaces (Windows 11 22H2, build 22621, or later).
    pub fn supports_mirrored(&self) -> bool {
        self.major > 10 || (self.major == 10 && self.build >= MIRRORED_BUILD)
    }
}

impl fmt::Display for WindowsBuild {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = if self.major == 10 && self.build >= WINDOWS_11_BUILD { "Windows 11" } else { "Windows 10" };
        if self.major > 10 {
            write!(f, "Windows {}.{} (build {})", self.major, self.minor, self.build)
        } else {
            write!(f, "{name} (build {})", self.build)
        }
    }
}

/// A dotted version such as WSL's `2.3.26.0`, compared by its first three parts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(pub u32, pub u32, pub u32);

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

/// WSL 2.0.0 introduced mirrored networking and the Hyper-V firewall settings.
pub const WSL_MIRRORED: Version = Version(2, 0, 0);

/// WSL's version from the first line of `wsl --version` (`WSL version: 2.3.26.0`, translated
/// in other languages), or `None` when the output has none, as with the WSL built into older
/// Windows, which does not know `--version`.
pub fn parse_wsl_version(output: &str) -> Option<Version> {
    let line = output.lines().find(|line| !line.trim().is_empty())?;
    line.split(|c: char| !(c.is_ascii_digit() || c == '.')).find_map(|token| {
        let parts: Vec<u32> = token.split('.').map_while(|part| part.parse().ok()).collect();
        (parts.len() >= 3 && token.split('.').count() == parts.len()).then(|| Version(parts[0], parts[1], parts[2]))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(build: u32) -> WindowsBuild {
        WindowsBuild { major: 10, minor: 0, build }
    }

    #[test]
    fn supports_windows_10_22h2_and_later() {
        assert!(!build(19044).is_supported());
        assert!(build(19045).is_supported());
        assert!(build(22631).is_supported());
        assert!(build(26100).is_supported());
    }

    #[test]
    fn mirrored_networking_needs_windows_11_22h2() {
        assert!(!build(19045).supports_mirrored());
        assert!(!build(22000).supports_mirrored());
        assert!(build(22621).supports_mirrored());
        assert!(build(26100).supports_mirrored());
    }

    #[test]
    fn names_windows_10_and_11() {
        assert_eq!(build(19045).to_string(), "Windows 10 (build 19045)");
        assert_eq!(build(26100).to_string(), "Windows 11 (build 26100)");
    }

    #[test]
    fn parses_wsl_versions() {
        let english = "WSL version: 2.3.26.0\nKernel version: 5.15.167.4-1\nWSLg version: 1.0.65\n";
        assert_eq!(parse_wsl_version(english), Some(Version(2, 3, 26)));
        assert_eq!(parse_wsl_version("WSL-Version: 2.0.14.0\r\nKernelversion: 5.15.133.1-1"), Some(Version(2, 0, 14)));
        assert_eq!(parse_wsl_version("Version de WSL : 1.2.5.0"), Some(Version(1, 2, 5)));
        assert_eq!(parse_wsl_version("Invalid command line option: --version"), None);
        assert_eq!(parse_wsl_version(""), None);
        assert!(Version(2, 0, 0) >= WSL_MIRRORED && Version(1, 2, 5) < WSL_MIRRORED);
    }
}
