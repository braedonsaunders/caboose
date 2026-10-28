//! Choosing the distribution from GitHub's releases, and checking what was downloaded.

use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::io::{self, Write};

/// A release as `GET /repos/:owner/:repo/releases` lists it.
#[derive(Debug, Clone, Deserialize)]
pub struct Release {
    pub tag_name: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Asset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
    /// `sha256:<hex>`, which GitHub computes for assets uploaded since mid-2025.
    #[serde(default)]
    pub digest: Option<String>,
}

/// The release to install from and its files.
#[derive(Debug, Clone)]
pub struct Selected {
    pub tag: String,
    pub archive: Asset,
    /// `<archive>.sha256`, when the release has it.
    pub checksum: Option<Asset>,
}

/// The newest release that has `asset` and a way to verify it, or the one tagged `tag`.
/// Stable releases win over pre-releases; drafts are never used. GitHub lists releases newest
/// first, and that order is kept.
pub fn select(releases: &[Release], asset: &str, tag: Option<&str>) -> Result<Selected, String> {
    let checksum_name = format!("{asset}.sha256");
    let usable = |release: &&Release| !release.draft && release.assets.iter().any(|a| a.name == asset);
    let release = match tag {
        Some(tag) => releases
            .iter()
            .filter(usable)
            .find(|release| release.tag_name == tag)
            .ok_or_else(|| format!("Release {tag} has no {asset}."))?,
        None => releases
            .iter()
            .filter(usable)
            .find(|release| !release.prerelease)
            .or_else(|| releases.iter().filter(usable).next())
            .ok_or_else(|| format!("No published Caboose release has {asset} yet."))?,
    };
    let archive = release.assets.iter().find(|a| a.name == asset).cloned().expect("filtered on it");
    let checksum = release.assets.iter().find(|a| a.name == checksum_name).cloned();
    if checksum.is_none() && archive.digest.as_deref().and_then(digest_hex).is_none() {
        return Err(format!("Release {} has no checksum for {asset}, so it cannot be verified.", release.tag_name));
    }
    Ok(Selected { tag: release.tag_name.clone(), archive, checksum })
}

/// The SHA-256 the archive must have: from its `.sha256` file and GitHub's digest, which must
/// agree when both exist.
pub fn expected_sha256(selected: &Selected, checksum_file: Option<&str>) -> Result<String, String> {
    let from_file = match checksum_file {
        Some(text) => Some(
            parse_checksum_file(text, &selected.archive.name)
                .ok_or_else(|| format!("{}.sha256 does not list a SHA-256 for it.", selected.archive.name))?,
        ),
        None => None,
    };
    let from_github = selected.archive.digest.as_deref().and_then(digest_hex);
    match (from_file, from_github) {
        (Some(a), Some(b)) if a != b => {
            Err(format!("{}.sha256 and GitHub disagree about its SHA-256.", selected.archive.name))
        }
        (Some(hex), _) | (None, Some(hex)) => Ok(hex),
        (None, None) => Err(format!("There is no SHA-256 to check {} against.", selected.archive.name)),
    }
}

/// The hex digest in `sha256:<hex>`.
fn digest_hex(digest: &str) -> Option<String> {
    digest.strip_prefix("sha256:").and_then(normalize_hex)
}

fn normalize_hex(text: &str) -> Option<String> {
    let text = text.trim().to_ascii_lowercase();
    (text.len() == 64 && text.chars().all(|c| c.is_ascii_hexdigit())).then_some(text)
}

/// The digest for `name` in a `sha256sum`-style file (`<hex>  <name>` or `<hex> *<name>`), or
/// the only digest in a file that holds just one.
pub fn parse_checksum_file(text: &str, name: &str) -> Option<String> {
    let entries: Vec<(String, Option<&str>)> = text
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let hex = normalize_hex(parts.next()?)?;
            Some((hex, parts.next().map(|file| file.trim_start_matches('*'))))
        })
        .collect();
    if let Some((hex, _)) = entries.iter().find(|(_, file)| *file == Some(name)) {
        return Some(hex.clone());
    }
    match entries.as_slice() {
        [(hex, None)] => Some(hex.clone()),
        _ => None,
    }
}

/// Fails unless `actual` is the `expected` digest.
pub fn verify(actual: &str, expected: &str) -> Result<(), String> {
    if actual.eq_ignore_ascii_case(expected) {
        Ok(())
    } else {
        Err(format!("The download is damaged or was tampered with: its SHA-256 is {actual}, not {expected}."))
    }
}

/// A writer that hashes everything written through it.
pub struct HashingWriter<W> {
    inner: W,
    hasher: Sha256,
    pub written: u64,
}

impl<W: Write> HashingWriter<W> {
    pub fn new(inner: W) -> Self {
        HashingWriter { inner, hasher: Sha256::new(), written: 0 }
    }

    /// The SHA-256 of everything written, as lowercase hex, and the inner writer.
    pub fn finish(mut self) -> io::Result<(String, W)> {
        self.inner.flush()?;
        Ok((hex(&self.hasher.finalize()), self.inner))
    }
}

impl<W: Write> Write for HashingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let count = self.inner.write(buf)?;
        self.hasher.update(&buf[..count]);
        self.written += count as u64;
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// The SHA-256 of a whole reader, as lowercase hex.
pub fn sha256_of(mut reader: impl io::Read) -> io::Result<String> {
    let mut writer = HashingWriter::new(io::sink());
    io::copy(&mut reader, &mut writer)?;
    Ok(writer.finish()?.0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    fn asset(name: &str) -> Asset {
        Asset { name: name.into(), browser_download_url: format!("https://example.com/{name}"), size: 1, digest: None }
    }

    fn release(tag: &str, prerelease: bool, names: &[&str]) -> Release {
        Release {
            tag_name: tag.into(),
            draft: false,
            prerelease,
            assets: names.iter().map(|name| asset(name)).collect(),
        }
    }

    const TAR: &str = "caboose-wsl-amd64.tar.gz";
    const SUM: &str = "caboose-wsl-amd64.tar.gz.sha256";

    #[test]
    fn parses_the_github_api() {
        let json = r#"[{"tag_name":"v0.3.0","draft":false,"prerelease":false,"assets":[{"name":"caboose-wsl-amd64.tar.gz","browser_download_url":"https://github.com/x","size":12,"digest":"sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","content_type":"application/gzip"}],"body":"notes"}]"#;
        let releases: Vec<Release> = serde_json::from_str(json).unwrap();
        let selected = select(&releases, TAR, None).unwrap();
        assert_eq!(selected.tag, "v0.3.0");
        assert_eq!(expected_sha256(&selected, None).unwrap(), HASH);
    }

    #[test]
    fn prefers_the_newest_stable_release_with_the_asset() {
        let releases = vec![
            release("v0.4.0-rc.1", true, &[TAR, SUM]),
            release("v0.3.1", false, &["CabooseSetup.exe"]),
            release("v0.3.0", false, &[TAR, SUM]),
            release("v0.2.0", false, &[TAR, SUM]),
        ];
        assert_eq!(select(&releases, TAR, None).unwrap().tag, "v0.3.0");
    }

    #[test]
    fn falls_back_to_a_prerelease_and_never_a_draft() {
        let mut draft = release("v0.5.0", false, &[TAR, SUM]);
        draft.draft = true;
        let releases = vec![draft, release("v0.4.0-rc.1", true, &[TAR, SUM])];
        assert_eq!(select(&releases, TAR, None).unwrap().tag, "v0.4.0-rc.1");
        assert!(select(&[], TAR, None).is_err());
    }

    #[test]
    fn picks_a_named_release() {
        let releases = vec![release("v0.3.0", false, &[TAR, SUM]), release("v0.2.0", false, &[TAR, SUM])];
        assert_eq!(select(&releases, TAR, Some("v0.2.0")).unwrap().tag, "v0.2.0");
        assert!(select(&releases, TAR, Some("v9")).is_err());
    }

    #[test]
    fn refuses_a_release_it_cannot_verify() {
        let releases = vec![release("v0.3.0", false, &[TAR])];
        assert!(select(&releases, TAR, None).unwrap_err().contains("cannot be verified"));
    }

    #[test]
    fn reads_checksum_files() {
        assert_eq!(parse_checksum_file(&format!("{HASH}  {TAR}\n"), TAR).as_deref(), Some(HASH));
        assert_eq!(parse_checksum_file(&format!("{} *{TAR}\r\n", HASH.to_uppercase()), TAR).as_deref(), Some(HASH));
        assert_eq!(parse_checksum_file(&format!("{HASH}\n"), TAR).as_deref(), Some(HASH));
        assert_eq!(parse_checksum_file(&format!("{HASH}  other.tar.gz\n"), TAR), None);
        assert_eq!(parse_checksum_file("not a hash  caboose-wsl-amd64.tar.gz", TAR), None);
    }

    #[test]
    fn requires_the_checksum_file_and_github_to_agree() {
        let mut selected = select(&[release("v1", false, &[TAR, SUM])], TAR, None).unwrap();
        let file = format!("{HASH}  {TAR}\n");
        assert_eq!(expected_sha256(&selected, Some(&file)).unwrap(), HASH);
        selected.archive.digest = Some(format!("sha256:{}", "0".repeat(64)));
        assert!(expected_sha256(&selected, Some(&file)).unwrap_err().contains("disagree"));
        selected.archive.digest = None;
        assert!(expected_sha256(&selected, None).is_err());
        assert!(expected_sha256(&selected, Some("garbage")).is_err());
    }

    #[test]
    fn hashes_and_verifies() {
        let mut writer = HashingWriter::new(Vec::new());
        writer.write_all(b"te").unwrap();
        writer.write_all(b"st").unwrap();
        assert_eq!(writer.written, 4);
        let (digest, bytes) = writer.finish().unwrap();
        assert_eq!(digest, HASH);
        assert_eq!(bytes, b"test");
        assert_eq!(sha256_of(&b"test"[..]).unwrap(), HASH);
        assert!(verify(HASH, &HASH.to_uppercase()).is_ok());
        assert!(verify(HASH, &"0".repeat(64)).is_err());
    }
}
