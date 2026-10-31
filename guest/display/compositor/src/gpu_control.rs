//! Exact CGB1 sequenced control records. No Vulkan commands are decoded here.
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

/// A bind's object: a Wayland client's wl_surface protocol ID, or an X11 window ID.
pub const WAYLAND_SURFACE: u32 = 0;
pub const X11_WINDOW: u32 = 1;
/// A compositor window showing phone-resident buffers the bound process rendered
/// (docs/gpu-buffers.md); the object is the window ID.
pub const BUFFER_WINDOW: u32 = 2;

#[derive(Debug)]
pub struct Bind {
    pub request: u64,
    pub process: u64,
    pub uid: u32,
    pub pid: u32,
    pub start_ticks: u64,
    pub object: u32,
    pub space: u32,
    pub pidfd: OwnedFd,
}

#[derive(Debug)]
pub enum Record {
    Bind(Bind),
    SurfaceRetired { epoch: [u8; 16], grant: [u8; 16], generation: u64 },
    RevokeRequest { epoch: [u8; 16], grant: [u8; 16], generation: u64 },
    Lifecycle { kind: u16, executor: [u8; 16], generation: u64 },
    /// A buffer present's buffer is free; status 0 when it was shown, else an errno.
    BufferReleased { request: u64, status: i32 },
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 { u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap()) }
fn u32_at(bytes: &[u8], offset: usize) -> u32 { u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) }
fn u64_at(bytes: &[u8], offset: usize) -> u64 { u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap()) }
fn invalid() -> io::Error { io::Error::new(io::ErrorKind::InvalidData, "invalid GPU control record") }

/// Receive one whole record. Every received descriptor becomes owned before any
/// parse error, so malformed packets cannot leak SCM_RIGHTS descriptors.
pub fn receive(socket: &UnixStream) -> io::Result<Record> {
    let mut data = [0u8; 81];
    let mut iov = libc::iovec { iov_base: data.as_mut_ptr().cast(), iov_len: data.len() };
    let mut control = [0usize; 16];
    let mut msg: libc::msghdr = unsafe { zeroed() };
    msg.msg_iov = &mut iov; msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = std::mem::size_of_val(&control);
    // SAFETY: the iovec and ancillary buffers are aligned and valid.
    let size = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut msg, libc::MSG_DONTWAIT | libc::MSG_CMSG_CLOEXEC) };
    if size < 0 { return Err(io::Error::last_os_error()); }
    let mut fds: Vec<OwnedFd> = Vec::new();
    let mut bad_control = false;
    // SAFETY: recvmsg populated the control list within the supplied buffer.
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&msg);
        while !header.is_null() {
            let base = libc::CMSG_LEN(0) as usize;
            let length = (*header).cmsg_len as usize;
            if (*header).cmsg_level != libc::SOL_SOCKET || (*header).cmsg_type != libc::SCM_RIGHTS || length < base {
                bad_control = true;
            } else {
                let bytes = length - base;
                if bytes % size_of::<libc::c_int>() != 0 { bad_control = true; }
                for index in 0..bytes / size_of::<libc::c_int>() {
                    let fd = std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>().add(index));
                    if fd < 0 { bad_control = true; } else { fds.push(OwnedFd::from_raw_fd(fd)); }
                }
            }
            header = libc::CMSG_NXTHDR(&msg, header);
        }
    }
    if bad_control || msg.msg_flags & (libc::MSG_CTRUNC | libc::MSG_TRUNC) != 0 { return Err(invalid()); }
    let data = &data[..size as usize];
    if data.len() < 16 || &data[..4] != b"CGB1" || u16_at(data, 4) != 1 ||
        u32_at(data, 8) as usize != data.len() || u32_at(data, 12) != 0 { return Err(invalid()); }
    match u16_at(data, 6) {
        1 if data.len() == 56 && fds.len() == 1 && matches!(u32_at(data, 52), WAYLAND_SURFACE | X11_WINDOW | BUFFER_WINDOW) => {
            let (request, process, uid, pid, start_ticks, object, space) = (u64_at(data, 16), u64_at(data, 24),
                u32_at(data, 32), u32_at(data, 36), u64_at(data, 40), u32_at(data, 48), u32_at(data, 52));
            if request == 0 || process == 0 || pid == 0 || start_ticks == 0 || object == 0 { return Err(invalid()); }
            Ok(Record::Bind(Bind { request, process, uid, pid, start_ticks, object, space, pidfd: fds.pop().unwrap() }))
        }
        kind @ (7 | 8) if data.len() == 64 && fds.is_empty() && u64_at(data, 56) == 0 => {
            let epoch: [u8; 16] = data[16..32].try_into().unwrap();
            let grant: [u8; 16] = data[32..48].try_into().unwrap();
            let generation = u64_at(data, 48);
            if epoch == [0; 16] || grant == [0; 16] || generation == 0 { return Err(invalid()); }
            if kind == 7 { Ok(Record::SurfaceRetired { epoch, grant, generation }) }
            else { Ok(Record::RevokeRequest { epoch, grant, generation }) }
        }
        10 if data.len() == 32 && fds.is_empty() && u32_at(data, 28) == 0 => {
            let (request, status) = (u64_at(data, 16), u32_at(data, 24) as i32);
            if request == 0 || status < 0 { return Err(invalid()); }
            Ok(Record::BufferReleased { request, status })
        }
        kind @ 4..=6 if data.len() == 48 && fds.is_empty() && u64_at(data, 40) == 0 => {
            let executor: [u8; 16] = data[16..32].try_into().unwrap();
            let generation = u64_at(data, 32);
            if executor == [0; 16] || generation == 0 { return Err(invalid()); }
            Ok(Record::Lifecycle { kind, executor, generation })
        }
        _ => Err(invalid()),
    }
}

pub fn response(request: u64, grant: Option<crate::gpu_grant::Grant>) -> io::Result<Vec<u8>> {
    if request == 0 { return Err(invalid()); }
    let mut data = vec![0u8; 80];
    data[..4].copy_from_slice(b"CGB1"); data[4..6].copy_from_slice(&1u16.to_le_bytes());
    data[6..8].copy_from_slice(&2u16.to_le_bytes()); data[8..12].copy_from_slice(&80u32.to_le_bytes());
    data[16..24].copy_from_slice(&request.to_le_bytes());
    if let Some(grant) = grant {
        if grant.epoch == [0; 16] || grant.token == [0; 16] || grant.window == 0 || grant.generation == 0 { return Err(invalid()); }
        data[32..48].copy_from_slice(&grant.epoch); data[48..64].copy_from_slice(&grant.token);
        data[64..72].copy_from_slice(&grant.window.to_le_bytes()); data[72..80].copy_from_slice(&grant.generation.to_le_bytes());
    } else {
        data[24..28].copy_from_slice(&1u32.to_le_bytes());
    }
    Ok(data)
}

/// Asks the broker to show a committed remote buffer, named by its dma-buf's device and
/// inode, in a window.
pub fn buffer_present(request: u64, window: u64, buffer: (u64, u64), width: u32, height: u32) -> io::Result<Vec<u8>> {
    if request == 0 || window == 0 || buffer.1 == 0 || width == 0 || height == 0 { return Err(invalid()); }
    let mut data = vec![0u8; 56];
    data[..4].copy_from_slice(b"CGB1"); data[4..6].copy_from_slice(&1u16.to_le_bytes());
    data[6..8].copy_from_slice(&9u16.to_le_bytes()); data[8..12].copy_from_slice(&56u32.to_le_bytes());
    data[16..24].copy_from_slice(&request.to_le_bytes()); data[24..32].copy_from_slice(&window.to_le_bytes());
    data[32..40].copy_from_slice(&buffer.0.to_le_bytes()); data[40..48].copy_from_slice(&buffer.1.to_le_bytes());
    data[48..52].copy_from_slice(&width.to_le_bytes()); data[52..56].copy_from_slice(&height.to_le_bytes());
    Ok(data)
}

pub fn revoke(grant: crate::gpu_grant::Grant) -> io::Result<Vec<u8>> {
    if grant.epoch == [0; 16] || grant.token == [0; 16] || grant.generation == 0 { return Err(invalid()); }
    let mut data = vec![0u8; 64];
    data[..4].copy_from_slice(b"CGB1"); data[4..6].copy_from_slice(&1u16.to_le_bytes());
    data[6..8].copy_from_slice(&3u16.to_le_bytes()); data[8..12].copy_from_slice(&64u32.to_le_bytes());
    data[16..32].copy_from_slice(&grant.epoch); data[32..48].copy_from_slice(&grant.token);
    data[48..56].copy_from_slice(&grant.generation.to_le_bytes());
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn pair() -> (UnixStream, UnixStream) {
        let mut fds = [-1; 2];
        // SAFETY: fds is valid writable storage for two descriptors.
        assert_eq!(unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0, fds.as_mut_ptr()) }, 0);
        // SAFETY: each returned descriptor is owned exactly once.
        unsafe { (UnixStream::from_raw_fd(fds[0]), UnixStream::from_raw_fd(fds[1])) }
    }

    #[test]
    fn receives_lifecycle_and_rejects_truncation() {
        let (mut sender, receiver) = pair();
        let mut packet = vec![0u8; 48];
        packet[..4].copy_from_slice(b"CGB1"); packet[4..6].copy_from_slice(&1u16.to_le_bytes());
        packet[6..8].copy_from_slice(&4u16.to_le_bytes()); packet[8..12].copy_from_slice(&48u32.to_le_bytes());
        packet[16..32].fill(2); packet[32..40].copy_from_slice(&7u64.to_le_bytes());
        sender.write_all(&packet).unwrap();
        match receive(&receiver).unwrap() {
            Record::Lifecycle { kind, executor, generation } => {
                assert_eq!(kind, 4); assert_eq!(executor, [2; 16]); assert_eq!(generation, 7);
            }
            _ => panic!("expected lifecycle"),
        }
        sender.write_all(&packet[..47]).unwrap();
        assert_eq!(receive(&receiver).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    fn own_pidfd() -> OwnedFd {
        // SAFETY: pidfd_open receives this process's live PID and zero flags.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, libc::getpid(), 0) as i32 };
        assert!(raw >= 0);
        // SAFETY: pidfd_open returned a new owned descriptor.
        unsafe { OwnedFd::from_raw_fd(raw) }
    }

    fn bind_packet(peer: &crate::gpu_peer::GpuPeer, object: u32, space: u32) -> [u8; 56] {
        let mut packet = [0u8; 56];
        packet[..4].copy_from_slice(b"CGB1"); packet[4..6].copy_from_slice(&1u16.to_le_bytes());
        packet[6..8].copy_from_slice(&1u16.to_le_bytes()); packet[8..12].copy_from_slice(&56u32.to_le_bytes());
        packet[16..24].copy_from_slice(&1u64.to_le_bytes()); packet[24..32].copy_from_slice(&3u64.to_le_bytes());
        packet[32..36].copy_from_slice(&peer.uid.to_le_bytes()); packet[36..40].copy_from_slice(&peer.pid.to_le_bytes());
        packet[40..48].copy_from_slice(&peer.start_ticks.to_le_bytes()); packet[48..52].copy_from_slice(&object.to_le_bytes());
        packet[52..56].copy_from_slice(&space.to_le_bytes());
        packet
    }

    fn send_with_fd(sender: &UnixStream, mut packet: [u8; 56], pidfd: &OwnedFd) {
        use std::os::fd::AsRawFd;
        let mut iov = libc::iovec { iov_base: packet.as_mut_ptr().cast(), iov_len: packet.len() };
        let mut control = [0usize; 8];
        let mut msg: libc::msghdr = unsafe { zeroed() };
        msg.msg_iov = &mut iov; msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = unsafe { libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) as usize };
        // SAFETY: the ancillary buffer is aligned and sized for one descriptor.
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&msg);
            (*header).cmsg_level = libc::SOL_SOCKET; (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as _;
            std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>(), pidfd.as_raw_fd());
            assert_eq!(libc::sendmsg(sender.as_raw_fd(), &msg, 0), 56);
        }
    }

    #[test]
    fn receives_real_pidfd_for_wayland_peer_match() {
        use std::os::fd::AsRawFd;
        let (wayland, _other) = UnixStream::pair().unwrap();
        let peer = crate::gpu_peer::GpuPeer::capture(&wayland).unwrap();
        let pidfd = own_pidfd();
        let (sender, receiver) = pair();
        send_with_fd(&sender, bind_packet(&peer, 17, WAYLAND_SURFACE), &pidfd);
        let Record::Bind(bind) = receive(&receiver).unwrap() else { panic!("expected bind") };
        assert_eq!((bind.request, bind.process, bind.object, bind.space), (1, 3, 17, WAYLAND_SURFACE));
        assert!(peer.matches_pidfd(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()));
    }

    #[test]
    fn bind_names_an_x11_window_and_no_other_namespace() {
        use std::os::fd::AsRawFd;
        let (socket, _other) = UnixStream::pair().unwrap();
        let peer = crate::gpu_peer::GpuPeer::capture(&socket).unwrap();
        let pidfd = own_pidfd();
        let (sender, receiver) = pair();
        send_with_fd(&sender, bind_packet(&peer, 0x400003, X11_WINDOW), &pidfd);
        let Record::Bind(bind) = receive(&receiver).unwrap() else { panic!("expected bind") };
        assert_eq!((bind.object, bind.space), (0x400003, X11_WINDOW));
        assert!(crate::gpu_peer::pidfd_identifies(bind.uid, bind.pid, bind.start_ticks, bind.pidfd.as_raw_fd()));
        send_with_fd(&sender, bind_packet(&peer, 9, BUFFER_WINDOW), &pidfd);
        let Record::Bind(bind) = receive(&receiver).unwrap() else { panic!("expected bind") };
        assert_eq!((bind.object, bind.space), (9, BUFFER_WINDOW));
        send_with_fd(&sender, bind_packet(&peer, 0x400003, 3), &pidfd);
        assert_eq!(receive(&receiver).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn buffer_present_and_release_match_the_broker_records() {
        // Byte-for-byte what guest/gpu/gfxstream/control_protocol.py encodes.
        let present = buffer_present(1, 7, (0x10, 1 << 40), 1920, 1080).unwrap();
        assert_eq!(present.len(), 56);
        assert_eq!((u16_at(&present, 6), u64_at(&present, 16), u64_at(&present, 24)), (9, 1, 7));
        assert_eq!((u64_at(&present, 32), u64_at(&present, 40)), (0x10, 1 << 40));
        assert_eq!((u32_at(&present, 48), u32_at(&present, 52)), (1920, 1080));
        assert!(buffer_present(1, 7, (1, 0), 1, 1).is_err());
        let (mut sender, receiver) = pair();
        let mut released = vec![0u8; 32];
        released[..4].copy_from_slice(b"CGB1"); released[4..6].copy_from_slice(&1u16.to_le_bytes());
        released[6..8].copy_from_slice(&10u16.to_le_bytes()); released[8..12].copy_from_slice(&32u32.to_le_bytes());
        released[16..24].copy_from_slice(&5u64.to_le_bytes()); released[24..28].copy_from_slice(&11i32.to_le_bytes());
        sender.write_all(&released).unwrap();
        assert!(matches!(receive(&receiver).unwrap(), Record::BufferReleased { request: 5, status: 11 }));
        released[28] = 1;
        sender.write_all(&released).unwrap();
        assert_eq!(receive(&receiver).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn result_and_revoke_have_exact_sizes_and_zero_denial() {
        let denied = response(3, None).unwrap();
        assert_eq!(denied.len(), 80);
        assert_eq!(u64_at(&denied, 16), 3);
        assert_eq!(u32_at(&denied, 24), 1);
        assert!(denied[32..].iter().all(|b| *b == 0));
        let grant = crate::gpu_grant::Grant { epoch: [1;16], token: [2;16], window: 7, process: 3, peer: (1000, 42, 123, 17), generation: 8 };
        let accepted = response(3, Some(grant)).unwrap();
        assert_eq!(accepted.len(), 80);
        assert_eq!(u32_at(&accepted, 24), 0);
        assert_eq!(u64_at(&accepted, 64), 7);
        assert_eq!(u64_at(&accepted, 72), 8);
        let revoke = revoke(grant).unwrap();
        assert_eq!(revoke.len(), 64);
        assert_eq!(u16_at(&revoke, 6), 3);
        assert_eq!(u64_at(&revoke, 48), 8);
        let (mut sender, receiver) = pair();
        let mut retired = revoke;
        retired[6..8].copy_from_slice(&7u16.to_le_bytes());
        sender.write_all(&retired).unwrap();
        match receive(&receiver).unwrap() {
            Record::SurfaceRetired { epoch, grant, generation } => {
                assert_eq!(epoch, [1; 16]); assert_eq!(grant, [2; 16]); assert_eq!(generation, 8);
            }
            _ => panic!("expected surface retirement"),
        }
        retired[6..8].copy_from_slice(&8u16.to_le_bytes());
        sender.write_all(&retired).unwrap();
        assert!(matches!(receive(&receiver).unwrap(), Record::RevokeRequest { generation: 8, .. }));
    }
}
