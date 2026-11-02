//! When each window committed, when the compositor presented its pictures, and when input
//! arrived, in CLOCK_MONOTONIC microseconds: the seat's timeline for frame lab
//! (guest/framelab), read through the control socket's `frames` request. Each ring keeps
//! the newest [`RING`] entries, so a reader polling every few seconds misses nothing at
//! display rate.

use std::collections::VecDeque;

pub const RING: usize = 1024;

#[derive(Debug)]
pub struct Ring<T> {
    items: VecDeque<T>,
}

impl<T> Default for Ring<T> {
    fn default() -> Self {
        Self { items: VecDeque::new() }
    }
}

impl<T: Copy> Ring<T> {
    pub fn push(&mut self, item: T) {
        if self.items.len() == RING {
            self.items.pop_front();
        }
        self.items.push_back(item);
    }

    /// The entries whose time (`at`) is after `since`, oldest first.
    pub fn after(&self, since: u64, at: impl Fn(&T) -> u64) -> Vec<T> {
        let first = self.items.partition_point(|item| at(item) <= since);
        self.items.range(first..).copied().collect()
    }
}

/// A picture the compositor rendered and asked the broker to show: when, the commit time
/// of the newest content it holds, and the bytes its texture uploads copied.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Present {
    pub at_us: u64,
    pub commit_us: u64,
    pub bytes: u64,
}

#[derive(Default, Debug)]
pub struct WindowTrace {
    pub commits: Ring<u64>,
    pub presents: Ring<Present>,
}

/// Input from the client, by kind. `id` correlates it with its [`Latency`]
/// entry (0 = the latency trace had stopped, so this event was not traced).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Input {
    pub at_us: u64,
    pub kind: &'static str,
    pub id: u64,
}

/// One input's journey, timing only: when the phone's event arrived, when it
/// had been delivered to the client, when the client next committed, and when
/// that commit's picture was presented. Never a key code or button. A stage
/// that never happened stays 0.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Latency {
    pub id: u64,
    pub window: u64,
    pub at_us: u64,
    pub delivered_us: u64,
    pub commit_us: u64,
    pub present_us: u64,
}

/// The per-input latency trace. Bounded like LordOS's keylag: at most
/// [`MAX_PENDING`] inputs wait for a stage, a stage not reached within
/// [`GIVE_UP_US`] completes the entry as it stands, and the trace stops
/// itself [`WINDOW_US`] after its first traced input (a later input, once
/// nothing is pending, starts a fresh window).
#[derive(Debug, Default)]
pub struct LatencyTrace {
    pending: Vec<Latency>,
    done: Ring<Latency>,
    started_us: u64,
    started: bool,
    stopped: bool,
}

pub const MAX_PENDING: usize = 32;
pub const GIVE_UP_US: u64 = 2_000_000;
pub const WINDOW_US: u64 = 120_000_000;
pub const MAX_DONE: usize = 256;

impl LatencyTrace {
    /// Starts tracing input `id` for `window`; false when the trace has
    /// stopped (the caller then records the event untraced, with id 0).
    pub fn begin(&mut self, id: u64, window: u64, at_us: u64) -> bool {
        if self.stopped {
            if self.pending.is_empty() && at_us.saturating_sub(self.started_us) > WINDOW_US {
                self.stopped = false;
                self.started = false;
            } else {
                return false;
            }
        }
        self.expire(at_us);
        if self.stopped {
            return false;
        }
        if !self.started {
            self.started = true;
            self.started_us = at_us;
        }
        if self.pending.len() == MAX_PENDING {
            let old = self.pending.remove(0);
            self.push_done(old);
        }
        self.pending.push(Latency { id, window, at_us, ..Default::default() });
        true
    }

    /// The event has been handed to the client (queued on its socket).
    pub fn delivered(&mut self, id: u64, at_us: u64) {
        if let Some(e) = self.pending.iter_mut().find(|e| e.id == id && e.delivered_us == 0) {
            e.delivered_us = at_us;
        }
    }

    /// `window` committed: its oldest delivered, uncommitted input reacted.
    pub fn commit(&mut self, window: u64, at_us: u64) {
        if let Some(e) = self.pending.iter_mut().find(|e| e.window == window && e.delivered_us != 0 && e.commit_us == 0) {
            e.commit_us = at_us;
        }
        self.expire(at_us);
    }

    /// A picture holding commit `commit_us` of `window` was presented.
    pub fn present(&mut self, window: u64, commit_us: u64, at_us: u64) {
        let Some(pos) = self
            .pending
            .iter()
            .position(|e| e.window == window && e.commit_us != 0 && e.commit_us <= commit_us)
        else {
            return;
        };
        let mut e = self.pending.remove(pos);
        e.present_us = at_us;
        self.push_done(e);
        self.expire(at_us);
    }

    /// Completed entries after `since` (by input time), oldest first.
    pub fn after(&self, since: u64) -> Vec<Latency> {
        self.done.after(since, |e| e.at_us)
    }

    fn push_done(&mut self, e: Latency) {
        if self.done.items.len() == MAX_DONE {
            self.done.items.pop_front();
        }
        self.done.items.push_back(e);
    }

    fn expire(&mut self, now_us: u64) {
        while self.pending.first().is_some_and(|e| now_us.saturating_sub(e.at_us) > GIVE_UP_US) {
            let old = self.pending.remove(0);
            self.push_done(old);
        }
        if self.started && now_us.saturating_sub(self.started_us) > WINDOW_US {
            self.stopped = true;
            for e in std::mem::take(&mut self.pending) {
                self.push_done(e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ring_keeps_the_newest_entries_and_reads_after_a_time() {
        let mut ring = Ring::default();
        for t in 0..(RING as u64 + 10) {
            ring.push(t);
        }
        assert_eq!(ring.after(0, |t| *t).first(), Some(&10));
        assert_eq!(ring.after(RING as u64 + 7, |t| *t), vec![RING as u64 + 8, RING as u64 + 9]);
        assert!(ring.after(u64::MAX, |t| *t).is_empty());
    }

    #[test]
    fn latency_correlates_one_input_through_commit_to_present() {
        let mut t = LatencyTrace::default();
        assert!(t.begin(7, 3, 1_000));
        t.delivered(7, 1_100);
        t.commit(3, 1_500);
        assert!(t.after(0).is_empty(), "not done until presented");
        t.present(3, 1_500, 2_000);
        assert_eq!(
            t.after(0),
            vec![Latency { id: 7, window: 3, at_us: 1_000, delivered_us: 1_100, commit_us: 1_500, present_us: 2_000 }]
        );
    }

    #[test]
    fn latency_gives_up_and_stops_itself_without_recording_what_the_input_was() {
        let mut t = LatencyTrace::default();
        assert!(t.begin(1, 3, 1_000));
        // No delivery, no commit: after the give-up the entry completes as-is.
        assert!(t.begin(2, 3, 1_000 + GIVE_UP_US + 1));
        assert_eq!(t.after(0).len(), 1);
        assert_eq!(t.after(0)[0].commit_us, 0);
        // Past the window the trace stops; a much later input starts fresh.
        assert!(!t.begin(3, 3, 1_000 + WINDOW_US + GIVE_UP_US + 2));
        assert!(t.begin(4, 3, 1_000 + WINDOW_US + GIVE_UP_US + 3 + WINDOW_US));
    }
}
