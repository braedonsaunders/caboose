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
use std::sync::atomic::{AtomicBool, Ordering};

const BROKER: &str = "/usr/local/libexec/caboose-gpu-broker";

pub struct GpuSupervisor {
    // None after close: do not leave a live channel across child teardown.
    ipc: Option<UnixStream>,
    child: Child,
}

impl GpuSupervisor {
    /// Starts exactly one child at owner-compositor startup, not on an incoming
    /// HTTP request. `token_file` is a path, never a bearer token in argv.
    pub fn start(token_file: &Path, local_socket: &Path, surface_socket: &Path) -> io::Result<Self> {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let parent = local_socket.parent().ok_or_else(|| io::Error::other("missing GPU socket directory"))?;
        if surface_socket.parent() != Some(parent) || local_socket == surface_socket {
            return Err(io::Error::other("invalid GPU socket paths"));
        }
        let metadata = std::fs::symlink_metadata(parent)?;
        let missing = |path: &Path| match std::fs::symlink_metadata(path) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(true),
            Ok(_) => Ok(false),
            Err(error) => Err(error),
        };
        // SAFETY: geteuid has no arguments or memory-safety preconditions.
        if !metadata.is_dir() || metadata.file_type().is_symlink() || metadata.uid() != unsafe { libc::geteuid() } ||
            metadata.permissions().mode() & 0o7777 != 0o700 || !missing(local_socket)? || !missing(surface_socket)? {
            return Err(io::Error::other("GPU socket directory is not private or sockets exist"));
        }
        let mut fds = [-1; 2];
        // SAFETY: fds points to two writable integers for a local socketpair.
        let result = unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) };
        if result < 0 { return Err(io::Error::last_os_error()); }
        // SAFETY: successful socketpair returns two distinct owned descriptors.
        let parent = unsafe { UnixStream::from_raw_fd(fds[0]) };
        let child_ipc = unsafe { UnixStream::from_raw_fd(fds[1]) };
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
            .arg("--surface-socket")
            .arg(surface_socket)
            .stdin(input)
            .spawn()?;
        Ok(Self { ipc: Some(parent), child })
    }

    pub fn clone_ipc(&mut self) -> io::Result<UnixStream> {
        if self.child.try_wait()?.is_some() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker exited"));
        }
        self.ipc.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker closed"))?.try_clone()
    }
}

fn send_once(ipc: &UnixStream, stream: &std::net::TcpStream) -> io::Result<()> {
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

/// Classify only the HTTP request target, retaining all bytes for the selected
/// handler. Run on a bounded routing worker, not on the compositor event loop.
/// A finite sleep is deliberate: peek does not consume partial bytes, so edge
/// readiness alone cannot guarantee a second notification.
pub fn is_gpu_request(stream: &std::net::TcpStream, stop: &AtomicBool, timeout: Duration) -> io::Result<bool> {
    stream.set_nonblocking(true)?;
    let deadline = Instant::now() + timeout;
    let mut data = [0u8; 8192];
    loop {
        if stop.load(Ordering::Acquire) { return Err(io::Error::new(io::ErrorKind::Interrupted, "GPU router stopped")); }
        match stream.peek(&mut data) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "empty HTTP request")),
            Ok(n) => {
                if let Some(end) = data[..n].windows(2).position(|v| v == b"\r\n") {
                    return Ok(request_is_gpu(&data[..end]));
                }
                if n == data.len() { return Err(io::Error::new(io::ErrorKind::InvalidData, "HTTP request line too long")); }
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        if Instant::now() >= deadline { return Err(io::Error::new(io::ErrorKind::TimedOut, "HTTP route timeout")); }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn request_is_gpu(line: &[u8]) -> bool {
    let mut parts = line.split(|b| *b == b' ');
    let method = parts.next();
    let target = parts.next();
    let version = parts.next();
    if parts.next().is_some() || method != Some(&b"GET"[..]) || version != Some(&b"HTTP/1.1"[..]) {
        return false;
    }
    target.unwrap_or_default().split(|b| *b == b'?').next().unwrap_or_default() == b"/gpu"
}

#[cfg(test)]
mod tests {
    use super::request_is_gpu;
    #[test]
    fn classify_request_without_reading_or_trusting_headers() {
        assert!(request_is_gpu(b"GET /gpu HTTP/1.1"));
        assert!(request_is_gpu(b"GET /gpu?bad HTTP/1.1"));
        assert!(!request_is_gpu(b"GET /display HTTP/1.1"));
        assert!(!request_is_gpu(b"GET /gpu-extra HTTP/1.1"));
        assert!(!request_is_gpu(b"POST /gpu HTTP/1.1"));
    }

    #[test]
    fn fragmented_request_is_peeked_without_consuming_bytes() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let client = std::thread::spawn(move || {
            let mut stream = std::net::TcpStream::connect(address).unwrap();
            stream.write_all(b"GET /g").unwrap();
            std::thread::sleep(std::time::Duration::from_millis(20));
            stream.write_all(b"pu HTTP/1.1\r\n").unwrap();
        });
        let (mut stream, _) = listener.accept().unwrap();
        let stop = std::sync::atomic::AtomicBool::new(false);
        assert!(super::is_gpu_request(&stream, &stop, std::time::Duration::from_secs(1)).unwrap());
        let mut request = [0u8; 19];
        stream.read_exact(&mut request).unwrap();
        assert_eq!(&request, b"GET /gpu HTTP/1.1\r\n");
        client.join().unwrap();
    }

    #[test]
    fn seqpacket_handoff_transfers_one_connected_tcp_fd() {
        use std::io::{Read, Write};
        use std::os::fd::{AsRawFd, FromRawFd};
        let mut fds = [-1; 2];
        // SAFETY: fds is valid writable storage for a socketpair.
        assert_eq!(unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) }, 0);
        // SAFETY: each returned descriptor is owned exactly once.
        let sender = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fds[0]) };
        let receiver = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fds[1]) };
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (accepted, _) = listener.accept().unwrap();
        super::send_once(&sender, &accepted).unwrap();
        let mut byte = [0u8; 1];
        let mut iov = libc::iovec { iov_base: byte.as_mut_ptr().cast(), iov_len: 1 };
        let mut control = [0usize; 8];
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov; msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = unsafe { libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) as usize };
        // SAFETY: msghdr buffers are aligned and valid for recvmsg.
        assert_eq!(unsafe { libc::recvmsg(receiver.as_raw_fd(), &mut msg, 0) }, 1);
        assert_eq!(byte, [b'G']);
        assert_eq!(msg.msg_flags & libc::MSG_CTRUNC, 0);
        let header = unsafe { libc::CMSG_FIRSTHDR(&msg) };
        assert!(!header.is_null());
        assert_eq!(unsafe { (*header).cmsg_level }, libc::SOL_SOCKET);
        assert_eq!(unsafe { (*header).cmsg_type }, libc::SCM_RIGHTS);
        let raw = unsafe { std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>()) };
        // SAFETY: SCM_RIGHTS returned a new descriptor owned by this test.
        let mut forwarded = unsafe { std::net::TcpStream::from_raw_fd(raw) };
        client.write_all(b"unchanged").unwrap();
        let mut bytes = [0u8; 9]; forwarded.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"unchanged");
    }

}

/// Wait for actual IPC writable readiness without blocking the compositor loop.
/// Caller retains the TCP socket unless this function returns success.
pub fn handoff_wait(ipc: &UnixStream, stream: &std::net::TcpStream, stop: &AtomicBool, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        if stop.load(Ordering::Acquire) { return Err(io::Error::new(io::ErrorKind::Interrupted, "GPU router stopped")); }
        match send_once(ipc, stream) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
        if Instant::now() >= deadline { return Err(io::Error::new(io::ErrorKind::TimedOut, "GPU broker backpressure")); }
        let mut fd = libc::pollfd { fd: ipc.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
        let result = unsafe { libc::poll(&mut fd, 1, 100) };
        if result < 0 {
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted { return Err(e); }
        }
        if fd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker closed"));
        }
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

/// Bounded routing workers leave the compositor's event loop nonblocking.
/// The callback returns ordinary display sockets to the event loop unchanged.
struct RoutePermit(std::sync::Arc<std::sync::atomic::AtomicUsize>);
impl Drop for RoutePermit {
    fn drop(&mut self) { self.0.fetch_sub(1, Ordering::AcqRel); }
}

/// The route permit remains occupied until the compositor consumes the socket.
pub struct RoutedDisplay {
    stream: Option<std::net::TcpStream>,
    peer: std::net::SocketAddr,
    _permit: RoutePermit,
}

impl RoutedDisplay {
    pub fn into_parts(mut self) -> (std::net::TcpStream, std::net::SocketAddr) {
        (self.stream.take().expect("route consumed once"), self.peer)
    }
}

pub enum RouteEvent {
    Display(RoutedDisplay),
    ControlSent(Option<crate::gpu_grant::Grant>),
    ControlFailed,
}

fn send_control_wait(ipc: &UnixStream, data: &[u8], stop: &AtomicBool) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if stop.load(Ordering::Acquire) { return Err(io::Error::new(io::ErrorKind::Interrupted, "GPU router stopped")); }
        // SAFETY: data points to the complete immutable sequenced-packet record.
        let result = unsafe { libc::send(ipc.as_raw_fd(), data.as_ptr().cast(), data.len(), libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL) };
        if result == data.len() as isize { return Ok(()); }
        if result >= 0 { return Err(io::Error::new(io::ErrorKind::WriteZero, "partial GPU control record")); }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::WouldBlock { return Err(error); }
        if Instant::now() >= deadline { return Err(io::Error::new(io::ErrorKind::TimedOut, "GPU control backpressure")); }
        let mut fd = libc::pollfd { fd: ipc.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
        // SAFETY: fd is a valid pollfd and the timeout is bounded.
        let result = unsafe { libc::poll(&mut fd, 1, 100) };
        if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted { return Err(io::Error::last_os_error()); }
        if fd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "GPU broker closed"));
        }
    }
}

pub struct GpuRouter {
    supervisor: GpuSupervisor,
    stop: std::sync::Arc<AtomicBool>,
    active: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    workers: Vec<std::thread::JoinHandle<()>>,
    deliver: std::sync::Arc<dyn Fn(RouteEvent) + Send + Sync>,
    control_tx: std::sync::mpsc::SyncSender<(Vec<u8>, Option<crate::gpu_grant::Grant>)>,
    control_worker: Option<std::thread::JoinHandle<()>>,
}

impl GpuRouter {
    pub fn available(&self) -> bool { !self.stop.load(Ordering::Acquire) }
    pub fn start(
        token_file: &Path,
        local_socket: &Path,
        surface_socket: &Path,
        deliver: impl Fn(RouteEvent) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let mut supervisor = GpuSupervisor::start(token_file, local_socket, surface_socket)?;
        let ipc = supervisor.clone_ipc()?;
        let stop = std::sync::Arc::new(AtomicBool::new(false));
        let deliver: std::sync::Arc<dyn Fn(RouteEvent) + Send + Sync> = std::sync::Arc::new(deliver);
        let (control_tx, control_rx) = std::sync::mpsc::sync_channel::<(Vec<u8>, Option<crate::gpu_grant::Grant>)>(64);
        let worker_stop = stop.clone();
        let worker_deliver = deliver.clone();
        let control_worker = std::thread::Builder::new().name("caboose-gpu-control".into()).spawn(move || {
            while !worker_stop.load(Ordering::Acquire) {
                match control_rx.recv_timeout(Duration::from_millis(100)) {
                    Ok((data, grant)) => match send_control_wait(&ipc, &data, &worker_stop) {
                        Ok(()) => worker_deliver(RouteEvent::ControlSent(grant)),
                        Err(_) => { worker_deliver(RouteEvent::ControlFailed); break; }
                    },
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {},
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
        })?;
        Ok(Self { supervisor, stop, active: std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            workers: Vec::new(), deliver, control_tx, control_worker: Some(control_worker) })
    }

    pub fn clone_control(&mut self) -> io::Result<UnixStream> { self.supervisor.clone_ipc() }

    pub fn fail(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(ipc) = &self.supervisor.ipc { let _ = ipc.shutdown(std::net::Shutdown::Both); }
    }

    pub fn queue_control(&self, data: Vec<u8>, revoke: Option<crate::gpu_grant::Grant>) -> io::Result<()> {
        if data.len() > 80 { return Err(io::Error::new(io::ErrorKind::InvalidInput, "oversized GPU control record")); }
        self.control_tx.try_send((data, revoke)).map_err(|_| io::Error::other("GPU control queue unavailable"))
    }

    /// Takes ownership, including on rejection. At most 64 workers exist at once.
    pub fn accept(&mut self, stream: std::net::TcpStream, peer: std::net::SocketAddr) -> io::Result<()> {
        if self.stop.load(Ordering::Acquire) { return Err(io::Error::other("GPU router stopped")); }
        let mut running = Vec::new();
        for worker in self.workers.drain(..) {
            if worker.is_finished() { let _ = worker.join(); } else { running.push(worker); }
        }
        self.workers = running;
        if self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < 64).then_some(n + 1)).is_err() {
            return Err(io::Error::other("GPU route capacity"));
        }
        let ipc = self.supervisor.clone_ipc().ok();
        let stop = self.stop.clone();
        let active = self.active.clone();
        let deliver = self.deliver.clone();
        let spawned = std::thread::Builder::new().name("caboose-gpu-route".into()).spawn(move || {
            let permit = RoutePermit(active);
            match is_gpu_request(&stream, &stop, Duration::from_secs(5)) {
                Ok(true) => {
                    if let Some(ipc) = ipc {
                        let _ = handoff_wait(&ipc, &stream, &stop, Duration::from_secs(5));
                    }
                }
                Ok(false) if !stop.load(Ordering::Acquire) => deliver(RouteEvent::Display(RoutedDisplay {
                    stream: Some(stream), peer, _permit: permit,
                })),
                _ => {}
            }
        });
        match spawned {
            Ok(worker) => { self.workers.push(worker); Ok(()) }
            Err(error) => { self.active.fetch_sub(1, Ordering::AcqRel); Err(error) }
        }
    }
}

impl Drop for GpuRouter {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        for worker in self.workers.drain(..) { let _ = worker.join(); }
        if let Some(worker) = self.control_worker.take() { let _ = worker.join(); }
        // GpuSupervisor then closes IPC and waits for its owned broker child.
    }
}
