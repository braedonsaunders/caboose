//! Bounded transfers through pipes, for the clipboard: applications read and write data
//! on descriptors the compositor hands them, and a slow or stuck application must
//! neither block the compositor nor hold a thread forever.

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

/// A new pipe, `(read, write)`, both close-on-exec.
pub fn pipe() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 fills the two descriptors it is given.
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: both descriptors are new and owned from here on.
    unsafe {
        Ok((
            <OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(fds[0]),
            <OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(fds[1]),
        ))
    }
}

fn set_nonblocking(fd: &OwnedFd) -> std::io::Result<()> {
    // SAFETY: fcntl on a descriptor this function borrows.
    unsafe {
        let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Waits until `fd` is ready for `events` or `deadline` passes; false on the deadline.
fn wait(fd: RawFd, events: libc::c_short, deadline: Instant) -> bool {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        let mut poll = libc::pollfd { fd, events, revents: 0 };
        let ms = left.as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: one valid pollfd.
        match unsafe { libc::poll(&mut poll, 1, ms) } {
            n if n > 0 => return true,
            0 => return false,
            _ if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted => continue,
            _ => return true, // the read or write that follows reports the error
        }
    }
}

/// Everything written to `fd` until its writer closes it: None if it is more than
/// `limit` bytes, empty, or not finished within `timeout`.
pub fn read_bounded(fd: OwnedFd, limit: usize, timeout: Duration) -> Option<Vec<u8>> {
    set_nonblocking(&fd).ok()?;
    let deadline = Instant::now() + timeout;
    let mut file = std::fs::File::from(fd);
    let mut data = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        match file.read(&mut chunk) {
            Ok(0) => return (!data.is_empty()).then_some(data),
            Ok(n) => {
                if data.len() + n > limit {
                    return None;
                }
                data.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if !wait(file.as_raw_fd(), libc::POLLIN, deadline) {
                    return None;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
}

/// Writes all of `data` to `fd`, giving up at `timeout` or when the reader goes away.
pub fn write_bounded(fd: OwnedFd, data: &[u8], timeout: Duration) -> bool {
    if set_nonblocking(&fd).is_err() {
        return false;
    }
    let deadline = Instant::now() + timeout;
    let mut file = std::fs::File::from(fd);
    let mut rest = data;
    while !rest.is_empty() {
        match file.write(rest) {
            Ok(0) => return false,
            Ok(n) => rest = &rest[n..],
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if !wait(file.as_raw_fd(), libc::POLLOUT, deadline) {
                    return false;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pipe_carries_bytes_to_the_reader() {
        let (read, write) = pipe().unwrap();
        let writer = std::thread::spawn(move || write_bounded(write, b"copied", Duration::from_secs(5)));
        assert_eq!(read_bounded(read, 1024, Duration::from_secs(5)).as_deref(), Some(&b"copied"[..]));
        assert!(writer.join().unwrap());
    }

    #[test]
    fn more_than_the_limit_is_refused() {
        let (read, write) = pipe().unwrap();
        let writer = std::thread::spawn(move || write_bounded(write, &[7u8; 300 * 1024], Duration::from_secs(5)));
        assert_eq!(read_bounded(read, 100 * 1024, Duration::from_secs(5)), None);
        // The reader is gone, so the writer stops rather than blocking.
        assert!(!writer.join().unwrap());
    }

    #[test]
    fn a_writer_that_never_finishes_times_out() {
        let (read, write) = pipe().unwrap();
        let started = Instant::now();
        assert_eq!(read_bounded(read, 1024, Duration::from_millis(200)), None);
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(write);
    }

    #[test]
    fn a_reader_that_never_reads_times_out() {
        let (read, write) = pipe().unwrap();
        // More than a pipe buffer, so the write must wait for the reader.
        assert!(!write_bounded(write, &[1u8; 1024 * 1024], Duration::from_millis(200)));
        drop(read);
    }
}
