// SPDX-License-Identifier: AGPL-3.0-or-later
//! Owner compositor's supervised private GPU broker. This is not enabled until
//! the complete broker bridge is installed and explicitly wired by the caller.
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const BROKER: &str = "/usr/local/libexec/caboose-gpu-broker";

pub struct GpuSupervisor {
    // None after close: do not leave a live channel across child teardown.
    ipc: Option<UnixStream>,
    child: Child,
}

impl GpuSupervisor {
    /// Starts exactly one child at owner-compositor startup, not on an incoming
    /// HTTP request. `token_file` is a path, never a bearer token in argv.
    pub fn start(token_file: &Path, local_socket: &Path) -> io::Result<Self> {
        let (parent, child_ipc) = UnixStream::pair()?;
        parent.set_nonblocking(true)?;
        // SAFETY: into_raw_fd transfers sole ownership into Stdio. The descriptor
        // becomes fd 0 in the child and is closed in this process after spawn.
        let input = unsafe { Stdio::from_raw_fd(child_ipc.into_raw_fd()) };
        let child = Command::new(BROKER)
            .arg("--control-fd=0")
            .arg("--token-file")
            .arg(token_file)
            .arg("--socket")
            .arg(local_socket)
            .stdin(input)
            .spawn()?;
        Ok(Self { ipc: Some(parent), child })
    }

    /// Transfer a connected TCP socket without consuming its HTTP bytes.
    /// EAGAIN leaves the caller's socket untouched, so the event loop can retry.
    pub fn handoff(&mut self, stream: &std::net::TcpStream) -> io::Result<()> {
        if self.child.try_wait()?.is_some() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker exited"));
        }
        let ipc = self.ipc.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker closed"))?;
        let marker = [b'G'];
        let mut iov = libc::iovec { iov_base: marker.as_ptr() as *mut _, iov_len: marker.len() };
        // cmsghdr requires native alignment, provided by the usize backing array.
        let mut control = [0usize; 8];
        let mut msg: libc::msghdr = unsafe { zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = unsafe { libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) as usize };
        // SAFETY: control is aligned, zeroed, and large enough for one int fd.
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&msg);
            if header.is_null() { return Err(io::Error::other("invalid control buffer")); }
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as _;
            std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>(), stream.as_raw_fd());
            let result = libc::sendmsg(ipc.as_raw_fd(), &msg, libc::MSG_NOSIGNAL);
            if result < 0 { return Err(io::Error::last_os_error()); }
            if result != 1 { return Err(io::Error::new(io::ErrorKind::WriteZero, "partial GPU handoff")); }
        }
        Ok(())
    }
}

impl Drop for GpuSupervisor {
    fn drop(&mut self) {
        self.ipc.take(); // EOF requests the owned child to stop.
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Err(_) => break,
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
                Ok(None) => break,
            }
        }
        // Only this supervisor's child is stopped; it is always reaped.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
