//! Index records on disk: one file per indexed disk, written atomically, with a checksum
//! so a torn or foreign file is discarded and rebuilt rather than trusted.

use crate::dedupe::{Record, RecordStore};
use crate::volume::{Extent, Identity};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use xxhash_rust::xxh3::xxh3_64;

const MAGIC: &[u8; 8] = b"CBDKREC1";
/// Bounds that a record from this tool never exceeds, so a corrupt length cannot exhaust memory.
const MAX_STRING: u32 = 4096;
const MAX_ENTRIES: u64 = 1 << 32;

/// Keys name computers and base images: `computer:<id>` or `base:<sha256>`.
pub fn valid_key(key: &str) -> bool {
    (1..=160).contains(&key.len()) && key.bytes().all(|b| b.is_ascii_alphanumeric() || b":._-".contains(&b))
}

pub struct FileStore {
    directory: PathBuf,
}

impl FileStore {
    pub fn open(directory: &Path) -> io::Result<Self> {
        fs::create_dir_all(directory)?;
        Ok(FileStore { directory: directory.to_path_buf() })
    }

    fn path(&self, key: &str) -> PathBuf {
        let hex: String = key.bytes().map(|b| format!("{b:02x}")).collect();
        self.directory.join(format!("r-{hex}.rec"))
    }

    /// Every readable record. Unreadable ones are removed: the next pass rebuilds them.
    pub fn load_all(&self) -> io::Result<Vec<Record>> {
        let mut records = Vec::new();
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".tmp") {
                let _ = fs::remove_file(entry.path());
                continue;
            }
            if !name.starts_with("r-") || !name.ends_with(".rec") {
                continue;
            }
            match read(&entry.path()) {
                Ok(record) if self.path(&record.key) == entry.path() => records.push(record),
                _ => {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        Ok(records)
    }
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

impl RecordStore for FileStore {
    fn save(&mut self, record: &Record) -> io::Result<()> {
        let path = self.path(&record.key);
        let temporary = path.with_extension("tmp");
        let bytes = encode(record);
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &path)?;
        sync_directory(&self.directory)
    }

    fn delete(&mut self, key: &str) -> io::Result<()> {
        match fs::remove_file(self.path(key)) {
            Ok(()) => sync_directory(&self.directory),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }
}

fn put_string(out: &mut Vec<u8>, value: &str) {
    out.extend_from_slice(&(value.len() as u32).to_le_bytes());
    out.extend_from_slice(value.as_bytes());
}

pub fn encode(record: &Record) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + record.extents.len() * 32 + record.anchors.len() * 16);
    out.extend_from_slice(MAGIC);
    put_string(&mut out, &record.key);
    put_string(&mut out, &record.path.to_string_lossy());
    for value in [record.identity.dev, record.identity.ino, record.identity.size, record.identity.mtime_ns as u64] {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&(record.extents.len() as u64).to_le_bytes());
    for extent in &record.extents {
        for value in [extent.logical, extent.physical, extent.length, extent.shared as u64] {
            out.extend_from_slice(&value.to_le_bytes());
        }
    }
    out.extend_from_slice(&(record.anchors.len() as u64).to_le_bytes());
    for (hash, block) in &record.anchors {
        out.extend_from_slice(&hash.to_le_bytes());
        out.extend_from_slice(&block.to_le_bytes());
    }
    let checksum = xxh3_64(&out);
    out.extend_from_slice(&checksum.to_le_bytes());
    out
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take(&mut self, count: usize) -> io::Result<&[u8]> {
        let end = self.at.checked_add(count).filter(|end| *end <= self.bytes.len()).ok_or_else(invalid)?;
        let slice = &self.bytes[self.at..end];
        self.at = end;
        Ok(slice)
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn string(&mut self) -> io::Result<String> {
        let length = self.u32()?;
        if length > MAX_STRING {
            return Err(invalid());
        }
        String::from_utf8(self.take(length as usize)?.to_vec()).map_err(|_| invalid())
    }
    fn count(&mut self, entry_bytes: usize) -> io::Result<usize> {
        let count = self.u64()?;
        if count > MAX_ENTRIES
            || (count as usize).checked_mul(entry_bytes).is_none_or(|bytes| bytes > self.bytes.len() - self.at)
        {
            return Err(invalid());
        }
        Ok(count as usize)
    }
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid dedupe record")
}

pub fn decode(bytes: &[u8]) -> io::Result<Record> {
    if bytes.len() < MAGIC.len() + 8 || &bytes[..MAGIC.len()] != MAGIC {
        return Err(invalid());
    }
    let (body, checksum) = bytes.split_at(bytes.len() - 8);
    if xxh3_64(body).to_le_bytes() != checksum {
        return Err(invalid());
    }
    let mut reader = Reader { bytes: body, at: MAGIC.len() };
    let key = reader.string()?;
    if !valid_key(&key) {
        return Err(invalid());
    }
    let path = PathBuf::from(reader.string()?);
    let identity =
        Identity { dev: reader.u64()?, ino: reader.u64()?, size: reader.u64()?, mtime_ns: reader.u64()? as i64 };
    let extent_count = reader.count(32)?;
    let mut extents = Vec::with_capacity(extent_count);
    for _ in 0..extent_count {
        extents.push(Extent {
            logical: reader.u64()?,
            physical: reader.u64()?,
            length: reader.u64()?,
            shared: reader.u64()? != 0,
        });
    }
    let anchor_count = reader.count(16)?;
    let mut anchors = Vec::with_capacity(anchor_count);
    for _ in 0..anchor_count {
        anchors.push((reader.u64()?, reader.u64()?));
    }
    if reader.at != body.len() {
        return Err(invalid());
    }
    Ok(Record { key, path, identity, extents, anchors })
}

fn read(path: &Path) -> io::Result<Record> {
    let mut bytes = Vec::new();
    File::open(path)?.read_to_end(&mut bytes)?;
    decode(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> Record {
        Record {
            key: "computer:abc".into(),
            path: PathBuf::from("/var/lib/caboose/overlays/abc.raw"),
            identity: Identity { dev: 3, ino: 99, size: 1 << 30, mtime_ns: -5 },
            extents: vec![Extent { logical: 0, physical: 8192, length: 4096, shared: true }],
            anchors: vec![(0xdead_beef, 0), (42, 7)],
        }
    }

    #[test]
    fn records_round_trip_and_reject_corruption() {
        let bytes = encode(&record());
        assert_eq!(decode(&bytes).unwrap(), record());
        for at in [0, 9, bytes.len() / 2, bytes.len() - 1] {
            let mut damaged = bytes.clone();
            damaged[at] ^= 1;
            assert!(decode(&damaged).is_err());
        }
        assert!(decode(&bytes[..bytes.len() - 3]).is_err());
    }

    #[test]
    fn the_store_saves_loads_and_discards_unreadable_files() {
        let directory = std::env::temp_dir().join(format!("caboose-disk-store-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        let mut store = FileStore::open(&directory).unwrap();
        store.save(&record()).unwrap();
        fs::write(directory.join("r-00.rec"), b"not a record").unwrap();
        fs::write(directory.join("r-01.tmp"), b"torn").unwrap();
        assert_eq!(store.load_all().unwrap(), vec![record()]);
        assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
        store.delete("computer:abc").unwrap();
        store.delete("computer:abc").unwrap();
        assert!(store.load_all().unwrap().is_empty());
        fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn keys_are_limited_to_computer_and_base_names() {
        assert!(valid_key("computer:4f9c-a1"));
        assert!(valid_key(&format!("base:{}", "a".repeat(64))));
        for bad in ["", "../x", "computer:a/b", "a b", &"k".repeat(161)] {
            assert!(!valid_key(bad));
        }
    }
}
