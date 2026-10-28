//! Talking to `wsl.exe`: its output, the distributions it lists, and paths and addresses in
//! the Caboose distribution.

use std::net::Ipv4Addr;

/// `wsl.exe`'s output as text. Its own messages are UTF-16 little-endian unless `WSL_UTF8=1`
/// is set (older WSL ignores that), while a Linux program's output passes through as UTF-8;
/// this tells them apart by the NUL bytes UTF-16 puts in ASCII text.
pub fn decode_output(bytes: &[u8]) -> String {
    let bytes = bytes.strip_prefix(&[0xFF, 0xFE]).unwrap_or(bytes);
    let pairs = bytes.len() / 2;
    let odd_nuls = bytes.iter().skip(1).step_by(2).filter(|&&byte| byte == 0).count();
    if pairs > 0 && odd_nuls * 2 >= pairs {
        let units: Vec<u16> = bytes.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
        return String::from_utf16_lossy(&units);
    }
    String::from_utf8_lossy(bytes).into_owned()
}

/// The names in `wsl --list --quiet`.
pub fn parse_distributions(output: &str) -> Vec<String> {
    output.lines().map(|line| line.trim().trim_matches('\0').to_string()).filter(|line| !line.is_empty()).collect()
}

/// Whether `wsl --list --quiet` lists `name` (WSL compares names without regard to case).
pub fn has_distribution(output: &str, name: &str) -> bool {
    parse_distributions(output).iter().any(|listed| listed.eq_ignore_ascii_case(name))
}

/// The address in `ip -4 -o addr show dev eth0`
/// (`2: eth0    inet 172.22.48.10/20 brd 172.22.63.255 scope global eth0 …`).
pub fn parse_ipv4(output: &str) -> Option<Ipv4Addr> {
    output.lines().find_map(|line| {
        let mut words = line.split_whitespace();
        words.find(|&word| word == "inet")?;
        words.next()?.split('/').next()?.parse().ok()
    })
}

/// A Windows path as the distribution sees it under `/mnt` (WSL's default automount root,
/// which the Caboose distribution keeps). `None` for paths not on a drive letter.
pub fn to_linux_path(windows_path: &str) -> Option<String> {
    let path = windows_path.strip_prefix(r"\\?\").unwrap_or(windows_path);
    let mut chars = path.chars();
    let drive = chars.next().filter(char::is_ascii_alphabetic)?;
    if chars.next() != Some(':') {
        return None;
    }
    let rest: String = chars.as_str().replace('\\', "/");
    Some(format!("/mnt/{}/{}", drive.to_ascii_lowercase(), rest.trim_start_matches('/')))
}

/// `wsl.exe` arguments that run `program` as root in the Caboose distribution, without a shell.
pub fn exec_as_root<'a>(program: &'a str, arguments: &[&'a str]) -> Vec<String> {
    ["-d", crate::DISTRO, "-u", "root", "--exec", program]
        .iter()
        .chain(arguments)
        .map(|part| part.to_string())
        .collect()
}

/// Whether `wsl --status` says WSL itself is missing or cannot run: it fails (older Windows
/// prints its usage), or says WSL or the Virtual Machine Platform is not installed. Any of
/// these means `wsl --install` is needed.
pub fn status_needs_install(exit_code: Option<i32>, output: &str) -> bool {
    let lower = output.to_ascii_lowercase();
    exit_code != Some(0) || lower.contains("not installed") || lower.contains("virtual machine platform")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(text: &str) -> Vec<u8> {
        text.encode_utf16().flat_map(u16::to_le_bytes).collect()
    }

    #[test]
    fn decodes_both_kinds_of_output() {
        assert_eq!(decode_output(&utf16("Ubuntu-24.04\r\nCaboose\r\n")), "Ubuntu-24.04\r\nCaboose\r\n");
        let with_bom: Vec<u8> = [0xFF, 0xFE].into_iter().chain(utf16("Caboose")).collect();
        assert_eq!(decode_output(&with_bom), "Caboose");
        assert_eq!(decode_output(b"{\"healthy\":true}\n"), "{\"healthy\":true}\n");
        assert_eq!(decode_output("Grüße".as_bytes()), "Grüße");
        assert_eq!(decode_output(b""), "");
    }

    #[test]
    fn lists_distributions() {
        let listed = decode_output(&utf16("Ubuntu-24.04\r\ncaboose\r\n\r\n"));
        assert_eq!(parse_distributions(&listed), vec!["Ubuntu-24.04", "caboose"]);
        assert!(has_distribution(&listed, "Caboose"));
        assert!(!has_distribution("Ubuntu\n", "Caboose"));
    }

    #[test]
    fn reads_the_distribution_address() {
        let output = "2: eth0    inet 172.22.48.10/20 brd 172.22.63.255 scope global eth0\\       valid_lft forever preferred_lft forever\n";
        assert_eq!(parse_ipv4(output), Some(Ipv4Addr::new(172, 22, 48, 10)));
        assert_eq!(parse_ipv4("Device \"eth0\" does not exist."), None);
    }

    #[test]
    fn maps_windows_paths_into_the_distribution() {
        assert_eq!(
            to_linux_path(r"C:\Users\Ann\AppData\Local\Caboose\downloads\caboose-wsl-amd64.tar.gz").as_deref(),
            Some("/mnt/c/Users/Ann/AppData/Local/Caboose/downloads/caboose-wsl-amd64.tar.gz")
        );
        assert_eq!(to_linux_path(r"\\?\D:\x").as_deref(), Some("/mnt/d/x"));
        assert_eq!(to_linux_path(r"\\server\share\x"), None);
    }

    #[test]
    fn builds_root_commands() {
        assert_eq!(
            exec_as_root("/usr/local/bin/caboose-wsl-ready", &[]),
            vec!["-d", "Caboose", "-u", "root", "--exec", "/usr/local/bin/caboose-wsl-ready"]
        );
    }

    #[test]
    fn knows_when_wsl_must_be_installed() {
        assert!(status_needs_install(Some(1), "Usage: wsl.exe [Argument]"));
        assert!(status_needs_install(Some(0), "The Windows Subsystem for Linux is not installed. Run wsl --install."));
        assert!(!status_needs_install(Some(0), "Default Version: 2\n"));
        assert!(status_needs_install(None, ""));
    }
}
