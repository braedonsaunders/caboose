//! The filesystem operations the dedupe and manifest passes need, behind a trait so the
//! passes can be tested against an in-memory volume. The Linux implementation uses FIEMAP,
//! FIDEDUPERANGE and hole punching; nothing here changes what a file reads as.

use std::io;
use std::path::Path;

/// The 4 KiB unit used to compare raw disk ranges, independent of the guest filesystem.
/// Shared ranges must also satisfy the host filesystem's allocation alignment.
pub const BLOCK: u64 = 4096;

/// Index of an open file within a `Volume`.
pub type FileId = usize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
    /// The disk being deduplicated: opened read-write and exclusively locked, so the pass
    /// refuses a disk a VMM (or anything else holding a lock) has open.
    Primary,
    /// A clone that tracks the primary (a parked Files view or a backup capture): opened
    /// read-write without a lock. Every change is content-preserving and kernel-verified.
    Sibling,
    /// A disk whose blocks may be shared into the primary: opened read-only under a shared
    /// lock, so a disk in use by a VMM is skipped.
    Source,
    /// An immutable image read for a manifest: read-only, no lock.
    Inspect,
}

/// What identifies a file's contents between passes. A different device or inode is a
/// different file; size and modification time say whether it may have been written.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Identity {
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub mtime_ns: i64,
}

/// One mapped data range. `shared` is the filesystem's statement that the physical blocks
/// are referenced by more than one file (or more than once), so they cannot change in place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Extent {
    pub logical: u64,
    pub physical: u64,
    pub length: u64,
    pub shared: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The ranges were identical and now share storage.
    Same,
    /// The kernel found the ranges differ; nothing changed.
    Differs,
    /// The kernel refused the range (a negative errno); nothing changed.
    Failed(i32),
}

pub trait Volume {
    fn open(&mut self, path: &Path, mode: OpenMode) -> io::Result<FileId>;
    fn identity(&self, file: FileId) -> io::Result<Identity>;
    /// Data extents in logical order. Holes are absent.
    fn extents(&self, file: FileId) -> io::Result<Vec<Extent>>;
    /// Fill `buf` from `offset`; reads past the end are zero.
    fn read_at(&self, file: FileId, offset: u64, buf: &mut [u8]) -> io::Result<()>;
    /// Share `length` bytes of `source` at `offset` into each destination, one outcome each.
    fn dedupe(
        &self,
        source: FileId,
        offset: u64,
        length: u64,
        destinations: &[(FileId, u64)],
    ) -> io::Result<Vec<Outcome>>;
    /// Deallocate a range that reads as zeros, keeping the file's size.
    fn punch(&self, file: FileId, offset: u64, length: u64) -> io::Result<()>;
}

#[cfg(target_os = "linux")]
pub use linux::LinuxVolume;

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::fs::{File, OpenOptions};
    use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
    use std::os::unix::io::AsRawFd;

    const FS_IOC_FIEMAP: libc::c_ulong = 0xC020_660B;
    const FIDEDUPERANGE: libc::c_ulong = 0xC018_9436;
    const FIEMAP_FLAG_SYNC: u32 = 0x1;
    const FIEMAP_EXTENT_LAST: u32 = 0x1;
    const FIEMAP_EXTENT_UNKNOWN: u32 = 0x2;
    const FIEMAP_EXTENT_DELALLOC: u32 = 0x4;
    const FIEMAP_EXTENT_UNWRITTEN: u32 = 0x800;
    const FIEMAP_EXTENT_SHARED: u32 = 0x2000;
    const BATCH: usize = 512;

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct FiemapExtent {
        logical: u64,
        physical: u64,
        length: u64,
        reserved64: [u64; 2],
        flags: u32,
        reserved: [u32; 3],
    }

    #[repr(C)]
    struct Fiemap {
        start: u64,
        length: u64,
        flags: u32,
        mapped_extents: u32,
        extent_count: u32,
        reserved: u32,
        extents: [FiemapExtent; BATCH],
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct DedupeInfo {
        dest_fd: i64,
        dest_offset: u64,
        bytes_deduped: u64,
        status: i32,
        reserved: u32,
    }

    #[repr(C)]
    struct DedupeRange<const N: usize> {
        src_offset: u64,
        src_length: u64,
        dest_count: u16,
        reserved1: u16,
        reserved2: u32,
        info: [DedupeInfo; N],
    }

    /// The most destinations one pass shares into at once: the primary and its clones.
    pub const MAX_DESTINATIONS: usize = 8;

    #[derive(Default)]
    pub struct LinuxVolume {
        files: Vec<File>,
    }

    impl LinuxVolume {
        pub fn new() -> Self {
            Self::default()
        }

        fn file(&self, id: FileId) -> io::Result<&File> {
            self.files.get(id).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "unknown file"))
        }
    }

    fn lock(file: &File, kind: libc::c_short) -> io::Result<()> {
        // Open file description locks: owned by this open file, and they conflict with the
        // byte-range locks VMMs and QEMU hold on images.
        let mut request: libc::flock = unsafe { std::mem::zeroed() };
        request.l_type = kind;
        request.l_whence = libc::SEEK_SET as libc::c_short;
        let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_OFD_SETLK, &request) };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    impl Volume for LinuxVolume {
        fn open(&mut self, path: &Path, mode: OpenMode) -> io::Result<FileId> {
            let file = OpenOptions::new()
                .read(true)
                .write(matches!(mode, OpenMode::Primary | OpenMode::Sibling))
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(path)?;
            if !file.metadata()?.is_file() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a regular file"));
            }
            match mode {
                OpenMode::Primary => lock(&file, libc::F_WRLCK as libc::c_short)?,
                OpenMode::Source => lock(&file, libc::F_RDLCK as libc::c_short)?,
                OpenMode::Sibling | OpenMode::Inspect => {}
            }
            self.files.push(file);
            Ok(self.files.len() - 1)
        }

        fn identity(&self, id: FileId) -> io::Result<Identity> {
            let meta = self.file(id)?.metadata()?;
            Ok(Identity {
                dev: meta.dev(),
                ino: meta.ino(),
                size: meta.size(),
                mtime_ns: meta.mtime() * 1_000_000_000 + meta.mtime_nsec(),
            })
        }

        fn extents(&self, id: FileId) -> io::Result<Vec<Extent>> {
            let file = self.file(id)?;
            let mut out: Vec<Extent> = Vec::new();
            let mut start = 0u64;
            let mut flags = FIEMAP_FLAG_SYNC;
            loop {
                let mut map: Box<Fiemap> = Box::new(Fiemap {
                    start,
                    length: u64::MAX - start,
                    flags,
                    mapped_extents: 0,
                    extent_count: BATCH as u32,
                    reserved: 0,
                    extents: [FiemapExtent::default(); BATCH],
                });
                flags = 0;
                if unsafe { libc::ioctl(file.as_raw_fd(), FS_IOC_FIEMAP as _, &mut *map as *mut Fiemap) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                let count = map.mapped_extents as usize;
                if count == 0 {
                    break;
                }
                let mut last = false;
                for extent in &map.extents[..count] {
                    last |= extent.flags & FIEMAP_EXTENT_LAST != 0;
                    start = extent.logical + extent.length;
                    // Unwritten (preallocated) extents read as zeros, like holes.
                    if extent.flags & FIEMAP_EXTENT_UNWRITTEN != 0 {
                        continue;
                    }
                    // Physical placement is unknown for delayed allocation; the data is
                    // still there, but it cannot be proven shared or stable.
                    let unknown = extent.flags & (FIEMAP_EXTENT_UNKNOWN | FIEMAP_EXTENT_DELALLOC) != 0;
                    out.push(Extent {
                        logical: extent.logical,
                        physical: if unknown { u64::MAX } else { extent.physical },
                        length: extent.length,
                        shared: !unknown && extent.flags & FIEMAP_EXTENT_SHARED != 0,
                    });
                }
                if last {
                    break;
                }
            }
            Ok(out)
        }

        fn read_at(&self, id: FileId, offset: u64, buf: &mut [u8]) -> io::Result<()> {
            let file = self.file(id)?;
            let mut done = 0;
            while done < buf.len() {
                match file.read_at(&mut buf[done..], offset + done as u64) {
                    Ok(0) => {
                        buf[done..].fill(0);
                        return Ok(());
                    }
                    Ok(read) => done += read,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    Err(error) => return Err(error),
                }
            }
            Ok(())
        }

        fn dedupe(
            &self,
            source: FileId,
            offset: u64,
            length: u64,
            destinations: &[(FileId, u64)],
        ) -> io::Result<Vec<Outcome>> {
            if destinations.is_empty() || destinations.len() > MAX_DESTINATIONS {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid destination count"));
            }
            let mut range = DedupeRange::<MAX_DESTINATIONS> {
                src_offset: offset,
                src_length: length,
                dest_count: destinations.len() as u16,
                reserved1: 0,
                reserved2: 0,
                info: [DedupeInfo::default(); MAX_DESTINATIONS],
            };
            for (slot, (file, dest_offset)) in destinations.iter().enumerate() {
                range.info[slot].dest_fd = self.file(*file)?.as_raw_fd() as i64;
                range.info[slot].dest_offset = *dest_offset;
            }
            let source = self.file(source)?;
            if unsafe {
                libc::ioctl(source.as_raw_fd(), FIDEDUPERANGE as _, &mut range as *mut DedupeRange<MAX_DESTINATIONS>)
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(range.info[..destinations.len()]
                .iter()
                .map(|info| match info.status {
                    0 if info.bytes_deduped == length => Outcome::Same,
                    0 | 1 => Outcome::Differs,
                    errno => Outcome::Failed(errno),
                })
                .collect())
        }

        fn punch(&self, id: FileId, offset: u64, length: u64) -> io::Result<()> {
            let file = self.file(id)?;
            let mode = libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE;
            if unsafe { libc::fallocate(file.as_raw_fd(), mode, offset as libc::off_t, length as libc::off_t) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
    }
}

#[cfg(test)]
pub mod fake {
    //! An in-memory volume with reference-counted physical blocks, so tests can observe
    //! sharing, holes and the kernel's compare-before-share semantics.
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::path::PathBuf;

    #[derive(Default)]
    struct State {
        next: u64,
        physical: HashMap<u64, (Vec<u8>, usize)>,
        files: HashMap<PathBuf, Vec<Option<u64>>>,
        locked: HashMap<PathBuf, OpenMode>,
    }

    #[derive(Default)]
    pub struct FakeVolume {
        state: RefCell<State>,
        open: Vec<PathBuf>,
        pub dedupe_calls: RefCell<usize>,
    }

    impl FakeVolume {
        pub fn new() -> Self {
            Self::default()
        }

        /// A file of whole blocks; `None` is a hole.
        pub fn add(&self, path: &str, blocks: &[Option<&[u8]>]) {
            let mut state = self.state.borrow_mut();
            let mut map = Vec::new();
            for block in blocks {
                map.push(block.map(|data| {
                    let mut bytes = data.to_vec();
                    bytes.resize(BLOCK as usize, 0);
                    state.next += 1;
                    let id = state.next;
                    state.physical.insert(id, (bytes, 1));
                    id
                }));
            }
            state.files.insert(PathBuf::from(path), map);
        }

        /// A reflink copy of a whole file.
        pub fn clone_file(&self, from: &str, to: &str) {
            let mut state = self.state.borrow_mut();
            let map = state.files[&PathBuf::from(from)].clone();
            for id in map.iter().flatten() {
                state.physical.get_mut(id).unwrap().1 += 1;
            }
            state.files.insert(PathBuf::from(to), map);
        }

        pub fn write_block(&self, path: &str, block: usize, data: &[u8]) {
            let mut state = self.state.borrow_mut();
            let mut bytes = data.to_vec();
            bytes.resize(BLOCK as usize, 0);
            state.next += 1;
            let id = state.next;
            state.physical.insert(id, (bytes, 1));
            let old = state.files.get_mut(&PathBuf::from(path)).unwrap()[block].replace(id);
            if let Some(old) = old {
                release(&mut state, old);
            }
        }

        pub fn lock(&self, path: &str, mode: OpenMode) {
            self.state.borrow_mut().locked.insert(PathBuf::from(path), mode);
        }

        pub fn contents(&self, path: &str) -> Vec<u8> {
            let state = self.state.borrow();
            let mut out = Vec::new();
            for block in &state.files[&PathBuf::from(path)] {
                match block {
                    Some(id) => out.extend_from_slice(&state.physical[id].0),
                    None => out.extend(std::iter::repeat_n(0u8, BLOCK as usize)),
                }
            }
            out
        }

        /// Distinct physical blocks still allocated.
        pub fn allocated_blocks(&self) -> usize {
            self.state.borrow().physical.len()
        }

        pub fn physical(&self, path: &str, block: usize) -> Option<u64> {
            self.state.borrow().files[&PathBuf::from(path)][block]
        }
    }

    fn release(state: &mut State, id: u64) {
        let entry = state.physical.get_mut(&id).unwrap();
        entry.1 -= 1;
        if entry.1 == 0 {
            state.physical.remove(&id);
        }
    }

    impl Volume for FakeVolume {
        fn open(&mut self, path: &Path, mode: OpenMode) -> io::Result<FileId> {
            let state = self.state.borrow();
            if !state.files.contains_key(path) {
                return Err(io::Error::from(io::ErrorKind::NotFound));
            }
            if let Some(held) = state.locked.get(path) {
                if mode == OpenMode::Primary || (mode == OpenMode::Source && *held == OpenMode::Primary) {
                    return Err(io::Error::from_raw_os_error(libc::EAGAIN));
                }
            }
            drop(state);
            self.open.push(path.to_path_buf());
            Ok(self.open.len() - 1)
        }

        fn identity(&self, file: FileId) -> io::Result<Identity> {
            let state = self.state.borrow();
            let path = &self.open[file];
            let map = &state.files[path];
            let ino =
                path.to_string_lossy().bytes().fold(7u64, |hash, byte| hash.wrapping_mul(31).wrapping_add(byte as u64));
            let mtime = map.iter().flatten().fold(0i64, |sum, id| sum.wrapping_mul(17).wrapping_add(*id as i64));
            Ok(Identity { dev: 1, ino, size: map.len() as u64 * BLOCK, mtime_ns: mtime })
        }

        fn extents(&self, file: FileId) -> io::Result<Vec<Extent>> {
            let state = self.state.borrow();
            let map = &state.files[&self.open[file]];
            let mut out: Vec<Extent> = Vec::new();
            for (index, block) in map.iter().enumerate() {
                let Some(id) = block else { continue };
                let shared = state.physical[id].1 > 1;
                let logical = index as u64 * BLOCK;
                let physical = *id * BLOCK;
                if let Some(last) = out.last_mut() {
                    if last.logical + last.length == logical
                        && last.physical + last.length == physical
                        && last.shared == shared
                    {
                        last.length += BLOCK;
                        continue;
                    }
                }
                out.push(Extent { logical, physical, length: BLOCK, shared });
            }
            Ok(out)
        }

        fn read_at(&self, file: FileId, offset: u64, buf: &mut [u8]) -> io::Result<()> {
            let state = self.state.borrow();
            let map = &state.files[&self.open[file]];
            for (index, byte) in buf.iter_mut().enumerate() {
                let position = offset + index as u64;
                let block = (position / BLOCK) as usize;
                *byte = match map.get(block).copied().flatten() {
                    Some(id) => state.physical[&id].0[(position % BLOCK) as usize],
                    None => 0,
                };
            }
            Ok(())
        }

        fn dedupe(
            &self,
            source: FileId,
            offset: u64,
            length: u64,
            destinations: &[(FileId, u64)],
        ) -> io::Result<Vec<Outcome>> {
            *self.dedupe_calls.borrow_mut() += 1;
            assert!(offset % BLOCK == 0 && length % BLOCK == 0 && length > 0);
            let mut outcomes = Vec::new();
            for (dest, dest_offset) in destinations {
                assert!(dest_offset % BLOCK == 0);
                let mut source_bytes = vec![0; length as usize];
                let mut dest_bytes = vec![0; length as usize];
                self.read_at(source, offset, &mut source_bytes)?;
                self.read_at(*dest, *dest_offset, &mut dest_bytes)?;
                if source_bytes != dest_bytes {
                    outcomes.push(Outcome::Differs);
                    continue;
                }
                let mut state = self.state.borrow_mut();
                let source_path = self.open[source].clone();
                let dest_path = self.open[*dest].clone();
                for block in 0..(length / BLOCK) as usize {
                    let from = state.files[&source_path][(offset / BLOCK) as usize + block];
                    let Some(from) = from else {
                        // Sharing a hole into data is not something the kernel does; tests
                        // never ask for it.
                        panic!("dedupe from a hole");
                    };
                    state.physical.get_mut(&from).unwrap().1 += 1;
                    let slot = (dest_offset / BLOCK) as usize + block;
                    let old = state.files.get_mut(&dest_path).unwrap()[slot].replace(from);
                    if let Some(old) = old {
                        release(&mut state, old);
                    }
                }
                outcomes.push(Outcome::Same);
            }
            Ok(outcomes)
        }

        fn punch(&self, file: FileId, offset: u64, length: u64) -> io::Result<()> {
            let mut state = self.state.borrow_mut();
            let path = self.open[file].clone();
            for block in (offset / BLOCK)..((offset + length) / BLOCK) {
                let old = state.files.get_mut(&path).unwrap()[block as usize].take();
                if let Some(old) = old {
                    assert!(state.physical[&old].0.iter().all(|byte| *byte == 0), "punched a block that holds data");
                    release(&mut state, old);
                }
            }
            Ok(())
        }
    }
}
