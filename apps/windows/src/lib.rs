use std::{
    io::Read,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub const VERSION: &str = match option_env!("CABOOSE_VERSION") {
    Some(v) => v,
    None => "development",
};
pub const NETWORK: &str = include_str!("../../../deploy/windows/setup-wsl.ps1");
pub const START: &str = include_str!("../../../deploy/windows/start-wsl.ps1");
pub const INSTALL: &str = include_str!("../../../deploy/windows/install.ps1");
pub const LINUX_INSTALL: &str = include_str!("../../../deploy/linux/install.sh");

// stdout and stderr are drained concurrently; only a bounded suffix is retained.
pub fn run(program: &str, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .env("WSL_UTF8", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000);
    }
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    fn drain(mut reader: impl Read + Send + 'static) -> std::thread::JoinHandle<Vec<u8>> {
        std::thread::spawn(move || {
            let mut tail = Vec::new();
            let mut bytes = [0; 4096];
            while let Ok(n) = reader.read(&mut bytes) {
                if n == 0 {
                    break;
                }
                tail.extend_from_slice(&bytes[..n]);
                if tail.len() > 65536 {
                    tail.drain(..tail.len() - 65536);
                }
            }
            tail
        })
    }
    let out = drain(child.stdout.take().unwrap());
    let err = drain(child.stderr.take().unwrap());
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                // Stop the owned tree, including PowerShell's native child commands.
                #[cfg(windows)]
                {
                    let _ = Command::new("taskkill.exe")
                        .args(["/PID", &child.id().to_string(), "/T", "/F"])
                        .output();
                }
                let _ = child.kill();
                let _ = child.wait();
                let _ = out.join();
                let _ = err.join();
                return Err(
                    "The operation timed out; retry when Windows and WSL are ready.".into(),
                );
            }
        }
    };
    let text = String::from_utf8_lossy(&out.join().unwrap_or_default()).replace('\0', "");
    let error = String::from_utf8_lossy(&err.join().unwrap_or_default()).replace('\0', "");
    if status.success() {
        Ok(text.trim().to_string())
    } else {
        Err(format!("{} {}", text.trim(), error.trim()))
    }
}
pub fn wsl(args: &[&str]) -> Result<String, String> {
    let mut fixed = vec!["-d", "Caboose", "-u", "root", "--exec"];
    fixed.extend(args);
    run("wsl.exe", &fixed, Duration::from_secs(180))
}
pub fn release_tag(tag: &str) -> bool {
    tag.starts_with('v')
        && tag.len() < 100
        && tag
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._+-".contains(&b))
}
pub fn pairing_link(addresses: &[String], code: &str) -> Result<String, String> {
    if code.len() != 8 || !code.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("Invalid pairing code".into());
    }
    let mut link = url::Url::parse("caboose://connect").unwrap();
    let mut count = 0;
    for address in addresses {
        let u = url::Url::parse(address).map_err(|_| "Invalid host address")?;
        if !matches!(u.scheme(), "http" | "https")
            || u.host_str().is_none()
            || !u.username().is_empty()
            || u.password().is_some()
        {
            continue;
        }
        let host = u.host_str().unwrap();
        if host == "localhost" || host == "::1" || host == "[::1]" || host.starts_with("127.") {
            continue;
        }
        link.query_pairs_mut()
            .append_pair(if count == 0 { "host" } else { "alt" }, address);
        count += 1;
    }
    if count == 0 {
        return Err(
            "No phone can reach this host. Check mirrored networking or enable Tailscale HTTPS."
                .into(),
        );
    }
    link.query_pairs_mut().append_pair("code", code);
    Ok(link.to_string())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_untrusted_tags() {
        assert!(release_tag("v1.2.0-rc.1"));
        for s in ["latest", "v../x", "v';shutdown", "v\n"] {
            assert!(!release_tag(s));
        }
    }
    #[test]
    fn phone_link_omits_loopback_and_escapes() {
        let link = pairing_link(
            &[
                "http://127.0.0.1:7310".into(),
                "https://pc.example.com".into(),
                "http://192.0.2.1:7310".into(),
            ],
            "ABCD2345",
        )
        .unwrap();
        let url = url::Url::parse(&link).unwrap();
        let pairs: Vec<_> = url.query_pairs().collect();
        assert_eq!(pairs[0].0, "host");
        assert_eq!(pairs[1].0, "alt");
        assert_eq!(pairs[2].1, "ABCD2345");
        assert!(pairing_link(&["http://localhost:7310".into()], "ABCD2345").is_err());
    }
    #[test]
    fn drains_large_output() {
        #[cfg(unix)]
        {
            assert_eq!(
                run(
                    "sh",
                    &["-c", "printf hello; head -c 100000 /dev/zero >&2"],
                    Duration::from_secs(5)
                )
                .unwrap(),
                "hello"
            );
        }
    }
    #[test]
    fn bounds_process_time() {
        #[cfg(unix)]
        {
            assert!(run("sleep", &["5"], Duration::from_millis(30)).is_err());
        }
    }
}
