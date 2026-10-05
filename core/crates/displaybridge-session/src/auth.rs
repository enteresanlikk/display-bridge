//! Pairing-code authentication policy for a source accepting network sinks.
//!
//! The code only proves "this sink was told the code shown on the source". It is sent
//! in the clear, so it does not protect against someone who can already read the
//! traffic; it stops any other device on the network from connecting and driving the
//! pointer.
// ponytail: cleartext pairing code + unencrypted stream. Upgrade path is a PAKE
// (or TLS with a pinned key) once the Android sink runs on this core.

use std::collections::VecDeque;

/// Wrong codes tolerated inside one [`LOCKOUT_NS`] window before new handshakes are
/// refused. Caps guessing a 6-digit code at 5 tries a minute (~70 days on average).
pub const MAX_FAILURES: usize = 5;

/// The sliding window over which failures are counted: 60 seconds.
pub const LOCKOUT_NS: u64 = 60_000_000_000;

/// Compares two codes without stopping at the first differing byte.
pub fn codes_match(expected: &str, got: &str) -> bool {
    let (a, b) = (expected.as_bytes(), got.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Counts recent failed pairing attempts. Shared by every session of a source,
/// because a guesser opens a fresh connection per try.
#[derive(Debug, Default)]
pub struct AuthThrottle {
    failures: VecDeque<u64>,
}

impl AuthThrottle {
    /// Whether handshakes are currently refused outright.
    pub fn is_locked(&mut self, now_ns: u64) -> bool {
        while self
            .failures
            .front()
            .is_some_and(|&t| now_ns.saturating_sub(t) >= LOCKOUT_NS)
        {
            self.failures.pop_front();
        }
        self.failures.len() >= MAX_FAILURES
    }

    pub fn record_failure(&mut self, now_ns: u64) {
        self.failures.push_back(now_ns);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_match_is_exact() {
        assert!(codes_match("123456", "123456"));
        assert!(!codes_match("123456", "123457"));
        assert!(!codes_match("123456", "12345"));
        assert!(!codes_match("123456", ""));
    }

    #[test]
    fn locks_after_max_failures_and_recovers_after_the_window() {
        let mut t = AuthThrottle::default();
        for i in 0..MAX_FAILURES as u64 {
            assert!(!t.is_locked(i));
            t.record_failure(i);
        }
        assert!(t.is_locked(MAX_FAILURES as u64));
        // Still locked just before the oldest failure ages out...
        assert!(t.is_locked(LOCKOUT_NS - 1));
        // ...and open again once it has.
        assert!(!t.is_locked(LOCKOUT_NS));
    }
}
