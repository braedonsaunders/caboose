//! Live GPU surface grants. All window candidates must come from the compositor's
//! native Wayland peer lookup; app-supplied window IDs are never authority.
use std::collections::HashMap;
use std::io::{self, Read};

fn random_nonzero() -> io::Result<[u8; 16]> {
    let mut file = std::fs::File::open("/dev/urandom")?;
    for _ in 0..4 {
        let mut value = [0u8; 16];
        file.read_exact(&mut value)?;
        if value.iter().any(|byte| *byte != 0) { return Ok(value); }
    }
    Err(io::Error::other("GPU entropy returned zero repeatedly"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grant {
    pub epoch: [u8; 16],
    pub token: [u8; 16],
    pub window: u64,
    pub process: u64,
    pub peer: (u32, u32, u64, u32),
    pub generation: u64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase { Idle, Ready, Lost }

pub struct Grants {
    epoch: [u8; 16],
    phase: Phase,
    executor: [u8; 16],
    executor_generation: u64,
    next_surface_generation: u64,
    retirement_received: bool,
    windows: HashMap<u64, (Grant, bool)>, // bool = revoke queued but not committed
}

impl Grants {
    pub fn new() -> io::Result<Self> {
        Ok(Self { epoch: random_nonzero()?, phase: Phase::Idle, executor: [0; 16],
            executor_generation: 0, next_surface_generation: 0, retirement_received: false, windows: HashMap::new() })
    }

    pub fn epoch_if_ready(&self) -> Option<[u8; 16]> {
        (self.phase == Phase::Ready).then_some(self.epoch)
    }

    pub fn ready(&mut self, executor: [u8; 16], generation: u64) -> io::Result<()> {
        if self.phase != Phase::Idle || !executor.iter().any(|b| *b != 0) || generation <= self.executor_generation {
            return Err(io::Error::other("invalid executor ready"));
        }
        self.executor = executor;
        self.executor_generation = generation;
        self.phase = Phase::Ready;
        self.retirement_received = false;
        Ok(())
    }

    pub fn lost(&mut self, executor: [u8; 16], generation: u64) -> io::Result<Vec<Grant>> {
        if self.phase != Phase::Ready || executor != self.executor || generation != self.executor_generation {
            return Err(io::Error::other("invalid executor lost"));
        }
        self.phase = Phase::Lost;
        let mut grants = Vec::with_capacity(self.windows.len());
        for (grant, pending) in self.windows.values_mut() {
            *pending = true;
            grants.push(*grant);
        }
        Ok(grants)
    }

    /// Called only after the corresponding REVOKE_GRANT record has been sent.
    pub fn revoke_sent(&mut self, grant: Grant) -> io::Result<()> {
        match self.windows.get(&grant.window) {
            Some((current, true)) if *current == grant => {
                self.windows.remove(&grant.window);
                self.finish_retirement()
            }
            _ => Err(io::Error::other("stale grant revoke")),
        }
    }

    pub fn retired(&mut self, executor: [u8; 16], generation: u64) -> io::Result<()> {
        if self.phase != Phase::Lost || executor != self.executor || generation != self.executor_generation || self.retirement_received {
            return Err(io::Error::other("invalid executor retirement"));
        }
        self.retirement_received = true;
        self.finish_retirement()
    }

    fn finish_retirement(&mut self) -> io::Result<()> {
        if self.phase != Phase::Lost || !self.retirement_received || !self.windows.is_empty() { return Ok(()); }
        let next = random_nonzero()?;
        if next == self.epoch { return Err(io::Error::other("GPU epoch repeated")); }
        self.epoch = next;
        self.phase = Phase::Idle;
        self.executor = [0; 16];
        self.retirement_received = false;
        Ok(())
    }

    /// IPC failure cannot prove native retirement, so remain latched unavailable.
    pub fn fail(&mut self) {
        if self.phase == Phase::Ready { self.phase = Phase::Lost; }
        for (_, pending) in self.windows.values_mut() { *pending = true; }
    }

    /// `matches` must be the complete compositor-derived set after pidfd and
    /// wl_surface object-ID validation. An ambiguous set never yields a grant.
    pub fn bind(&mut self, process: u64, peer: (u32, u32, u64, u32), matches: &[u64]) -> io::Result<Grant> {
        if self.phase != Phase::Ready || process == 0 || matches.len() != 1 || matches[0] == 0 || self.windows.contains_key(&matches[0]) || self.windows.values().any(|(grant, _)| grant.peer == peer) {
            return Err(io::Error::other("surface unavailable or ambiguous"));
        }
        self.next_surface_generation = self.next_surface_generation.checked_add(1)
            .ok_or_else(|| io::Error::other("surface generation exhausted"))?;
        let token = random_nonzero()?;
        if self.windows.values().any(|(grant, _)| grant.token == token) {
            return Err(io::Error::other("GPU grant repeated"));
        }
        let grant = Grant { epoch: self.epoch, token, window: matches[0], process, peer, generation: self.next_surface_generation };
        self.windows.insert(grant.window, (grant, false));
        Ok(grant)
    }

    /// Mark a destroyed/unmapped surface as unavailable before sending revoke.
    pub fn begin_revoke(&mut self, window: u64) -> Option<Grant> {
        let (grant, pending) = self.windows.get_mut(&window)?;
        if *pending { return None; }
        *pending = true;
        Some(*grant)
    }
}

#[cfg(test)]
mod tests {
    use super::Grants;
    #[test]
    fn ambiguous_wayland_connections_cannot_receive_a_grant() {
        let mut grants = Grants::new().unwrap();
        grants.ready([1; 16], 1).unwrap();
        assert!(grants.bind(1, (1000, 42, 123, 17), &[7, 8]).is_err());
        assert!(grants.bind(1, (1000, 42, 123, 17), &[]).is_err());
        let grant = grants.bind(1, (1000, 42, 123, 17), &[7]).unwrap();
        assert!(grants.bind(1, (1000, 42, 123, 17), &[7]).is_err());
        assert_eq!(grants.begin_revoke(7), Some(grant));
        assert!(grants.bind(1, (1000, 42, 123, 17), &[7]).is_err());
        grants.revoke_sent(grant).unwrap();
        let next = grants.bind(1, (1000, 42, 123, 17), &[7]).unwrap();
        assert!(next.generation > grant.generation);
    }
    #[test]
    fn two_real_peer_connections_with_same_object_id_are_ambiguous() {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::net::UnixStream;
        let (one, _one_client) = UnixStream::pair().unwrap();
        let (two, _two_client) = UnixStream::pair().unwrap();
        let peer_one = crate::gpu_peer::GpuPeer::capture(&one).unwrap();
        let peer_two = crate::gpu_peer::GpuPeer::capture(&two).unwrap();
        // SAFETY: pidfd_open receives this live process's PID and zero flags.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, libc::getpid(), 0) as i32 };
        assert!(raw >= 0);
        // SAFETY: pidfd_open returned a new owned descriptor.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let peer = (peer_one.uid, peer_one.pid, peer_one.start_ticks, 17);
        let candidates: Vec<u64> = [(7, &peer_one, 17), (8, &peer_two, 17)].into_iter()
            .filter(|(_, client, object)| *object == peer.3 && client.matches_pidfd(peer.0, peer.1, peer.2, fd.as_raw_fd()))
            .map(|(window, _, _)| window).collect();
        assert_eq!(candidates, [7, 8]);
        let mut grants = Grants::new().unwrap();
        grants.ready([1; 16], 1).unwrap();
        assert!(grants.bind(1, peer, &candidates).is_err());
    }

    #[test]
    fn lost_epoch_cannot_rotate_without_retirement_and_revocation() {
        let mut grants = Grants::new().unwrap();
        assert!(grants.epoch_if_ready().is_none());
        grants.ready([1; 16], 1).unwrap();
        let old = grants.epoch_if_ready().unwrap();
        let grant = grants.bind(1, (1000, 42, 123, 17), &[7]).unwrap();
        assert_eq!(grants.lost([1; 16], 1).unwrap(), vec![grant]);
        assert!(grants.epoch_if_ready().is_none());
        grants.retired([1; 16], 1).unwrap();
        assert!(grants.epoch_if_ready().is_none());
        assert!(grants.ready([2; 16], 2).is_err());
        grants.revoke_sent(grant).unwrap();
        assert!(grants.ready([2; 16], 1).is_err());
        grants.ready([2; 16], 2).unwrap();
        assert_ne!(grants.epoch_if_ready(), Some(old));
    }
}
