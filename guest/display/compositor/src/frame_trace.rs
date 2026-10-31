//! When each window committed, when its pictures went to the client, and when input
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

/// A picture sent to the client: when, the commit time of its content (its pts), and its
/// encoded bytes (frame, tiles and motion region together).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sent {
    pub at_us: u64,
    pub pts_us: u64,
    pub bytes: u64,
}

#[derive(Default, Debug)]
pub struct WindowTrace {
    pub commits: Ring<u64>,
    pub sent: Ring<Sent>,
}

/// Input from the client, by kind.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Input {
    pub at_us: u64,
    pub kind: &'static str,
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
}
