//! Phone-resident buffers (docs/gpu-buffers.md).
//!
//! A dma-buf with [`MOD_REMOTE`] holds no pixels: they are phone GPU memory that the
//! process which rendered them registered with the GPU broker. The compositor accepts such
//! a buffer without mapping it. When a toplevel commits one, the compositor asks the broker
//! to show it in that window ([`crate::gpu_control::buffer_present`]) and keeps the
//! client's buffer until the broker reports it released, as a GPU compositor would until
//! scanout finished.
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::allocator::{Buffer as _, Format, Fourcc, Modifier};
use smithay::backend::renderer::utils::Buffer;
use std::collections::HashMap;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;

/// `CABOOSE_FORMAT_MOD_REMOTE` (guest/gpu/gbm/include/caboose_drm_formats.h).
pub const MOD_REMOTE: u64 = 0xcb << 56 | 1;

/// Formats a remote buffer can have: the GBM backend's format table.
pub const REMOTE_FORMATS: [Fourcc; 17] = [
    Fourcc::Xrgb8888, Fourcc::Argb8888, Fourcc::Xbgr8888, Fourcc::Abgr8888, Fourcc::Rgb565,
    Fourcc::Xrgb2101010, Fourcc::Argb2101010, Fourcc::Xbgr2101010, Fourcc::Abgr2101010,
    Fourcc::Xbgr16161616f, Fourcc::Abgr16161616f, Fourcc::R8, Fourcc::Gr88, Fourcc::R16, Fourcc::Gr1616,
    Fourcc::Nv12, Fourcc::P010,
];

pub fn formats() -> impl Iterator<Item = Format> {
    REMOTE_FORMATS.into_iter().map(|code| Format { code, modifier: Modifier::from(MOD_REMOTE) })
}

pub fn is_remote(dmabuf: &Dmabuf) -> bool {
    u64::from(dmabuf.format().modifier) == MOD_REMOTE
}

/// A buffer's identity: its dma-buf's device and inode. The kernel numbers dma-bufs from
/// a counter that does not repeat while it runs, and every descriptor of one buffer, in any
/// process, has the same inode. None unless every plane is in the same buffer.
pub fn identity(dmabuf: &Dmabuf) -> Option<(u64, u64)> {
    let mut planes = dmabuf.handles().map(|fd| fd.as_fd().try_clone_to_owned().ok()
        .and_then(|fd| std::fs::File::from(fd).metadata().ok())
        .map(|metadata| (metadata.dev(), metadata.ino())));
    let first = planes.next()??;
    planes.all(|plane| plane == Some(first)).then_some(first)
}

/// The buffer's implicit write fences as a sync file, when they have not all signaled:
/// a client relying on implicit synchronization commits before its rendering finished.
pub fn pending_fence(dmabuf: &Dmabuf) -> Option<OwnedFd> {
    #[repr(C)]
    struct ExportSyncFile { flags: u32, fd: i32 }
    // DMA_BUF_IOCTL_EXPORT_SYNC_FILE, _IOWR('b', 2, struct dma_buf_export_sync_file)
    const EXPORT_SYNC_FILE: libc::c_ulong = 0xc008_6202;
    const SYNC_READ: u32 = 1;  // the fences a reader waits for: the writes
    let plane = dmabuf.handles().next()?;
    let mut export = ExportSyncFile { flags: SYNC_READ, fd: -1 };
    // SAFETY: the descriptor is a live dma-buf and the argument matches the ioctl's layout.
    if unsafe { libc::ioctl(plane.as_raw_fd(), EXPORT_SYNC_FILE as _, &mut export) } != 0 || export.fd < 0 {
        return None;
    }
    // SAFETY: the kernel returned a new descriptor that nothing else owns.
    let fence = unsafe { OwnedFd::from_raw_fd(export.fd) };
    let mut ready = libc::pollfd { fd: fence.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd and a zero timeout.
    (unsafe { libc::poll(&mut ready, 1, 0) } == 0).then_some(fence)
}

/// Remote buffers the broker has been asked to show, kept until it releases them.
#[derive(Default)]
pub struct Presents {
    next: u64,
    outstanding: HashMap<u64, (u64, Buffer)>,
    /// Per window, the one present waiting for its buffer's rendering to finish.
    fenced: HashMap<u64, (u64, smithay::reexports::calloop::RegistrationToken)>,
}

impl Presents {
    /// Holds the client's buffer for a new present to `window`, returning its request ID.
    pub fn begin(&mut self, window: u64, buffer: Buffer) -> u64 {
        self.next += 1;
        self.outstanding.insert(self.next, (window, buffer));
        self.next
    }

    /// The broker released a present's buffer: dropping the last hold releases it to the
    /// client. False for an unknown request.
    pub fn released(&mut self, request: u64) -> bool {
        self.outstanding.remove(&request).is_some()
    }

    /// Whether the window has a present the broker has not released: the only windows a
    /// buffer-window bind may name.
    pub fn presenting(&self, window: u64) -> bool {
        self.outstanding.values().any(|(w, _)| *w == window)
    }

    /// Records the window's present waiting for its fence, returning the one it replaces.
    pub fn fence(&mut self, window: u64, request: u64, token: smithay::reexports::calloop::RegistrationToken)
        -> Option<(u64, smithay::reexports::calloop::RegistrationToken)> {
        self.fenced.insert(window, (request, token))
    }

    /// The present's fence signaled: it is no longer waiting. False if it was replaced.
    pub fn fence_signaled(&mut self, window: u64, request: u64) -> bool {
        if self.fenced.get(&window).is_some_and(|(r, _)| *r == request) {
            self.fenced.remove(&window);
            return true;
        }
        false
    }

    /// Releases every held buffer, when the broker can no longer report releases, and
    /// returns the fence waits to cancel.
    pub fn release_all(&mut self) -> Vec<smithay::reexports::calloop::RegistrationToken> {
        self.outstanding.clear();
        self.fenced.drain().map(|(_, (_, token))| token).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_present_holds_its_buffer_until_released() {
        let mut presents = Presents::default();
        assert!(!presents.presenting(7));
        assert!(!presents.released(1));
        assert!(presents.release_all().is_empty());
        assert!(!presents.presenting(7));
        assert!(!presents.fence_signaled(7, 1));
    }

    #[test]
    fn remote_modifier_and_formats_match_the_gbm_backend() {
        let header = include_str!("../../../gpu/gbm/include/caboose_drm_formats.h");
        assert!(header.contains("#define CABOOSE_FORMAT_MOD_REMOTE ((uint64_t)0xcb << 56 | 1)"));
        assert_eq!(MOD_REMOTE, 0xcb00_0000_0000_0001);
        let table: Vec<String> = header.lines()
            .filter_map(|line| line.trim().strip_prefix("{DRM_FORMAT_"))
            .map(|rest| rest.split(',').next().unwrap().to_string())
            .collect();
        // Each DRM format name, in the header's order, with the code it denotes.
        let named = [
            ("XRGB8888", Fourcc::Xrgb8888), ("ARGB8888", Fourcc::Argb8888), ("XBGR8888", Fourcc::Xbgr8888),
            ("ABGR8888", Fourcc::Abgr8888), ("RGB565", Fourcc::Rgb565), ("XRGB2101010", Fourcc::Xrgb2101010),
            ("ARGB2101010", Fourcc::Argb2101010), ("XBGR2101010", Fourcc::Xbgr2101010),
            ("ABGR2101010", Fourcc::Abgr2101010), ("XBGR16161616F", Fourcc::Xbgr16161616f),
            ("ABGR16161616F", Fourcc::Abgr16161616f), ("R8", Fourcc::R8), ("GR88", Fourcc::Gr88), ("R16", Fourcc::R16),
            ("GR1616", Fourcc::Gr1616), ("NV12", Fourcc::Nv12), ("P010", Fourcc::P010),
        ];
        assert_eq!(table, named.iter().map(|(name, _)| name.to_string()).collect::<Vec<_>>());
        assert_eq!(REMOTE_FORMATS.to_vec(), named.iter().map(|(_, code)| *code).collect::<Vec<_>>());
        assert!(formats().all(|format| u64::from(format.modifier) == MOD_REMOTE));
    }
}
