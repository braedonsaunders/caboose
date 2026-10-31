//! The computer's render node (docs/gpu-buffers.md).
//!
//! The render node is the kernel's vgem device. Clients allocate buffers on it through
//! the Caboose GBM backend (guest/gpu/gbm) and hand them over linux-dmabuf; the
//! compositor names it as the main device of its dma-buf feedback, so a client knows
//! which device to allocate on without scanning for one.
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};

/// The vgem render node: its device number and path, when the computer has one.
pub fn find() -> Option<(libc::dev_t, PathBuf)> {
    find_in(Path::new("/dev/dri"), Path::new("/sys/class/drm"))
}

fn find_in(dev: &Path, sys: &Path) -> Option<(libc::dev_t, PathBuf)> {
    let mut nodes: Vec<_> = std::fs::read_dir(dev).ok()?.flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("renderD"))
        .collect();
    nodes.sort_by_key(|entry| entry.file_name());
    nodes.into_iter().find_map(|entry| {
        let name = entry.file_name();
        // vgem is a platform device without a bound driver: the node's device is it.
        let device = std::fs::read_link(sys.join(&name).join("device")).ok()?;
        if device.file_name()? != "vgem" { return None; }
        let metadata = std::fs::metadata(entry.path()).ok()?;
        metadata.file_type().is_char_device().then(|| (metadata.rdev() as libc::dev_t, entry.path()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_only_a_vgem_render_node() {
        let root = std::env::temp_dir().join(format!("caboose-render-node-{}", std::process::id()));
        let (dev, sys) = (root.join("dev"), root.join("sys"));
        std::fs::create_dir_all(&dev).unwrap();
        // As sysfs has them: a PCI GPU's node and the vgem platform device's node.
        for (node, device) in [("renderD128", "0000:01:00.0"), ("renderD129", "vgem")] {
            std::fs::create_dir_all(sys.join(node)).unwrap();
            std::fs::create_dir_all(root.join("devices").join(device)).unwrap();
            std::os::unix::fs::symlink(root.join("devices").join(device), sys.join(node).join("device")).unwrap();
        }
        // Regular files stand in for the nodes: neither is a character device.
        std::fs::write(dev.join("renderD128"), b"").unwrap();
        std::fs::write(dev.join("renderD129"), b"").unwrap();
        assert!(find_in(&dev, &sys).is_none());
        // /dev/null is a character device: a vgem node that is one is found, past the
        // other driver's node.
        std::fs::remove_file(dev.join("renderD129")).unwrap();
        std::os::unix::fs::symlink("/dev/null", dev.join("renderD129")).unwrap();
        std::fs::remove_file(dev.join("renderD128")).unwrap();
        std::os::unix::fs::symlink("/dev/null", dev.join("renderD128")).unwrap();
        let (_, path) = find_in(&dev, &sys).unwrap();
        assert_eq!(path, dev.join("renderD129"));
        std::fs::remove_dir_all(root).unwrap();
    }
}
