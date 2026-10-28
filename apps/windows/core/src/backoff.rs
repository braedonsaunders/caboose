//! How long caboose-service waits before starting the keepalive again.

use std::time::Duration;

/// A keepalive that ran at least this long was healthy; its exit starts the count again.
pub const HEALTHY_RUN: Duration = Duration::from_secs(120);
pub const MAX_DELAY: Duration = Duration::from_secs(60);

/// Consecutive quick failures after a keepalive that ran for `ran_for`.
pub fn failures_after(previous: u32, ran_for: Duration) -> u32 {
    if ran_for >= HEALTHY_RUN {
        1
    } else {
        previous.saturating_add(1)
    }
}

/// The wait before the next start: 1 s after one failure, doubling, at most a minute.
pub fn delay(failures: u32) -> Duration {
    match failures {
        0 => Duration::ZERO,
        n => Duration::from_secs(1u64 << (n - 1).min(6)).min(MAX_DELAY),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_up_to_a_minute() {
        let delays: Vec<u64> = (0..9).map(|n| delay(n).as_secs()).collect();
        assert_eq!(delays, vec![0, 1, 2, 4, 8, 16, 32, 60, 60]);
        assert_eq!(delay(u32::MAX), MAX_DELAY);
    }

    #[test]
    fn a_long_run_resets_the_count() {
        assert_eq!(failures_after(6, Duration::from_secs(5)), 7);
        assert_eq!(failures_after(6, Duration::from_secs(600)), 1);
        assert_eq!(failures_after(u32::MAX, Duration::ZERO), u32::MAX);
    }
}
