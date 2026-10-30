//! Kernel-bound identity of an accepted native Wayland peer.
//! An absent or dead identity never authorizes a GPU surface grant.
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

const SO_PEERPIDFD: libc::c_int = 77;

pub struct GpuPeer {
    pub uid: u32,
    pub pid: u32,
    pub start_ticks: u64,
    pidfd: OwnedFd,
}

fn start_ticks(stat: &str) -> Option<u64> {
    let (_, rest) = stat.rsplit_once(") ")?;
    rest.split_ascii_whitespace().nth(19)?.parse().ok()
}

fn pid_from_fdinfo(fd: i32) -> io::Result<u32> {
    let text = std::fs::read_to_string(format!("/proc/self/fdinfo/{fd}"))?;
    let mut values = text.lines().filter_map(|line| line.strip_prefix("Pid:"));
    let pid = values.next().and_then(|s| s.trim().parse::<u32>().ok())
        .filter(|pid| *pid != 0).ok_or_else(|| io::Error::other("invalid peer pidfd"))?;
    if values.next().is_some() { return Err(io::Error::other("duplicate peer pidfd")); }
    Ok(pid)
}

impl GpuPeer {
    pub fn capture(stream: &UnixStream) -> io::Result<Self> {
        let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: credentials and length point to writable, correctly sized objects.
        let result = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(), &mut length) };
        if result < 0 { return Err(io::Error::last_os_error()); }
        if length as usize != std::mem::size_of::<libc::ucred>() || credentials.pid <= 0 {
            return Err(io::Error::other("invalid Wayland peer credentials"));
        }
        let mut raw_fd: libc::c_int = -1;
        length = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        // SAFETY: raw_fd and length are correctly sized for SO_PEERPIDFD.
        let result = unsafe { libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, SO_PEERPIDFD,
            (&mut raw_fd as *mut libc::c_int).cast(), &mut length) };
        if result < 0 { return Err(io::Error::last_os_error()); }
        if raw_fd < 0 { return Err(io::Error::other("invalid Wayland peer pidfd")); }
        // SAFETY: getsockopt returned a new owned descriptor.
        let pidfd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        if length as usize != std::mem::size_of::<libc::c_int>() { return Err(io::Error::other("invalid pidfd size")); }
        let flags = unsafe { libc::fcntl(raw_fd, libc::F_GETFD) };
        if flags < 0 || unsafe { libc::fcntl(raw_fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let pid = credentials.pid as u32;
        let mut peer = Self { uid: credentials.uid, pid, start_ticks: 0, pidfd };
        if !peer.alive() || pid_from_fdinfo(raw_fd)? != pid { return Err(io::Error::other("Wayland peer exited")); }
        let text = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
        peer.start_ticks = start_ticks(&text).ok_or_else(|| io::Error::other("invalid process start time"))?;
        if !peer.alive() || pid_from_fdinfo(raw_fd)? != pid { return Err(io::Error::other("Wayland peer changed")); }
        Ok(peer)
    }

    pub fn alive(&self) -> bool {
        let mut fd = libc::pollfd { fd: self.pidfd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: pollfd is valid and polling with zero timeout never blocks.
        unsafe { libc::poll(&mut fd, 1, 0) == 0 }
    }
}

#[cfg(test)]
mod tests {
    use super::{start_ticks, GpuPeer};
    #[test]
    fn captures_the_actual_socket_peer() {
        let (a, _b) = std::os::unix::net::UnixStream::pair().unwrap();
        let peer = GpuPeer::capture(&a).unwrap();
        assert_eq!(peer.pid, std::process::id());
        assert_eq!(peer.uid, unsafe { libc::getuid() });
        assert!(peer.alive());
    }

    #[test]
    fn parses_start_ticks_after_complex_comm() {
        let stat = format!("42 (space ) inside) S {} 9123 0", vec!["1"; 18].join(" "));
        assert_eq!(start_ticks(&stat), Some(9123));
        assert_eq!(start_ticks("42 (broken) S 1"), None);
    }
}
