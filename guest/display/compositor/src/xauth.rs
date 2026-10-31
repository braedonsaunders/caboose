//! X11 authorization for Xwayland.
//!
//! Xwayland started without `-auth` falls back to host-based access control, which
//! refuses local clients in containers and minimal VMs. Like a desktop session, the
//! compositor writes a per-boot MIT-MAGIC-COOKIE-1 into an Xauthority file, starts
//! Xwayland with `-auth` on it, and gives applications `XAUTHORITY`.
//!
//! Smithay launches `Xwayland` from `PATH` with fixed arguments, so the compositor
//! puts a private directory first in Xwayland's `PATH` holding a link to its own
//! binary named `Xwayland`; invoked under that name, `caboose-display` appends
//! `-auth FILE` and executes the real Xwayland.

use std::ffi::OsString;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const REAL_ENV: &str = "CABOOSE_XWAYLAND_REAL";
const AUTH_ENV: &str = "CABOOSE_XWAYLAND_AUTH";
const FAMILY_WILD: u16 = 0xffff;

/// One Xauthority entry that matches display `number` on any host.
pub fn entry(number: u32, cookie: &[u8; 16]) -> Vec<u8> {
    // family, then address (empty: any host), display number, auth name, auth data,
    // each a big-endian u16 length and the bytes.
    let mut out = FAMILY_WILD.to_be_bytes().to_vec();
    for part in [&b""[..], number.to_string().as_bytes(), b"MIT-MAGIC-COOKIE-1", &cookie[..]] {
        out.extend_from_slice(&(part.len() as u16).to_be_bytes());
        out.extend_from_slice(part);
    }
    out
}

/// What the Xwayland launch needs.
pub struct Prepared {
    /// Environment for the Xwayland process.
    pub env: Vec<(OsString, OsString)>,
    /// The Xauthority file applications use.
    pub authority: PathBuf,
    /// The cookie in it, for the compositor's own X connections.
    pub cookie: [u8; 16],
}

fn find_in_path(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file()))
}

/// Writes the cookie and the shim link under `dir`, the instance's private directory
/// (see `Config::instance_dir`), which is made owner-only along with its parent.
pub fn prepare(dir: &Path, number: u32) -> std::io::Result<Prepared> {
    std::fs::create_dir_all(dir)?;
    for d in [Some(dir), dir.parent()].into_iter().flatten() {
        std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))?;
    }
    let mut cookie = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut cookie)?;
    let authority = dir.join("Xauthority");
    let tmp = dir.join("Xauthority.tmp");
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?
        .write_all(&entry(number, &cookie))?;
    std::fs::rename(&tmp, &authority)?;
    let real = find_in_path("Xwayland")
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "Xwayland is not on PATH"))?;
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin)?;
    let link = bin.join("Xwayland");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(std::env::current_exe()?, &link)?;
    let mut path = OsString::from(bin.as_os_str());
    if let Some(p) = std::env::var_os("PATH") {
        path.push(":");
        path.push(p);
    }
    Ok(Prepared {
        cookie,
        env: vec![
            ("PATH".into(), path),
            (REAL_ENV.into(), real.into_os_string()),
            (AUTH_ENV.into(), authority.clone().into_os_string()),
        ],
        authority,
    })
}

/// If this process was started as the `Xwayland` shim, executes the real Xwayland with
/// `-auth` added. Returns only when it is not the shim.
pub fn shim_if_invoked() {
    let mut args = std::env::args_os();
    let Some(argv0) = args.next() else { return };
    if Path::new(&argv0).file_name() != Some(std::ffi::OsStr::new("Xwayland")) {
        return;
    }
    let (Some(real), Some(auth)) = (std::env::var_os(REAL_ENV), std::env::var_os(AUTH_ENV)) else {
        eprintln!("caboose-display: started as Xwayland without {REAL_ENV}/{AUTH_ENV}");
        std::process::exit(1);
    };
    let mut argv: Vec<std::ffi::CString> = vec![std::ffi::CString::new(real.clone().into_vec()).unwrap()];
    for a in args.chain([OsString::from("-auth"), auth]) {
        argv.push(std::ffi::CString::new(a.into_vec()).unwrap());
    }
    let mut ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    // SAFETY: argv is NUL-terminated C strings and a terminating null pointer.
    unsafe { libc::execv(argv[0].as_ptr(), ptrs.as_ptr()) };
    eprintln!("caboose-display: exec {}: {}", real.to_string_lossy(), std::io::Error::last_os_error());
    std::process::exit(127);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_entry_is_family_address_number_name_data() {
        let cookie = [0xab; 16];
        let e = entry(110, &cookie);
        let mut expected = vec![0xff, 0xff, 0, 0, 0, 3, b'1', b'1', b'0', 0, 18];
        expected.extend_from_slice(b"MIT-MAGIC-COOKIE-1");
        expected.extend_from_slice(&[0, 16]);
        expected.extend_from_slice(&cookie);
        assert_eq!(e, expected);
    }
}
