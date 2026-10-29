//! Backup manifests: a disk described in fixed-size chunks, each either all zeros, the same
//! as the base image at the same offset, or data named by its SHA-256. Only data chunks
//! have to be stored anywhere else; the rest are rebuilt from the base and holes.

use crate::volume::{Extent, FileId, Volume};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use xxhash_rust::xxh3::xxh3_64;

pub const DEFAULT_CHUNK_BYTES: u64 = 1 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chunk {
    Zero,
    Base,
    Data([u8; 32]),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BaseMap {
    pub size: u64,
    pub chunk_bytes: u64,
    pub sha256: [u8; 32],
    pub chunks: Vec<[u8; 32]>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub disk_bytes: u64,
    pub chunk_bytes: u64,
    pub base_sha256: Option<[u8; 32]>,
    pub chunks: Vec<Chunk>,
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn chunk_count(size: u64, chunk_bytes: u64) -> u64 {
    size.div_ceil(chunk_bytes)
}

fn has_data(extents: &[Extent], start: u64, end: u64) -> bool {
    let at = extents.partition_point(|e| e.logical + e.length <= start);
    at < extents.len() && extents[at].logical < end
}

fn extent_at(extents: &[Extent], position: u64) -> Result<&Extent, u64> {
    let at = extents.partition_point(|e| e.logical + e.length <= position);
    match extents.get(at) {
        Some(extent) if extent.logical <= position => Ok(extent),
        Some(extent) => Err(extent.logical),
        None => Err(u64::MAX),
    }
}

/// Whether `[start, end)` of the image is mapped to exactly the base's blocks, which proves
/// equal contents without reading them.
fn same_mapping(image: &[Extent], base: &[Extent], start: u64, end: u64) -> bool {
    let mut position = start;
    while position < end {
        match (extent_at(image, position), extent_at(base, position)) {
            (Err(image_next), Err(base_next)) => position = image_next.min(base_next),
            (Ok(i), Ok(b)) => {
                if !i.shared
                    || i.physical == u64::MAX
                    || b.physical == u64::MAX
                    || i.physical + (position - i.logical) != b.physical + (position - b.logical)
                {
                    return false;
                }
                position = (i.logical + i.length).min(b.logical + b.length);
            }
            _ => return false,
        }
    }
    true
}

fn zero_chunk_hash(length: u64) -> [u8; 32] {
    let zeros = vec![0u8; length as usize];
    Sha256::digest(&zeros).into()
}

/// Per-chunk hashes of a base image and the SHA-256 of the whole file.
pub fn base_map<V: Volume>(
    volume: &V,
    file: FileId,
    chunk_bytes: u64,
    cancel: &dyn Fn() -> bool,
) -> io::Result<BaseMap> {
    let size = volume.identity(file)?.size;
    let extents = volume.extents(file)?;
    let mut whole = Sha256::new();
    let mut chunks = Vec::with_capacity(chunk_count(size, chunk_bytes) as usize);
    let mut buffer = vec![0u8; chunk_bytes as usize];
    let full_zero = zero_chunk_hash(chunk_bytes);
    for index in 0..chunk_count(size, chunk_bytes) {
        if cancel() {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
        }
        let start = index * chunk_bytes;
        let length = (size - start).min(chunk_bytes);
        let bytes = &mut buffer[..length as usize];
        if has_data(&extents, start, start + length) {
            volume.read_at(file, start, bytes)?;
            whole.update(&*bytes);
            chunks.push(Sha256::digest(&*bytes).into());
        } else {
            bytes.fill(0);
            whole.update(&*bytes);
            chunks.push(if length == chunk_bytes { full_zero } else { zero_chunk_hash(length) });
        }
    }
    Ok(BaseMap { size, chunk_bytes, sha256: whole.finalize().into(), chunks })
}

pub fn manifest<V: Volume>(
    volume: &V,
    image: FileId,
    base: Option<(FileId, &BaseMap)>,
    chunk_bytes: u64,
    cancel: &dyn Fn() -> bool,
) -> io::Result<Manifest> {
    let size = volume.identity(image)?.size;
    let image_extents = volume.extents(image)?;
    let base_extents = match base {
        Some((file, map)) => {
            if map.chunk_bytes != chunk_bytes {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "base map chunk size differs"));
            }
            volume.extents(file)?
        }
        None => Vec::new(),
    };
    let mut buffer = vec![0u8; chunk_bytes as usize];
    let mut chunks = Vec::with_capacity(chunk_count(size, chunk_bytes) as usize);
    for index in 0..chunk_count(size, chunk_bytes) {
        if cancel() {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
        }
        let start = index * chunk_bytes;
        let end = (start + chunk_bytes).min(size);
        if !has_data(&image_extents, start, end) {
            chunks.push(Chunk::Zero);
            continue;
        }
        // The base holds a chunk of the same extent: equal when mapped to the same blocks
        // or when the bytes hash the same.
        let base_chunk = base.and_then(|(_, map)| {
            (end <= map.size || (start < map.size && end == size && map.size == size))
                .then(|| map.chunks[index as usize])
        });
        if base_chunk.is_some() && same_mapping(&image_extents, &base_extents, start, end) {
            chunks.push(Chunk::Base);
            continue;
        }
        let bytes = &mut buffer[..(end - start) as usize];
        volume.read_at(image, start, bytes)?;
        if bytes.iter().all(|b| *b == 0) {
            chunks.push(Chunk::Zero);
            continue;
        }
        let hash: [u8; 32] = Sha256::digest(&*bytes).into();
        chunks.push(if base_chunk == Some(hash) { Chunk::Base } else { Chunk::Data(hash) });
    }
    Ok(Manifest { disk_bytes: size, chunk_bytes, base_sha256: base.map(|(_, map)| map.sha256), chunks })
}

/// `{"version":1,"diskBytes":…,"chunkBytes":…,"baseSha256":…,"chunks":[…]}` where each
/// element of `chunks` is a data chunk's hex SHA-256 or a run, `{"zero":n}` or `{"base":n}`.
pub fn to_json(manifest: &Manifest) -> String {
    let mut out = format!(
        "{{\"version\":1,\"diskBytes\":{},\"chunkBytes\":{},\"baseSha256\":{},\"chunks\":[",
        manifest.disk_bytes,
        manifest.chunk_bytes,
        manifest.base_sha256.map(|hash| format!("\"{}\"", hex(&hash))).unwrap_or_else(|| "null".into())
    );
    let mut first = true;
    let mut index = 0;
    while index < manifest.chunks.len() {
        if !first {
            out.push(',');
        }
        first = false;
        match manifest.chunks[index] {
            Chunk::Data(hash) => {
                out.push('"');
                out.push_str(&hex(&hash));
                out.push('"');
                index += 1;
            }
            kind => {
                let run = manifest.chunks[index..].iter().take_while(|chunk| **chunk == kind).count();
                out.push_str(&format!("{{\"{}\":{run}}}", if kind == Chunk::Zero { "zero" } else { "base" }));
                index += run;
            }
        }
    }
    out.push_str("]}");
    out
}

const MAGIC: &[u8; 8] = b"CBDKBAS1";

/// A base map cached beside its source's identity, so each base is read in full once.
pub fn cached_base_map<V: Volume>(
    volume: &V,
    file: FileId,
    chunk_bytes: u64,
    cache: &Path,
    cancel: &dyn Fn() -> bool,
) -> io::Result<BaseMap> {
    let identity = volume.identity(file)?;
    let prefix = format!("base-{}-{}-", identity.dev, identity.ino);
    let path = cache.join(format!("{prefix}{}-{}-{chunk_bytes}.map", identity.size, identity.mtime_ns));
    if let Ok(map) = read_map(&path) {
        if map.size == identity.size && map.chunk_bytes == chunk_bytes {
            return Ok(map);
        }
    }
    let map = base_map(volume, file, chunk_bytes, cancel)?;
    fs::create_dir_all(cache)?;
    for entry in fs::read_dir(cache)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(&prefix) && entry.path() != path {
            let _ = fs::remove_file(entry.path());
        }
    }
    let mut bytes = Vec::with_capacity(64 + map.chunks.len() * 32);
    bytes.extend_from_slice(MAGIC);
    bytes.extend_from_slice(&map.size.to_le_bytes());
    bytes.extend_from_slice(&map.chunk_bytes.to_le_bytes());
    bytes.extend_from_slice(&map.sha256);
    bytes.extend_from_slice(&(map.chunks.len() as u64).to_le_bytes());
    for chunk in &map.chunks {
        bytes.extend_from_slice(chunk);
    }
    let checksum = xxh3_64(&bytes);
    bytes.extend_from_slice(&checksum.to_le_bytes());
    let temporary = path.with_extension("tmp");
    let mut out = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary)?;
    out.write_all(&bytes)?;
    out.sync_all()?;
    fs::rename(&temporary, &path)?;
    Ok(map)
}

fn read_map(path: &Path) -> io::Result<BaseMap> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidData, "invalid base map");
    let mut bytes = Vec::new();
    File::open(path)?.read_to_end(&mut bytes)?;
    if bytes.len() < 64 + 8 || &bytes[..8] != MAGIC {
        return Err(invalid());
    }
    let (body, checksum) = bytes.split_at(bytes.len() - 8);
    if xxh3_64(body).to_le_bytes() != checksum {
        return Err(invalid());
    }
    let u64_at = |at: usize| u64::from_le_bytes(body[at..at + 8].try_into().unwrap());
    let (size, chunk_bytes, count) = (u64_at(8), u64_at(16), u64_at(56));
    if chunk_bytes == 0 || count != chunk_count(size, chunk_bytes) || body.len() as u64 != 64 + count * 32 {
        return Err(invalid());
    }
    let sha256: [u8; 32] = body[24..56].try_into().unwrap();
    let chunks = body[64..].chunks_exact(32).map(|chunk| chunk.try_into().unwrap()).collect();
    Ok(BaseMap { size, chunk_bytes, sha256, chunks })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::volume::fake::FakeVolume;
    use crate::volume::{OpenMode, BLOCK};
    use std::path::PathBuf;

    fn block(seed: u8) -> Vec<u8> {
        vec![seed; BLOCK as usize]
    }

    fn never() -> bool {
        false
    }

    #[test]
    fn chunks_are_zero_base_or_named_data() {
        let mut volume = FakeVolume::new();
        // Chunks of two blocks: [1 2] [3 4] [hole hole] [5 6].
        let (b1, b2, b3, b4, b5, b6) = (block(1), block(2), block(3), block(4), block(5), block(6));
        volume.add("/base", &[Some(&b1), Some(&b2), Some(&b3), Some(&b4), None, None, Some(&b5), Some(&b6)]);
        volume.clone_file("/base", "/disk");
        // Chunk 1 rewritten; chunk 3 rewritten with what the base already holds there.
        volume.write_block("/disk", 2, &block(9));
        volume.write_block("/disk", 6, &block(5));
        let base = volume.open(&PathBuf::from("/base"), OpenMode::Inspect).unwrap();
        let disk = volume.open(&PathBuf::from("/disk"), OpenMode::Inspect).unwrap();
        let map = base_map(&volume, base, 2 * BLOCK, &never).unwrap();
        let result = manifest(&volume, disk, Some((base, &map)), 2 * BLOCK, &never).unwrap();
        let mut expected = block(9);
        expected.extend(block(4));
        let data: [u8; 32] = Sha256::digest(&expected).into();
        assert_eq!(result.chunks, vec![Chunk::Base, Chunk::Data(data), Chunk::Zero, Chunk::Base]);
        let mut whole = Vec::new();
        for seed in [1, 2, 3, 4, 0, 0, 5, 6] {
            whole.extend(block(seed));
        }
        assert_eq!(map.sha256, <[u8; 32]>::from(Sha256::digest(&whole)));
        let json = to_json(&result);
        assert!(json.starts_with(&format!("{{\"version\":1,\"diskBytes\":{},\"chunkBytes\":{},\"baseSha256\":\"{}\",\"chunks\":[{{\"base\":1}},\"{}\",{{\"zero\":1}},{{\"base\":1}}]}}", 8 * BLOCK, 2 * BLOCK, hex(&map.sha256), hex(&data))));
    }

    #[test]
    fn without_a_base_every_non_zero_chunk_is_data_and_runs_are_compressed() {
        let mut volume = FakeVolume::new();
        let zero = vec![0u8; BLOCK as usize];
        let data = block(7);
        volume.add("/disk", &[None, None, Some(&zero), None, Some(&data), None]);
        let disk = volume.open(&PathBuf::from("/disk"), OpenMode::Inspect).unwrap();
        let result = manifest(&volume, disk, None, BLOCK, &never).unwrap();
        assert_eq!(result.chunks[..4], [Chunk::Zero; 4]);
        assert!(matches!(result.chunks[4], Chunk::Data(_)));
        assert!(to_json(&result).contains("\"baseSha256\":null,\"chunks\":[{\"zero\":4},"));
    }

    #[test]
    fn base_maps_are_cached_by_identity() {
        let mut volume = FakeVolume::new();
        let one = block(1);
        volume.add("/base", &[Some(&one), None]);
        let base = volume.open(&PathBuf::from("/base"), OpenMode::Inspect).unwrap();
        let cache = std::env::temp_dir().join(format!("caboose-disk-maps-{}", std::process::id()));
        let _ = fs::remove_dir_all(&cache);
        let first = cached_base_map(&volume, base, BLOCK, &cache, &never).unwrap();
        let fail = || -> bool { panic!("the cached map must be used") };
        assert_eq!(cached_base_map(&volume, base, BLOCK, &cache, &fail).unwrap(), first);
        fs::remove_dir_all(&cache).unwrap();
    }
}
