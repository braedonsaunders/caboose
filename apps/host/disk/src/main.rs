//! caboose-disk: shared storage and backup manifests for Caboose microVM disks.
//!
//!   caboose-disk dedupe-serve --state <dir>
//!       Keep the dedupe index in memory and run passes requested as JSON lines on stdin.
//!   caboose-disk manifest --image <path> [--base <path> --cache <dir>] [--chunk-bytes <n>]
//!       Print a backup manifest of an immutable disk image.
//!   caboose-disk base-hash --base <path> --cache <dir> [--chunk-bytes <n>]
//!       Print the SHA-256 and size of a base image (cached with its chunk map).
//!   caboose-disk punch <path>
//!       Deallocate the `offset length` ranges read from stdin (each must read as zeros).
//!   caboose-disk discard <path>
//!       Deallocate the ranges read from stdin whatever they hold (a restore's staging disk).
//!
//! See apps/host/disk/README.md.

#![cfg_attr(not(target_os = "linux"), allow(dead_code, unused_imports))]

mod dedupe;
mod manifest;
mod persist;
mod volume;

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!("usage: caboose-disk dedupe-serve --state <dir>\n       caboose-disk manifest --image <path> [--base <path> --cache <dir>] [--chunk-bytes <n>]\n       caboose-disk base-hash --base <path> --cache <dir> [--chunk-bytes <n>]\n       caboose-disk punch|discard <path>");
    ExitCode::from(2)
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|pair| pair[0] == name).map(|pair| pair[1].clone())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("dedupe-serve") => match flag(&args, "--state") {
            Some(state) => serve(Path::new(&state)),
            None => return usage(),
        },
        Some("manifest") => match flag(&args, "--image") {
            Some(image) => print_manifest(&image, flag(&args, "--base"), flag(&args, "--cache"), flag(&args, "--chunk-bytes")),
            None => return usage(),
        },
        Some("base-hash") => match (flag(&args, "--base"), flag(&args, "--cache")) {
            (Some(base), Some(cache)) => print_base_hash(&base, &cache, flag(&args, "--chunk-bytes")),
            _ => return usage(),
        },
        Some("punch") if args.len() == 2 => punch(Path::new(&args[1]), true),
        Some("discard") if args.len() == 2 => punch(Path::new(&args[1]), false),
        Some("--version") => {
            println!("caboose-disk {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        _ => return usage(),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("caboose-disk: {error}");
            ExitCode::FAILURE
        }
    }
}

fn chunk_bytes(value: Option<String>) -> io::Result<u64> {
    match value {
        Some(value) => value.parse::<u64>().ok().filter(|n| n.is_power_of_two() && *n >= volume::BLOCK && *n <= 64 << 20).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "--chunk-bytes must be a power of two from 4096 to 64 MiB")),
        None => Ok(manifest::DEFAULT_CHUNK_BYTES),
    }
}

#[cfg(target_os = "linux")]
fn print_base_hash(base: &str, cache: &str, chunk: Option<String>) -> io::Result<()> {
    use volume::{OpenMode, Volume};
    let chunk_bytes = chunk_bytes(chunk)?;
    let mut volume = volume::LinuxVolume::new();
    let file = volume.open(Path::new(base), OpenMode::Inspect)?;
    let map = manifest::cached_base_map(&volume, file, chunk_bytes, Path::new(cache), &|| false)?;
    println!("{{\"sha256\":\"{}\",\"size\":{}}}", manifest::hex(&map.sha256), map.size);
    Ok(())
}

#[cfg(target_os = "linux")]
fn print_manifest(image: &str, base: Option<String>, cache: Option<String>, chunk: Option<String>) -> io::Result<()> {
    use volume::{OpenMode, Volume};
    let chunk_bytes = chunk_bytes(chunk)?;
    let never = || false;
    let mut volume = volume::LinuxVolume::new();
    let image = volume.open(Path::new(image), OpenMode::Inspect)?;
    let base = match base {
        Some(path) => {
            let cache = cache.ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "--base needs --cache"))?;
            let file = volume.open(Path::new(&path), OpenMode::Inspect)?;
            Some((file, manifest::cached_base_map(&volume, file, chunk_bytes, Path::new(&cache), &never)?))
        }
        None => None,
    };
    let result = manifest::manifest(&volume, image, base.as_ref().map(|(file, map)| (*file, map)), chunk_bytes, &never)?;
    let mut out = io::stdout().lock();
    out.write_all(manifest::to_json(&result).as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()
}

/// Deallocate ranges read from stdin. With `verify`, a range that holds data is refused.
#[cfg(target_os = "linux")]
fn punch(path: &Path, verify: bool) -> io::Result<()> {
    use volume::{OpenMode, Volume};
    let mut volume = volume::LinuxVolume::new();
    let file = volume.open(path, OpenMode::Sibling)?;
    let size = volume.identity(file)?.size;
    let invalid = |message: &str| io::Error::new(io::ErrorKind::InvalidInput, message.to_string());
    let mut buffer = vec![0u8; 1 << 20];
    for line in io::stdin().lock().lines() {
        let line = line?;
        let mut parts = line.split_whitespace().map(str::parse::<u64>);
        let (Some(Ok(offset)), Some(Ok(length)), None) = (parts.next(), parts.next(), parts.next()) else { return Err(invalid("each line must be `offset length`")) };
        let end = offset.checked_add(length).filter(|end| *end <= size).ok_or_else(|| invalid("range beyond the end of the file"))?;
        if offset % volume::BLOCK != 0 || (length % volume::BLOCK != 0 && end != size) || length == 0 {
            return Err(invalid("ranges must be block-aligned"));
        }
        // Unless discarding, never deallocate data: the caller states these ranges are zeros; prove it.
        let mut at = if verify { offset } else { end };
        while at < end {
            let count = ((end - at) as usize).min(buffer.len());
            volume.read_at(file, at, &mut buffer[..count])?;
            if buffer[..count].iter().any(|b| *b != 0) {
                return Err(invalid("range holds data"));
            }
            at += count as u64;
        }
        volume.punch(file, offset, length)?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn serve(state: &Path) -> io::Result<()> {
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{mpsc, Arc};

    let mut store = persist::FileStore::open(state)?;
    let mut index = dedupe::Index::new();
    for record in store.load_all()? {
        index.insert(record);
    }
    let settings = dedupe::Settings::default();
    // The id of the run to cancel; u64::MAX cancels everything (stdin closed).
    let cancelled = Arc::new(AtomicU64::new(0));
    let (sender, receiver) = mpsc::channel::<Value>();
    {
        let cancelled = cancelled.clone();
        std::thread::spawn(move || {
            for line in io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                let Ok(command) = serde_json::from_str::<Value>(&line) else { continue };
                if command["op"] == "cancel" {
                    if let Some(id) = command["id"].as_u64() {
                        cancelled.store(id, Ordering::SeqCst);
                    }
                } else if sender.send(command).is_err() {
                    break;
                }
            }
            cancelled.store(u64::MAX, Ordering::SeqCst);
        });
    }
    let mut out = io::stdout();
    writeln!(out, "{}", json!({ "ready": true, "indexed": index.len() }))?;
    for command in receiver {
        let id = command["id"].as_u64().unwrap_or(0);
        let reply = match command["op"].as_str() {
            Some("run") => match parse_job(&command) {
                Ok(job) => {
                    let mut volume = volume::LinuxVolume::new();
                    let is_cancelled = || {
                        let value = cancelled.load(Ordering::SeqCst);
                        value == id || value == u64::MAX
                    };
                    match dedupe::run(&mut volume, &mut index, &mut store, &job, &settings, &is_cancelled) {
                        Ok(report) => json!({ "id": id, "ok": true, "report": report }),
                        Err(dedupe::RunError::Cancelled(report)) => json!({ "id": id, "ok": false, "error": "cancelled", "report": report }),
                        Err(error) => {
                            let kind = match error {
                                dedupe::RunError::Busy => "busy",
                                dedupe::RunError::Missing => "missing",
                                dedupe::RunError::Unsupported(_) => "unsupported",
                                _ => "io",
                            };
                            json!({ "id": id, "ok": false, "error": kind, "message": error.to_string() })
                        }
                    }
                }
                Err(message) => json!({ "id": id, "ok": false, "error": "invalid", "message": message }),
            },
            Some("forget") => match command["key"].as_str().filter(|key| persist::valid_key(key)) {
                Some(key) => {
                    index.remove(key);
                    use dedupe::RecordStore;
                    match store.delete(key) {
                        Ok(()) => json!({ "id": id, "ok": true }),
                        Err(error) => json!({ "id": id, "ok": false, "error": "io", "message": error.to_string() }),
                    }
                }
                None => json!({ "id": id, "ok": false, "error": "invalid", "message": "invalid key" }),
            },
            _ => json!({ "id": id, "ok": false, "error": "invalid", "message": "unknown op" }),
        };
        writeln!(out, "{reply}")?;
        out.flush()?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn parse_job(command: &serde_json::Value) -> Result<dedupe::Job, String> {
    let key = command["key"].as_str().filter(|key| persist::valid_key(key)).ok_or("invalid key")?;
    let path = |value: &serde_json::Value| -> Result<PathBuf, String> {
        let text = value.as_str().ok_or("paths must be strings")?;
        let path = PathBuf::from(text);
        if !path.is_absolute() || text.contains('\0') {
            return Err("paths must be absolute".into());
        }
        Ok(path)
    };
    let files = command["files"].as_array().ok_or("files is required")?.iter().map(path).collect::<Result<Vec<_>, _>>()?;
    if files.is_empty() || files.len() > 8 {
        return Err("files must list the disk and at most seven clones".into());
    }
    let mut sources = Vec::new();
    for source in command["sources"].as_array().map(Vec::as_slice).unwrap_or(&[]) {
        let key = source["key"].as_str().filter(|key| persist::valid_key(key)).ok_or("invalid source key")?;
        sources.push(dedupe::SourceSpec { key: key.into(), path: path(&source["path"])?, immutable: source["immutable"] == true });
    }
    let live = match command.get("live") {
        Some(serde_json::Value::Array(keys)) => Some(keys.iter().map(|key| key.as_str().filter(|key| persist::valid_key(key)).map(String::from).ok_or("invalid live key")).collect::<Result<Vec<_>, _>>()?),
        Some(serde_json::Value::Null) | None => None,
        Some(_) => return Err("live must be a list".into()),
    };
    Ok(dedupe::Job { key: key.into(), files, sources, live })
}

#[cfg(not(target_os = "linux"))]
fn linux_only() -> io::Result<()> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "caboose-disk requires Linux (FIEMAP and FIDEDUPERANGE)"))
}

#[cfg(not(target_os = "linux"))]
fn serve(_: &Path) -> io::Result<()> {
    linux_only()
}

#[cfg(not(target_os = "linux"))]
fn print_manifest(_: &str, _: Option<String>, _: Option<String>, _: Option<String>) -> io::Result<()> {
    linux_only()
}

#[cfg(not(target_os = "linux"))]
fn punch(_: &Path, _: bool) -> io::Result<()> {
    linux_only()
}

#[cfg(not(target_os = "linux"))]
fn print_base_hash(_: &str, _: &str, _: Option<String>) -> io::Result<()> {
    linux_only()
}
