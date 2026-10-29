//! Block-level sharing between computer disks.
//!
//! Each pass takes one parked computer's disk (the primary) and the clones that track it,
//! finds 4 KiB-aligned runs whose bytes already exist in an indexed source (a base image or
//! another parked computer's disk), and asks the kernel to share them. The kernel compares
//! the bytes under its own locks before remapping anything, so a stale index entry or a
//! hash collision costs one refused call and never changes what a file reads as.
//!
//! The index samples content-defined anchors: a block is an anchor when its hash has its
//! low bits clear, so the same content is an anchor wherever it lands. A shared run is found
//! from any anchor inside it and then extended by comparing bytes in both directions.

use crate::volume::{Extent, FileId, Identity, OpenMode, Outcome, Volume, BLOCK};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::io;
use std::path::PathBuf;
use xxhash_rust::xxh3::xxh3_64;

#[derive(Clone, Copy, Debug)]
pub struct Settings {
    /// One block in `sample` is an anchor (a power of two).
    pub sample: u64,
    /// The shortest run worth sharing, in blocks. Shorter runs fragment the disk for little.
    pub min_run: u64,
    /// The shortest run of zero blocks worth deallocating, in blocks.
    pub min_zero: u64,
    /// The most blocks shared by one kernel call.
    pub max_call: u64,
    /// Blocks read per I/O while hashing or comparing.
    pub read_blocks: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { sample: 32, min_run: 32, min_zero: 16, max_call: 4096, read_blocks: 256 }
    }
}

/// What the index remembers about one file between passes.
#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    pub key: String,
    pub path: PathBuf,
    pub identity: Identity,
    pub extents: Vec<Extent>,
    /// `(hash, block)` in block order.
    pub anchors: Vec<(u64, u64)>,
}

pub trait RecordStore {
    fn save(&mut self, record: &Record) -> io::Result<()>;
    fn delete(&mut self, key: &str) -> io::Result<()>;
}

#[derive(Clone, Copy)]
struct Location {
    slot: u32,
    generation: u32,
    block: u64,
}

struct Slot {
    record: Record,
    generation: u32,
}

/// Anchors of every indexed file, one location per distinct hash.
#[derive(Default)]
pub struct Index {
    slots: Vec<Option<Slot>>,
    free: Vec<usize>,
    by_key: HashMap<String, usize>,
    map: HashMap<u64, Location>,
    generation: u32,
    stale: usize,
}

impl Index {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.by_key.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_key.is_empty()
    }

    pub fn keys(&self) -> Vec<String> {
        self.by_key.keys().cloned().collect()
    }

    pub fn get(&self, key: &str) -> Option<&Record> {
        self.by_key.get(key).and_then(|slot| self.slots[*slot].as_ref()).map(|slot| &slot.record)
    }

    fn alive(&self, location: &Location) -> bool {
        matches!(self.slots.get(location.slot as usize), Some(Some(slot)) if slot.generation == location.generation)
    }

    pub fn insert(&mut self, record: Record) {
        self.remove(&record.key);
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        let slot = self.free.pop().unwrap_or_else(|| {
            self.slots.push(None);
            self.slots.len() - 1
        });
        for (hash, block) in &record.anchors {
            let location = Location { slot: slot as u32, generation, block: *block };
            match self.map.get(hash) {
                Some(existing) if self.alive(existing) => {}
                _ => {
                    self.map.insert(*hash, location);
                }
            }
        }
        self.by_key.insert(record.key.clone(), slot);
        self.slots[slot] = Some(Slot { record, generation });
    }

    pub fn remove(&mut self, key: &str) -> Option<Record> {
        let slot = self.by_key.remove(key)?;
        let removed = self.slots[slot].take()?;
        self.free.push(slot);
        self.stale += removed.record.anchors.len();
        if self.stale > 1024 && self.stale > self.map.len() / 2 {
            self.compact();
        }
        Some(removed.record)
    }

    /// Rebuild the hash map so removed files' anchors stop occupying it, and anchors they
    /// shadowed become reachable again.
    fn compact(&mut self) {
        self.map.clear();
        for (index, slot) in self.slots.iter().enumerate() {
            let Some(slot) = slot else { continue };
            for (hash, block) in &slot.record.anchors {
                self.map.entry(*hash).or_insert(Location { slot: index as u32, generation: slot.generation, block: *block });
            }
        }
        self.stale = 0;
    }

    fn lookup(&self, hash: u64) -> Option<(&str, u64)> {
        let location = self.map.get(&hash)?;
        if !self.alive(location) {
            return None;
        }
        let slot = self.slots[location.slot as usize].as_ref()?;
        Some((slot.record.key.as_str(), location.block))
    }
}

#[derive(Clone, Debug)]
pub struct SourceSpec {
    pub key: String,
    pub path: PathBuf,
    /// A base image: never written, so its record is rebuilt only when the file is replaced.
    pub immutable: bool,
}

#[derive(Clone, Debug)]
pub struct Job {
    pub key: String,
    /// The primary disk first, then the clones that track it.
    pub files: Vec<PathBuf>,
    pub sources: Vec<SourceSpec>,
    /// When present, every indexed key not listed (and not the primary) is forgotten.
    pub live: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// Bytes of the primary that were read and hashed this pass.
    pub hashed_bytes: u64,
    /// Bytes of the primary that now share storage with a source.
    pub shared_bytes: u64,
    /// Bytes of zeros deallocated from the primary.
    pub punched_bytes: u64,
    /// Sources that were not usable this pass (in use, missing, or not yet indexed).
    pub skipped_sources: Vec<String>,
}

#[derive(Debug)]
pub enum RunError {
    /// The primary is locked: a VMM or another tool has it open.
    Busy,
    Missing,
    Cancelled(Report),
    /// The filesystem cannot share blocks between these files.
    Unsupported(String),
    Io(io::Error),
}

impl From<io::Error> for RunError {
    fn from(error: io::Error) -> Self {
        RunError::Io(error)
    }
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::Busy => write!(f, "the disk is in use"),
            RunError::Missing => write!(f, "the disk does not exist"),
            RunError::Cancelled(_) => write!(f, "cancelled"),
            RunError::Unsupported(message) => write!(f, "{message}"),
            RunError::Io(error) => write!(f, "{error}"),
        }
    }
}

/// The hash of one non-zero block.
pub fn block_hash(block: &[u8]) -> u64 {
    xxh3_64(block)
}

fn is_zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|byte| *byte == 0)
}

fn is_anchor(hash: u64, settings: &Settings) -> bool {
    hash & (settings.sample - 1) == 0
}

/// Blocks hashed in one file: its anchors, and for unshared data the lookups and zero runs.
#[derive(Default)]
struct Scan {
    anchors: Vec<(u64, u64)>,
    candidates: Vec<(u64, u64)>,
    regions: Vec<(u64, u64)>,
    zero_runs: Vec<(u64, u64)>,
    hashed_bytes: u64,
}

fn push_range(ranges: &mut Vec<(u64, u64)>, start: u64, end: u64) {
    if let Some(last) = ranges.last_mut() {
        if last.1 == start {
            last.1 = end;
            return;
        }
    }
    ranges.push((start, end));
}

/// Physical ranges already held by indexed sources, sorted and merged.
#[derive(Default)]
struct Settled(Vec<(u64, u64)>);

impl Settled {
    fn from_records<'a>(records: impl Iterator<Item = &'a Record>) -> Self {
        let mut ranges: Vec<(u64, u64)> = records.flat_map(|record| record.extents.iter()).filter(|e| e.shared && e.physical != u64::MAX).map(|e| (e.physical, e.physical + e.length)).collect();
        ranges.sort_unstable();
        let mut merged: Vec<(u64, u64)> = Vec::with_capacity(ranges.len());
        for (start, end) in ranges {
            match merged.last_mut() {
                Some(last) if start <= last.1 => last.1 = last.1.max(end),
                _ => merged.push((start, end)),
            }
        }
        Settled(merged)
    }

    /// The extent's blocks are already shared with an indexed source: nothing to gain.
    fn covers(&self, extent: &Extent) -> bool {
        if !extent.shared || extent.physical == u64::MAX {
            return false;
        }
        let at = self.0.partition_point(|(start, _)| *start <= extent.physical);
        at > 0 && self.0[at - 1].1 >= extent.physical + extent.length
    }
}

/// Hash a file's data: anchors everywhere, and for data not already held by a source
/// (`settled`), the blocks to look up and the zero runs. A settled extent unchanged since
/// `previous` keeps its old anchors: shared blocks cannot be written in place, so the same
/// mapping means the same bytes.
fn scan<V: Volume>(volume: &V, file: FileId, extents: &[Extent], previous: Option<&Record>, settled: Option<&Settled>, settings: &Settings, cancel: &dyn Fn() -> bool) -> Result<Scan, RunError> {
    let mut scan = Scan::default();
    let mut buffer = vec![0u8; (settings.read_blocks * BLOCK) as usize];
    for extent in extents {
        if extent.logical % BLOCK != 0 || extent.length % BLOCK != 0 {
            continue;
        }
        let first = extent.logical / BLOCK;
        let end = first + extent.length / BLOCK;
        let open = settled.is_some_and(|settled| !settled.covers(extent));
        if open {
            push_range(&mut scan.regions, first, end);
        }
        if let Some(old) = previous {
            if !open && extent.shared && old.extents.binary_search_by_key(&extent.logical, |e| e.logical).is_ok_and(|at| old.extents[at] == *extent) {
                let from = old.anchors.partition_point(|(_, block)| *block < first);
                let to = old.anchors.partition_point(|(_, block)| *block < end);
                scan.anchors.extend_from_slice(&old.anchors[from..to]);
                continue;
            }
        }
        let mut zero_start: Option<u64> = None;
        let mut block = first;
        while block < end {
            if cancel() {
                return Err(RunError::Cancelled(Report::default()));
            }
            let count = (end - block).min(settings.read_blocks);
            let bytes = &mut buffer[..(count * BLOCK) as usize];
            volume.read_at(file, block * BLOCK, bytes)?;
            for (offset, data) in bytes.chunks_exact(BLOCK as usize).enumerate() {
                let here = block + offset as u64;
                if is_zero(data) {
                    if open && zero_start.is_none() {
                        zero_start = Some(here);
                    }
                    continue;
                }
                if let Some(start) = zero_start.take() {
                    push_range(&mut scan.zero_runs, start, here);
                }
                let hash = block_hash(data);
                if is_anchor(hash, settings) {
                    scan.anchors.push((hash, here));
                }
                if open {
                    scan.candidates.push((hash, here));
                }
            }
            scan.hashed_bytes += count * BLOCK;
            block += count;
        }
        if let Some(start) = zero_start {
            push_range(&mut scan.zero_runs, start, end);
        }
    }
    scan.anchors.sort_by_key(|(_, block)| *block);
    scan.anchors.dedup_by_key(|(_, block)| *block);
    Ok(scan)
}

/// Blocks, from `(a, b)` forward, that are equal in both files; at most `limit`.
fn equal_forward<V: Volume>(volume: &V, a: FileId, a_block: u64, b: FileId, b_block: u64, limit: u64, settings: &Settings) -> io::Result<u64> {
    let mut matched = 0;
    let mut left = vec![0u8; (settings.read_blocks * BLOCK) as usize];
    let mut right = left.clone();
    while matched < limit {
        let count = (limit - matched).min(settings.read_blocks);
        let size = (count * BLOCK) as usize;
        volume.read_at(a, (a_block + matched) * BLOCK, &mut left[..size])?;
        volume.read_at(b, (b_block + matched) * BLOCK, &mut right[..size])?;
        for index in 0..count as usize {
            let range = index * BLOCK as usize..(index + 1) * BLOCK as usize;
            if left[range.clone()] != right[range] {
                return Ok(matched + index as u64);
            }
        }
        matched += count;
    }
    Ok(matched)
}

/// Blocks before `(a, b)` that are equal in both files; at most `limit`.
fn equal_backward<V: Volume>(volume: &V, a: FileId, a_block: u64, b: FileId, b_block: u64, limit: u64, settings: &Settings) -> io::Result<u64> {
    let mut matched = 0;
    let mut left = vec![0u8; (settings.read_blocks * BLOCK) as usize];
    let mut right = left.clone();
    while matched < limit {
        let count = (limit - matched).min(settings.read_blocks);
        let size = (count * BLOCK) as usize;
        volume.read_at(a, (a_block - matched - count) * BLOCK, &mut left[..size])?;
        volume.read_at(b, (b_block - matched - count) * BLOCK, &mut right[..size])?;
        for index in (0..count as usize).rev() {
            let range = index * BLOCK as usize..(index + 1) * BLOCK as usize;
            if left[range.clone()] != right[range] {
                return Ok(matched + (count - 1 - index as u64));
            }
        }
        matched += count;
    }
    Ok(matched)
}

fn unsupported(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::EXDEV) | Some(libc::EOPNOTSUPP) | Some(libc::ENOTTY) | Some(libc::EINVAL))
}

fn open_error(error: io::Error) -> RunError {
    match error.raw_os_error() {
        Some(libc::EAGAIN) | Some(libc::EACCES) => RunError::Busy,
        _ if error.kind() == io::ErrorKind::NotFound => RunError::Missing,
        _ => RunError::Io(error),
    }
}

/// One pass over one computer's disk.
pub fn run<V: Volume>(volume: &mut V, index: &mut Index, store: &mut dyn RecordStore, job: &Job, settings: &Settings, cancel: &dyn Fn() -> bool) -> Result<Report, RunError> {
    assert!(settings.sample.is_power_of_two() && settings.min_run > 0 && settings.max_call > 0 && settings.read_blocks > 0);
    let mut report = Report::default();
    if let Some(live) = &job.live {
        let keep: HashSet<&str> = live.iter().map(String::as_str).chain([job.key.as_str()]).collect();
        for key in index.keys() {
            if !keep.contains(key.as_str()) {
                index.remove(&key);
                store.delete(&key)?;
            }
        }
    }
    let primary_path = job.files.first().ok_or(RunError::Missing)?;
    let primary = volume.open(primary_path, OpenMode::Primary).map_err(open_error)?;
    let mut siblings = Vec::new();
    for path in &job.files[1..] {
        if let Ok(file) = volume.open(path, OpenMode::Sibling) {
            siblings.push(file);
        }
    }
    if siblings.len() + 1 > 8 {
        return Err(RunError::Unsupported("too many clones of one disk".into()));
    }

    // Sources: a base is indexed on first use; a computer only once it has been a primary.
    let mut eligible: HashMap<String, FileId> = HashMap::new();
    for source in &job.sources {
        if source.key == job.key {
            continue;
        }
        let file = match volume.open(&source.path, OpenMode::Source) {
            Ok(file) => file,
            Err(_) => {
                report.skipped_sources.push(source.key.clone());
                continue;
            }
        };
        let identity = volume.identity(file)?;
        let current = index.get(&source.key).is_some_and(|record| record.identity.dev == identity.dev && record.identity.ino == identity.ino && (!source.immutable || record.identity == identity));
        if !current {
            if !source.immutable {
                report.skipped_sources.push(source.key.clone());
                continue;
            }
            let extents = volume.extents(file)?;
            let scanned = scan(volume, file, &extents, None, None, settings, cancel).map_err(|error| match error {
                RunError::Cancelled(_) => RunError::Cancelled(report.clone()),
                other => other,
            })?;
            let record = Record { key: source.key.clone(), path: source.path.clone(), identity, extents, anchors: scanned.anchors };
            store.save(&record)?;
            index.insert(record);
        }
        eligible.insert(source.key.clone(), file);
    }

    let settled = Settled::from_records(eligible.keys().filter_map(|key| index.get(key)));
    let previous = index.remove(&job.key);
    let extents = volume.extents(primary)?;
    let scanned = match scan(volume, primary, &extents, previous.as_ref(), Some(&settled), settings, cancel) {
        Ok(scanned) => scanned,
        Err(error) => {
            if let Some(previous) = previous {
                index.insert(previous);
            }
            return Err(match error {
                RunError::Cancelled(_) => RunError::Cancelled(report),
                other => other,
            });
        }
    };
    report.hashed_bytes = scanned.hashed_bytes;

    let mut source_blocks: HashMap<FileId, u64> = HashMap::new();
    for file in eligible.values() {
        source_blocks.insert(*file, volume.identity(*file)?.size / BLOCK);
    }
    let mut cursor = 0u64;
    let mut cancelled = false;
    'candidates: for (hash, block) in &scanned.candidates {
        if *block < cursor {
            continue;
        }
        if cancel() {
            cancelled = true;
            break;
        }
        let Some((key, source_block)) = index.lookup(*hash) else { continue };
        let Some(source) = eligible.get(key).copied() else { continue };
        let region = scanned.regions[scanned.regions.partition_point(|(_, end)| *end <= *block)];
        let source_end = source_blocks[&source];
        if source_block >= source_end {
            continue;
        }
        let ahead = equal_forward(volume, source, source_block, primary, *block, (region.1 - block).min(source_end - source_block), settings)?;
        if ahead == 0 {
            continue;
        }
        let floor = region.0.max(cursor);
        let behind = equal_backward(volume, source, source_block, primary, *block, (block - floor).min(source_block), settings)?;
        let (start, source_start, length) = (block - behind, source_block - behind, behind + ahead);
        if length < settings.min_run {
            continue;
        }
        let mut done = 0;
        while done < length {
            if cancel() {
                cancelled = true;
                break 'candidates;
            }
            let piece = (length - done).min(settings.max_call);
            let destinations: Vec<(FileId, u64)> = [primary].iter().chain(&siblings).map(|file| (*file, (start + done) * BLOCK)).collect();
            let outcomes = match volume.dedupe(source, (source_start + done) * BLOCK, piece * BLOCK, &destinations) {
                Ok(outcomes) => outcomes,
                Err(error) if unsupported(&error) => return Err(RunError::Unsupported(format!("the filesystem cannot share these blocks: {error}"))),
                Err(error) => return Err(RunError::Io(error)),
            };
            match outcomes[0] {
                Outcome::Same => report.shared_bytes += piece * BLOCK,
                // A concurrent change or a stale range; the next anchor tries again.
                Outcome::Differs | Outcome::Failed(_) => break,
            }
            done += piece;
        }
        cursor = start + done.max(1);
    }

    if !cancelled {
        let mut zero = vec![0u8; (settings.read_blocks * BLOCK) as usize];
        'zeros: for (start, end) in &scanned.zero_runs {
            if end - start < settings.min_zero {
                continue;
            }
            if cancel() {
                cancelled = true;
                break;
            }
            volume.punch(primary, start * BLOCK, (end - start) * BLOCK)?;
            report.punched_bytes += (end - start) * BLOCK;
            // A clone may have diverged from the primary; deallocate only what it proves zero.
            'siblings: for sibling in &siblings {
                let mut block = *start;
                while block < *end {
                    if cancel() {
                        cancelled = true;
                        break 'zeros;
                    }
                    let count = (end - block).min(settings.read_blocks);
                    let bytes = &mut zero[..(count * BLOCK) as usize];
                    volume.read_at(*sibling, block * BLOCK, bytes)?;
                    if !is_zero(bytes) {
                        continue 'siblings;
                    }
                    block += count;
                }
                volume.punch(*sibling, start * BLOCK, (end - start) * BLOCK)?;
            }
        }
    }

    let record = Record { key: job.key.clone(), path: primary_path.clone(), identity: volume.identity(primary)?, extents: volume.extents(primary)?, anchors: scanned.anchors };
    store.save(&record)?;
    index.insert(record);
    if cancelled {
        return Err(RunError::Cancelled(report));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::volume::fake::FakeVolume;

    #[derive(Default)]
    struct Memory {
        saved: HashMap<String, Record>,
    }

    impl RecordStore for Memory {
        fn save(&mut self, record: &Record) -> io::Result<()> {
            self.saved.insert(record.key.clone(), record.clone());
            Ok(())
        }
        fn delete(&mut self, key: &str) -> io::Result<()> {
            self.saved.remove(key);
            Ok(())
        }
    }

    fn block(seed: u64) -> Vec<u8> {
        let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
        (0..BLOCK)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    fn settings() -> Settings {
        // Every block an anchor and short runs, so small fixtures exercise the paths.
        Settings { sample: 1, min_run: 2, min_zero: 2, max_call: 3, read_blocks: 2 }
    }

    fn file(volume: &FakeVolume, path: &str, seeds: &[Option<u64>]) {
        let blocks: Vec<Option<Vec<u8>>> = seeds.iter().map(|seed| seed.map(|seed| if seed == 0 { vec![0; BLOCK as usize] } else { block(seed) })).collect();
        let refs: Vec<Option<&[u8]>> = blocks.iter().map(|b| b.as_deref()).collect();
        volume.add(path, &refs);
    }

    fn job(key: &str, files: &[&str], sources: &[(&str, &str, bool)]) -> Job {
        Job {
            key: key.into(),
            files: files.iter().map(PathBuf::from).collect(),
            sources: sources.iter().map(|(key, path, immutable)| SourceSpec { key: (*key).into(), path: PathBuf::from(path), immutable: *immutable }).collect(),
            live: None,
        }
    }

    fn never() -> bool {
        false
    }

    #[test]
    fn shares_runs_that_already_exist_in_an_indexed_disk_without_changing_contents() {
        let mut volume = FakeVolume::new();
        file(&volume, "/a", &[Some(1), Some(2), Some(3), Some(4), Some(5)]);
        // The same run at a different offset, between unrelated blocks.
        file(&volume, "/b", &[Some(9), Some(2), Some(3), Some(4), Some(8)]);
        let before = (volume.contents("/a"), volume.contents("/b"));
        let mut index = Index::new();
        let mut store = Memory::default();
        let first = run(&mut volume, &mut index, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        assert_eq!(first.shared_bytes, 0);
        let allocated = volume.allocated_blocks();
        let second = run(&mut volume, &mut index, &mut store, &job("computer:b", &["/b"], &[("computer:a", "/a", false)]), &settings(), &never).unwrap();
        assert_eq!(second.shared_bytes, 3 * BLOCK);
        assert_eq!(volume.allocated_blocks(), allocated - 3);
        assert_eq!(volume.physical("/b", 2), volume.physical("/a", 2));
        assert_eq!((volume.contents("/a"), volume.contents("/b")), before);
        assert!(store.saved.contains_key("computer:b"));
    }

    #[test]
    fn indexes_a_base_on_first_use_and_shares_into_every_clone_of_the_primary() {
        let mut volume = FakeVolume::new();
        file(&volume, "/base", &[Some(1), Some(2), Some(3), Some(4)]);
        file(&volume, "/disk", &[Some(7), Some(3), Some(4), Some(6)]);
        volume.clone_file("/disk", "/view");
        let allocated = volume.allocated_blocks();
        let mut index = Index::new();
        let mut store = Memory::default();
        let report = run(&mut volume, &mut index, &mut store, &job("computer:c", &["/disk", "/view"], &[("base:x", "/base", true)]), &settings(), &never).unwrap();
        assert_eq!(report.shared_bytes, 2 * BLOCK);
        // Both references to the old blocks moved, so they were freed.
        assert_eq!(volume.allocated_blocks(), allocated - 2);
        assert_eq!(volume.physical("/view", 1), volume.physical("/base", 2));
        assert!(index.get("base:x").is_some());
    }

    #[test]
    fn deallocates_zero_runs_but_keeps_a_diverged_clones_data() {
        let mut volume = FakeVolume::new();
        file(&volume, "/disk", &[Some(1), Some(0), Some(0), Some(0), Some(2)]);
        file(&volume, "/older", &[Some(1), Some(5), Some(0), Some(0), Some(2)]);
        let older = volume.contents("/older");
        let mut index = Index::new();
        let mut store = Memory::default();
        let report = run(&mut volume, &mut index, &mut store, &job("computer:d", &["/disk", "/older"], &[]), &settings(), &never).unwrap();
        assert_eq!(report.punched_bytes, 3 * BLOCK);
        assert_eq!(volume.physical("/disk", 2), None);
        assert_eq!(volume.contents("/older"), older);
        assert!(volume.physical("/older", 1).is_some());
    }

    #[test]
    fn refuses_a_disk_in_use_and_skips_sources_in_use() {
        let mut volume = FakeVolume::new();
        file(&volume, "/a", &[Some(1), Some(2)]);
        file(&volume, "/b", &[Some(1), Some(2)]);
        let mut index = Index::new();
        let mut store = Memory::default();
        run(&mut volume, &mut index, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        volume.lock("/b", OpenMode::Primary);
        assert!(matches!(run(&mut volume, &mut index, &mut store, &job("computer:b", &["/b"], &[]), &settings(), &never), Err(RunError::Busy)));
        let mut volume2 = FakeVolume::new();
        file(&volume2, "/a", &[Some(1), Some(2)]);
        file(&volume2, "/b", &[Some(1), Some(2)]);
        let mut index2 = Index::new();
        run(&mut volume2, &mut index2, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        volume2.lock("/a", OpenMode::Primary);
        let report = run(&mut volume2, &mut index2, &mut store, &job("computer:b", &["/b"], &[("computer:a", "/a", false)]), &settings(), &never).unwrap();
        assert_eq!(report.shared_bytes, 0);
        assert_eq!(report.skipped_sources, vec!["computer:a".to_string()]);
    }

    #[test]
    fn a_stale_index_entry_costs_a_refused_call_and_nothing_else() {
        let mut volume = FakeVolume::new();
        file(&volume, "/a", &[Some(1), Some(2), Some(3)]);
        file(&volume, "/b", &[Some(1), Some(2), Some(3)]);
        let mut index = Index::new();
        let mut store = Memory::default();
        run(&mut volume, &mut index, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        // /a changes after it was indexed (its computer ran); its record is now stale.
        volume.write_block("/a", 0, &block(40));
        volume.write_block("/a", 1, &block(41));
        volume.write_block("/a", 2, &block(42));
        let before = volume.contents("/b");
        let report = run(&mut volume, &mut index, &mut store, &job("computer:b", &["/b"], &[("computer:a", "/a", false)]), &settings(), &never).unwrap();
        assert_eq!(report.shared_bytes, 0);
        assert_eq!(volume.contents("/b"), before);
    }

    #[test]
    fn a_rescan_reuses_anchors_of_unchanged_shared_extents() {
        let mut volume = FakeVolume::new();
        file(&volume, "/base", &[Some(1), Some(2), Some(3), Some(4)]);
        volume.clone_file("/base", "/disk");
        volume.write_block("/disk", 3, &block(9));
        let mut index = Index::new();
        let mut store = Memory::default();
        let sources = [("base:x", "/base", true)];
        let first = run(&mut volume, &mut index, &mut store, &job("computer:e", &["/disk"], &sources), &settings(), &never).unwrap();
        assert_eq!(first.hashed_bytes, 4 * BLOCK);
        let second = run(&mut volume, &mut index, &mut store, &job("computer:e", &["/disk"], &sources), &settings(), &never).unwrap();
        // Only the block the computer owns is read again.
        assert_eq!(second.hashed_bytes, BLOCK);
        assert_eq!(index.get("computer:e").unwrap().anchors, store.saved["computer:e"].anchors);
        assert_eq!(index.get("computer:e").unwrap().anchors.len(), 4);
    }

    #[test]
    fn cancellation_stops_between_calls_and_keeps_the_previous_record_when_scanning() {
        let mut volume = FakeVolume::new();
        file(&volume, "/a", &[Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)]);
        file(&volume, "/b", &[Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)]);
        let mut index = Index::new();
        let mut store = Memory::default();
        run(&mut volume, &mut index, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        let calls = std::cell::Cell::new(0);
        let after_one_call = || {
            calls.set(calls.get() + 1);
            calls.get() > 5
        };
        let result = run(&mut volume, &mut index, &mut store, &job("computer:b", &["/b"], &[("computer:a", "/a", false)]), &settings(), &after_one_call);
        let Err(RunError::Cancelled(report)) = result else { panic!("expected cancellation") };
        assert!(report.shared_bytes < 6 * BLOCK);
        assert!(index.get("computer:b").is_some());
        let always = || true;
        let previous = index.get("computer:b").cloned();
        assert!(matches!(run(&mut volume, &mut index, &mut store, &job("computer:b", &["/b"], &[]), &settings(), &always), Err(RunError::Cancelled(_))));
        assert_eq!(index.get("computer:b").cloned(), previous);
    }

    #[test]
    fn forgets_disks_that_are_no_longer_live() {
        let mut volume = FakeVolume::new();
        file(&volume, "/a", &[Some(1)]);
        file(&volume, "/b", &[Some(2)]);
        let mut index = Index::new();
        let mut store = Memory::default();
        run(&mut volume, &mut index, &mut store, &job("computer:a", &["/a"], &[]), &settings(), &never).unwrap();
        let mut second = job("computer:b", &["/b"], &[]);
        second.live = Some(vec![]);
        run(&mut volume, &mut index, &mut store, &second, &settings(), &never).unwrap();
        assert!(index.get("computer:a").is_none());
        assert!(!store.saved.contains_key("computer:a"));
        assert_eq!(index.keys(), vec!["computer:b".to_string()]);
    }

    #[test]
    fn the_index_keeps_the_first_live_location_and_recovers_shadowed_ones_after_removal() {
        let record = |key: &str, block: u64| Record { key: key.into(), path: PathBuf::from("/"), identity: Identity::default(), extents: vec![], anchors: vec![(7, block)] };
        let mut index = Index::new();
        index.insert(record("a", 1));
        index.insert(record("b", 2));
        assert_eq!(index.lookup(7), Some(("a", 1)));
        index.remove("a");
        index.compact();
        assert_eq!(index.lookup(7), Some(("b", 2)));
    }
}
