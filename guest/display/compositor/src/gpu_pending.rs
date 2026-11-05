//! GPU binds held for X11 windows that are not bindable yet. A toolkit binds its Vulkan
//! surface to a window as soon as it has made it, often before the window is mapped (a
//! menu made ahead of being shown, a top-level or a child made before its first show), or
//! before the compositor has taken in the map. Such a bind, by the process that made the
//! window, is held unanswered rather than refused, and answered once the window is a
//! bindable surface. It is refused when the window goes, the process ends, a newer bind of
//! the same window by the same process replaces it, or it has waited `HOLD`, which is
//! shorter than the broker's wait for the compositor's answer (docs/gpu-live.md). At most
//! `LIMIT` are held. A window whose bind waited out `HOLD` is not held again (its later
//! binds are refused at once, and granted as usual once it is bindable), so a window that
//! never maps costs its process one wait. Only standard-library types here, so the rules
//! are tested on any host.
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// The most binds held at once; the broker allows 64 outstanding binds in all.
pub const LIMIT: usize = 16;
/// How long a bind is held. The broker waits 5 s for the compositor's answer.
pub const HOLD: Duration = Duration::from_millis(4000);
/// How often held binds are looked at again while any are held.
pub const SWEEP: Duration = Duration::from_millis(100);
/// How many windows whose hold expired are remembered (oldest forgotten first).
pub const REMEMBERED: usize = 64;
// A held bind is answered, at the latest by the sweep after `HOLD`, before the broker gives
// up on it, and the held binds leave the broker room for others.
const _: () = assert!(HOLD.as_millis() + SWEEP.as_millis() < 5000 && LIMIT < 64);

/// Whether a bind of a window no bindable top-level holds yet is held: the X server records
/// the bound process `pid` as the client that made it (`maker`).
pub fn holdable(maker: Option<u32>, pid: u32) -> bool {
    maker == Some(pid)
}

/// One held bind: the X11 window it names, the bound process, and when it was first held.
#[derive(Debug)]
pub struct Held<T> {
    pub object: u32,
    pub pid: u32,
    pub since: Instant,
    pub bind: T,
}

impl<T> Held<T> {
    pub fn expired(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.since) >= HOLD
    }
}

#[derive(Debug)]
pub struct PendingBinds<T> {
    held: Vec<Held<T>>,
    /// (window, process) whose held bind waited out `HOLD`.
    expired: VecDeque<(u32, u32)>,
}

impl<T> Default for PendingBinds<T> {
    fn default() -> Self { Self { held: Vec::new(), expired: VecDeque::new() } }
}

impl<T> PendingBinds<T> {
    pub fn is_empty(&self) -> bool { self.held.is_empty() }

    #[cfg(test)]
    pub fn len(&self) -> usize { self.held.len() }

    /// Holds a bind; when `LIMIT` are held it is returned, to be refused at once.
    pub fn hold(&mut self, held: Held<T>) -> Result<(), T> {
        if self.held.len() >= LIMIT { return Err(held.bind); }
        self.held.push(held);
        Ok(())
    }

    /// Removes and returns every held bind, oldest first, to be looked at again; those still
    /// waiting are held again with `hold`, keeping their `since`.
    pub fn take_all(&mut self) -> Vec<Held<T>> {
        std::mem::take(&mut self.held)
    }

    /// Removes and returns the binds held for X11 window `object`: all of them when the
    /// window was destroyed, or those of process `pid` when it binds the window again.
    pub fn take_window(&mut self, object: u32, pid: Option<u32>) -> Vec<T> {
        let (taken, kept) = std::mem::take(&mut self.held).into_iter()
            .partition(|h| h.object == object && pid.is_none_or(|pid| h.pid == pid));
        self.held = kept;
        taken.into_iter().map(|h: Held<T>| h.bind).collect()
    }

    /// Forgets every held bind without answering it: its broker is gone.
    pub fn clear(&mut self) { self.held.clear(); }

    /// A held bind of `object` by `pid` waited out `HOLD`: that window is not held again.
    pub fn remember_expired(&mut self, object: u32, pid: u32) {
        if self.expired.contains(&(object, pid)) { return; }
        if self.expired.len() >= REMEMBERED { self.expired.pop_front(); }
        self.expired.push_back((object, pid));
    }

    /// Whether `pid`'s bind of `object` waited out `HOLD` before.
    pub fn expired_before(&self, object: u32, pid: u32) -> bool { self.expired.contains(&(object, pid)) }

    /// The X11 window `object` was destroyed (its id may be made again).
    pub fn forget_window(&mut self, object: u32) { self.expired.retain(|&(o, _)| o != object); }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(object: u32, pid: u32, since: Instant, bind: u64) -> Held<u64> {
        Held { object, pid, since, bind }
    }

    #[test]
    fn only_a_window_the_bound_process_made_is_held() {
        assert!(holdable(Some(42), 42));
        assert!(!holdable(Some(43), 42), "another process made it");
        assert!(!holdable(None, 42), "the X server does not know who made it");
    }

    #[test]
    fn a_window_whose_hold_expired_is_not_held_again_until_it_goes() {
        let mut pending = PendingBinds::<u64>::default();
        assert!(!pending.expired_before(0x400003, 42));
        pending.remember_expired(0x400003, 42);
        pending.remember_expired(0x400003, 42);
        assert!(pending.expired_before(0x400003, 42));
        assert!(!pending.expired_before(0x400003, 43), "another process's bind of it is its own");
        pending.forget_window(0x400003);
        assert!(!pending.expired_before(0x400003, 42), "a destroyed window's id may be made again");
        // Bounded: the oldest is forgotten first.
        for i in 0..=REMEMBERED as u32 { pending.remember_expired(0x500000 + i, 42); }
        assert!(!pending.expired_before(0x500000, 42));
        assert!(pending.expired_before(0x500000 + REMEMBERED as u32, 42));
    }

    #[test]
    fn a_newer_bind_of_the_same_window_by_the_same_process_takes_the_held_one() {
        let now = Instant::now();
        let mut pending = PendingBinds::default();
        pending.hold(held(0x400003, 42, now, 1)).unwrap();
        // Another process's bind of that window, or the process's bind of another, is its own.
        pending.hold(held(0x400003, 43, now, 2)).unwrap();
        pending.hold(held(0x400005, 42, now, 3)).unwrap();
        assert_eq!(pending.take_window(0x400003, Some(42)), vec![1]);
        assert_eq!(pending.take_window(0x400003, Some(42)), Vec::<u64>::new());
        pending.hold(held(0x400003, 42, now, 4)).unwrap();
        let binds: Vec<u64> = pending.take_all().into_iter().map(|h| h.bind).collect();
        assert_eq!(binds, vec![2, 3, 4]);
        assert!(pending.is_empty());
    }

    #[test]
    fn at_most_limit_binds_are_held() {
        let now = Instant::now();
        let mut pending = PendingBinds::default();
        for i in 0..LIMIT as u32 {
            pending.hold(held(0x400000 + i, 42, now, u64::from(i))).unwrap();
        }
        assert_eq!(pending.hold(held(0x500000, 42, now, 99)).unwrap_err(), 99);
        assert_eq!(pending.len(), LIMIT);
        // Taking one makes room again.
        assert_eq!(pending.take_window(0x400000, Some(42)), vec![0]);
        pending.hold(held(0x500000, 42, now, 99)).unwrap();
    }

    #[test]
    fn a_destroyed_window_takes_its_held_binds_with_it() {
        let now = Instant::now();
        let mut pending = PendingBinds::default();
        pending.hold(held(0x400003, 42, now, 1)).unwrap();
        pending.hold(held(0x400003, 43, now, 2)).unwrap();
        pending.hold(held(0x400005, 42, now, 3)).unwrap();
        assert_eq!(pending.take_window(0x400003, None), vec![1, 2]);
        assert_eq!(pending.take_window(0x400003, None), Vec::<u64>::new());
        assert_eq!(pending.len(), 1);
    }

    #[test]
    fn a_bind_held_again_keeps_when_it_was_first_held() {
        let start = Instant::now();
        let mut pending = PendingBinds::default();
        pending.hold(held(0x400003, 42, start, 1)).unwrap();
        for h in pending.take_all() {
            assert!(!h.expired(start + HOLD - Duration::from_millis(1)));
            assert!(h.expired(start + HOLD));
            pending.hold(h).unwrap();
        }
        assert_eq!(pending.take_all()[0].since, start);
    }

    #[test]
    fn clearing_forgets_every_held_bind() {
        let now = Instant::now();
        let mut pending = PendingBinds::default();
        pending.hold(held(0x400003, 42, now, 1)).unwrap();
        pending.clear();
        assert!(pending.is_empty());
    }
}
