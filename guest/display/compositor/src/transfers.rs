//! The transfer area: files the phone uploaded through the host (`/v1/fs/transfer`, served
//! by guest/files) so applications can be given them. The phone names them by path, so
//! every path is checked against the area's layout and opened without following
//! symbolic links before an application is told about it.

use std::ffi::CString;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};

/// The area, relative to the home directory.
pub const AREA: &str = ".cache/caboose/transfers";

/// The home directory the area is in.
pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/home/caboose"))
}

/// Whether `id` is a transfer id: 32 lowercase hexadecimal digits.
pub fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Whether `name` is one path component the file service would have written.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != "."
        && name != ".."
        && !name.starts_with(".caboose-upload-")
        && !name.chars().any(|c| c == '/' || c.is_control())
}

/// The id and name of an absolute path inside the area under `home`, if it has the
/// area's shape (`<home>/<AREA>/<id>/<name>`).
pub fn parse(home: &Path, path: &str) -> Option<(String, String)> {
    let rest = path.strip_prefix(&format!("{}/{AREA}/", home.to_str()?))?;
    let (id, name) = rest.split_once('/')?;
    (valid_id(id) && valid_name(name)).then(|| (id.to_owned(), name.to_owned()))
}

fn open_at(dir: Option<&OwnedFd>, name: &str, flags: libc::c_int) -> Option<OwnedFd> {
    let name = CString::new(name).ok()?;
    let at = dir.map_or(libc::AT_FDCWD, |d| d.as_raw_fd());
    // SAFETY: a valid C string and directory descriptor; the result is checked.
    let fd = unsafe { libc::openat(at, name.as_ptr(), flags | libc::O_CLOEXEC | libc::O_NOFOLLOW) };
    // SAFETY: a new descriptor owned from here on.
    (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd) })
}

fn stat(fd: &OwnedFd) -> Option<libc::stat> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fstat fills the struct for a valid descriptor.
    (unsafe { libc::fstat(fd.as_raw_fd(), &mut st) } == 0).then_some(st)
}

/// Opens a file of the area for reading: every directory from the home down and the
/// file itself without following links, the file regular and, like the directories
/// below `.cache`, owned by this user. None for anything else.
pub fn open(home: &Path, path: &str) -> Option<(std::fs::File, u64)> {
    let (id, name) = parse(home, path)?;
    let dir = libc::O_RDONLY | libc::O_DIRECTORY;
    let mut fd = open_at(None, home.to_str()?, dir)?;
    // SAFETY: plain syscall.
    let uid = unsafe { libc::geteuid() };
    for (i, component) in AREA.split('/').chain([id.as_str()]).enumerate() {
        fd = open_at(Some(&fd), component, dir)?;
        // `.cache` may be shared with other tools; everything below it is Caboose's own.
        if i > 0 && stat(&fd)?.st_uid != uid {
            return None;
        }
    }
    let file = open_at(Some(&fd), &name, libc::O_RDONLY)?;
    let st = stat(&file)?;
    if st.st_mode & libc::S_IFMT != libc::S_IFREG || st.st_uid != uid {
        return None;
    }
    Some((std::fs::File::from(file), st.st_size as u64))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn paths_must_have_the_area_shape() {
        let home = Path::new("/home/caboose");
        let path = format!("/home/caboose/.cache/caboose/transfers/{ID}/photo 1.jpg");
        assert_eq!(parse(home, &path), Some((ID.into(), "photo 1.jpg".into())));
        for bad in [
            format!("/home/caboose/.cache/caboose/transfers/{ID}"),
            format!("/home/caboose/.cache/caboose/transfers/{ID}/a/b"),
            format!("/home/caboose/.cache/caboose/transfers/{ID}/.."),
            format!("/home/caboose/.cache/caboose/transfers/{ID}//a"),
            format!("/home/caboose/.cache/caboose/transfers/./{ID}/a"),
            format!("/home/caboose/.cache/caboose/transfers/{}/a", ID.to_uppercase()),
            "/home/caboose/.cache/caboose/transfers/short/a".to_string(),
            format!("/home/caboose/Documents/{ID}/a"),
            format!("/home/caboose/.cache/caboose/transfers/{ID}/.caboose-upload-x"),
            "/etc/passwd".to_string(),
        ] {
            assert_eq!(parse(home, &bad), None, "{bad}");
        }
    }

    #[test]
    fn files_are_opened_only_inside_the_area_without_links() {
        let home = std::env::temp_dir().join(format!("caboose-transfers-{}", std::process::id()));
        let dir = home.join(AREA).join(ID);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), b"hello").unwrap();
        std::os::unix::fs::symlink("/etc/hostname", dir.join("link")).unwrap();
        std::fs::create_dir(dir.join("sub")).unwrap();
        let path = |name: &str| dir.join(name).to_str().unwrap().to_owned();
        assert_eq!(open(&home, &path("a.txt")).map(|(_, size)| size), Some(5));
        assert!(open(&home, &path("link")).is_none());
        assert!(open(&home, &path("sub")).is_none());
        assert!(open(&home, &path("missing")).is_none());
        std::fs::remove_dir_all(&home).unwrap();
    }
}
