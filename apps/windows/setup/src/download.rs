//! Fetching the distribution from GitHub Releases, checked against its SHA-256.

use crate::ui::Progress;
use caboose_win_core::release::{expected_sha256, select, sha256_of, verify, HashingWriter, Release, Selected};
use caboose_win_core::{DISTRO_ASSET, REPOSITORY};
use std::fs::File;
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

fn agent() -> Result<ureq::Agent, String> {
    let tls = native_tls::TlsConnector::new().map_err(|error| format!("Windows' TLS is unavailable: {error}"))?;
    Ok(ureq::AgentBuilder::new()
        .tls_connector(Arc::new(tls))
        .timeout_connect(Duration::from_secs(30))
        .timeout_read(Duration::from_secs(60))
        .user_agent(concat!("CabooseSetup/", env!("CARGO_PKG_VERSION")))
        .try_proxy_from_env(true)
        .build())
}

fn describe(error: ureq::Error) -> String {
    match error {
        ureq::Error::Status(403, _) | ureq::Error::Status(429, _) => {
            "GitHub is limiting requests from this network. Try again in an hour.".to_string()
        }
        ureq::Error::Status(code, response) => format!("GitHub answered HTTP {code} for {}.", response.get_url()),
        ureq::Error::Transport(transport) => format!("Could not reach GitHub: {transport}"),
    }
}

/// The release to install from: `tag`, or the newest that has the distribution.
pub fn choose_release(tag: Option<&str>) -> Result<Selected, String> {
    let url = format!("https://api.github.com/repos/{REPOSITORY}/releases?per_page=30");
    let releases: Vec<Release> = agent()?
        .get(&url)
        .set("Accept", "application/vnd.github+json")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .call()
        .map_err(describe)?
        .into_json()
        .map_err(|error| format!("GitHub's release list could not be read: {error}"))?;
    select(&releases, DISTRO_ASSET, tag)
}

/// Downloads the release's distribution into `directory`, or reuses a copy already there
/// with the right SHA-256 (after a restart, say), and returns its path.
pub fn fetch_distro(selected: &Selected, directory: &Path, progress: &Progress) -> Result<PathBuf, String> {
    let agent = agent()?;
    let checksum = match &selected.checksum {
        Some(asset) => {
            let mut text = String::new();
            agent
                .get(&asset.browser_download_url)
                .call()
                .map_err(describe)?
                .into_reader()
                .take(4096)
                .read_to_string(&mut text)
                .map_err(|error| format!("Could not read {}: {error}", asset.name))?;
            Some(text)
        }
        None => None,
    };
    let expected = expected_sha256(selected, checksum.as_deref())?;
    std::fs::create_dir_all(directory).map_err(|error| format!("Could not create {}: {error}", directory.display()))?;
    let target = directory.join(&selected.archive.name);

    if target.is_file() {
        progress.set("Checking the copy downloaded earlier…", None);
        let file = File::open(&target).map_err(|error| format!("Could not read {}: {error}", target.display()))?;
        if sha256_of(file).is_ok_and(|actual| actual == expected) {
            return Ok(target);
        }
    }

    let partial = target.with_extension("part");
    let response = agent.get(&selected.archive.browser_download_url).call().map_err(describe)?;
    let total = response
        .header("Content-Length")
        .and_then(|length| length.parse::<u64>().ok())
        .unwrap_or(selected.archive.size);
    let file = File::create(&partial).map_err(|error| format!("Could not write {}: {error}", partial.display()))?;
    let mut writer = HashingWriter::new(BufWriter::new(file));
    let mut reader = response.into_reader();
    let mut buffer = vec![0u8; 256 * 1024];
    let mut reported = 0;
    loop {
        if progress.cancelled() {
            drop(writer);
            let _ = std::fs::remove_file(&partial);
            return Err("Setup was cancelled.".to_string());
        }
        let count = reader.read(&mut buffer).map_err(|error| format!("The download stopped: {error}"))?;
        if count == 0 {
            break;
        }
        writer
            .write_all(&buffer[..count])
            .map_err(|error| format!("Could not write {}: {error}", partial.display()))?;
        if writer.written - reported >= 4 * 1024 * 1024 || writer.written == total {
            reported = writer.written;
            let percent = (total > 0).then(|| (writer.written.saturating_mul(100) / total) as u32);
            progress.set(
                format!(
                    "Downloading Caboose {} ({} of {} MB)…",
                    selected.tag,
                    writer.written / 1_048_576,
                    total.max(1) / 1_048_576
                ),
                percent,
            );
        }
    }
    let (actual, _) = writer.finish().map_err(|error| format!("Could not write {}: {error}", partial.display()))?;
    if let Err(error) = verify(&actual, &expected) {
        let _ = std::fs::remove_file(&partial);
        return Err(error);
    }
    let _ = std::fs::remove_file(&target);
    std::fs::rename(&partial, &target).map_err(|error| format!("Could not move the download into place: {error}"))?;
    Ok(target)
}

/// A rootfs given with `--distro`, checked against `--sha256` when that is given.
pub fn local_distro(path: &Path, sha256: Option<&str>, progress: &Progress) -> Result<PathBuf, String> {
    let file = File::open(path).map_err(|error| format!("Could not open {}: {error}", path.display()))?;
    if let Some(expected) = sha256 {
        progress.set(format!("Checking {}…", path.display()), None);
        let actual = sha256_of(file).map_err(|error| format!("Could not read {}: {error}", path.display()))?;
        verify(&actual, expected)?;
    }
    Ok(path.to_path_buf())
}
