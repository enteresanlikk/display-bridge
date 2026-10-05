//! Heartbeat policy — the pure timing rules ported from the Swift
//! `SessionCoordinator.startHeartbeat` loop.
//!
//! There are no timers or threads here: the driver owns the clock and calls these
//! predicates with an injected monotonic `now_ns`. All times are **nanoseconds**,
//! matching the Swift `DispatchTime.uptimeNanoseconds` values.

/// How often to send a `Ping` while streaming: 3 seconds.
pub const PING_INTERVAL_NS: u64 = 3_000_000_000;

/// How long the peer may be silent before it is considered dead: 10 seconds.
pub const DEAD_TIMEOUT_NS: u64 = 10_000_000_000;

/// Whether it is time to send another ping, given when the last ping was sent
/// (`last_ping_ns`) and the current time (`now_ns`). True once at least
/// [`PING_INTERVAL_NS`] has elapsed.
pub fn should_ping(last_ping_ns: u64, now_ns: u64) -> bool {
    now_ns.saturating_sub(last_ping_ns) >= PING_INTERVAL_NS
}

/// Whether the peer should be considered dead, given when a packet was last received
/// (`last_received_ns`) and the current time (`now_ns`). True once silence exceeds
/// [`DEAD_TIMEOUT_NS`] (strictly greater, matching the Swift check).
pub fn is_dead(last_received_ns: u64, now_ns: u64) -> bool {
    now_ns.saturating_sub(last_received_ns) > DEAD_TIMEOUT_NS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn should_ping_only_after_the_interval() {
        // Before 3s: no ping.
        assert!(!should_ping(0, 0));
        assert!(!should_ping(0, PING_INTERVAL_NS - 1));
        // At and after 3s: ping.
        assert!(should_ping(0, PING_INTERVAL_NS));
        assert!(should_ping(0, PING_INTERVAL_NS + 1));
    }

    #[test]
    fn should_ping_is_relative_to_last_ping() {
        let last = 5 * PING_INTERVAL_NS;
        assert!(!should_ping(last, last + PING_INTERVAL_NS - 1));
        assert!(should_ping(last, last + PING_INTERVAL_NS));
    }

    #[test]
    fn is_dead_only_past_the_timeout() {
        // Exactly at the timeout is still alive (strictly greater).
        assert!(!is_dead(0, DEAD_TIMEOUT_NS));
        assert!(!is_dead(0, DEAD_TIMEOUT_NS - 1));
        // One nanosecond past → dead.
        assert!(is_dead(0, DEAD_TIMEOUT_NS + 1));
    }

    #[test]
    fn clock_going_backwards_is_not_dead() {
        // Defensive: a non-monotonic reading must not underflow into "dead".
        assert!(!is_dead(1_000, 500));
        assert!(!should_ping(1_000, 500));
    }
}
