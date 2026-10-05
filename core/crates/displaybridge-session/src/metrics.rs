//! Pipeline metrics — a port of the Swift `PipelineMetrics`.
//!
//! Records per-frame capture/send events and computes FPS, drop rate, latency, and
//! throughput over the interval since the last snapshot. The clock is **injected**:
//! callers pass `now_ns` into [`PipelineMetrics::snapshot`] rather than the type reading
//! any wall clock, which keeps the math deterministic and unit-testable.
//!
//! The type is `Sync` (it uses a `std::sync::Mutex`) so the FFI layer can share it
//! across the capture and send threads.

use std::sync::Mutex;

/// A computed snapshot of pipeline performance over one interval.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stats {
    /// Frames captured per second over the interval.
    pub capture_fps: f64,
    /// Frames sent per second over the interval.
    pub sent_fps: f64,
    /// Percentage of captured frames that were dropped (not sent) over the interval.
    pub dropped_percent: f64,
    /// Average send latency in milliseconds over the interval.
    pub avg_latency_ms: f64,
    /// Peak send latency in milliseconds over the interval.
    pub max_latency_ms: f64,
    /// The length of the interval in seconds.
    pub interval_sec: f64,
    /// Transport throughput in megabits per second over the interval.
    pub throughput_mbps: f64,
    /// Average sent frame size in kilobytes over the interval.
    pub avg_frame_size_kb: f64,
}

impl Stats {
    /// The zero snapshot, returned when an interval has no elapsed time.
    pub const ZERO: Stats = Stats {
        capture_fps: 0.0,
        sent_fps: 0.0,
        dropped_percent: 0.0,
        avg_latency_ms: 0.0,
        max_latency_ms: 0.0,
        interval_sec: 0.0,
        throughput_mbps: 0.0,
        avg_frame_size_kb: 0.0,
    };

    /// Projects to the lightweight [`ClientStats`] surfaced to the UI / peer.
    pub fn client_stats(&self) -> ClientStats {
        ClientStats {
            capture_fps: self.capture_fps,
            sent_fps: self.sent_fps,
            dropped_percent: self.dropped_percent,
            avg_latency_ms: self.avg_latency_ms,
            max_latency_ms: self.max_latency_ms,
        }
    }
}

/// A trimmed-down stats view for the UI / status reporting, matching the Swift
/// `ClientStats`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClientStats {
    /// Frames captured per second.
    pub capture_fps: f64,
    /// Frames sent per second.
    pub sent_fps: f64,
    /// Percentage of captured frames dropped.
    pub dropped_percent: f64,
    /// Average send latency in milliseconds.
    pub avg_latency_ms: f64,
    /// Peak send latency in milliseconds.
    pub max_latency_ms: f64,
}

/// Records frame timings and computes periodic [`Stats`].
#[derive(Debug)]
pub struct PipelineMetrics {
    inner: Mutex<MetricsInner>,
}

#[derive(Debug)]
struct MetricsInner {
    // Cumulative counters.
    capture_count: u64,
    sent_count: u64,
    total_latency_us: u64,
    max_latency_us: u64,
    total_sent_bytes: u64,

    // Values captured at the previous snapshot, used to compute per-interval deltas.
    last_snapshot_ns: u64,
    last_capture_count: u64,
    last_sent_count: u64,
    last_total_latency_us: u64,
    last_total_sent_bytes: u64,
}

impl PipelineMetrics {
    /// Creates a metrics collector. `start_ns` is the monotonic time the first interval
    /// begins at (the reference for the first [`snapshot`](PipelineMetrics::snapshot)).
    pub fn new(start_ns: u64) -> Self {
        Self {
            inner: Mutex::new(MetricsInner {
                capture_count: 0,
                sent_count: 0,
                total_latency_us: 0,
                max_latency_us: 0,
                total_sent_bytes: 0,
                last_snapshot_ns: start_ns,
                last_capture_count: 0,
                last_sent_count: 0,
                last_total_latency_us: 0,
                last_total_sent_bytes: 0,
            }),
        }
    }

    /// Records that a frame was captured.
    pub fn record_capture(&self) {
        let mut m = self.inner.lock().unwrap();
        m.capture_count += 1;
    }

    /// Records that a frame was sent, with its end-to-end `latency_us` (microseconds)
    /// and encoded `bytes`.
    pub fn record_sent(&self, latency_us: u64, bytes: u64) {
        let mut m = self.inner.lock().unwrap();
        m.sent_count += 1;
        m.total_latency_us += latency_us;
        m.total_sent_bytes += bytes;
        if latency_us > m.max_latency_us {
            m.max_latency_us = latency_us;
        }
    }

    /// Computes [`Stats`] over the interval since the last snapshot, then resets the
    /// interval baseline (and the peak-latency tracker) to `now_ns`. Returns
    /// [`Stats::ZERO`] when no time has elapsed.
    pub fn snapshot(&self, now_ns: u64) -> Stats {
        let mut m = self.inner.lock().unwrap();

        let delta_ns = now_ns.saturating_sub(m.last_snapshot_ns);
        let delta_capture = m.capture_count - m.last_capture_count;
        let delta_sent = m.sent_count - m.last_sent_count;
        let delta_latency = m.total_latency_us - m.last_total_latency_us;
        let max_lat = m.max_latency_us;
        let delta_bytes = m.total_sent_bytes - m.last_total_sent_bytes;

        // Advance the baseline (matches Swift: done before the interval check) and reset
        // the peak so max latency is per-interval.
        m.last_snapshot_ns = now_ns;
        m.last_capture_count = m.capture_count;
        m.last_sent_count = m.sent_count;
        m.last_total_latency_us = m.total_latency_us;
        m.last_total_sent_bytes = m.total_sent_bytes;
        m.max_latency_us = 0;
        drop(m);

        let interval_sec = delta_ns as f64 / 1_000_000_000.0;
        if interval_sec <= 0.0 {
            return Stats::ZERO;
        }

        let capture_fps = delta_capture as f64 / interval_sec;
        let sent_fps = delta_sent as f64 / interval_sec;
        let dropped_percent = if delta_capture > delta_sent {
            (delta_capture - delta_sent) as f64 / delta_capture as f64 * 100.0
        } else {
            0.0
        };
        let avg_latency_ms = if delta_sent > 0 {
            delta_latency as f64 / delta_sent as f64 / 1000.0
        } else {
            0.0
        };
        let max_latency_ms = max_lat as f64 / 1000.0;
        let throughput_mbps = delta_bytes as f64 * 8.0 / 1_000_000.0 / interval_sec;
        let avg_frame_size_kb = if delta_sent > 0 {
            delta_bytes as f64 / delta_sent as f64 / 1024.0
        } else {
            0.0
        };

        Stats {
            capture_fps,
            sent_fps,
            dropped_percent,
            avg_latency_ms,
            max_latency_ms,
            interval_sec,
            throughput_mbps,
            avg_frame_size_kb,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NS_PER_SEC: u64 = 1_000_000_000;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-6, "expected {b}, got {a}");
    }

    #[test]
    fn math_over_a_one_second_interval() {
        let m = PipelineMetrics::new(0);

        // 10 captured, 8 sent. Each sent frame: 5000us latency, 10240 bytes.
        for _ in 0..10 {
            m.record_capture();
        }
        for _ in 0..8 {
            m.record_sent(5_000, 10_240);
        }

        let s = m.snapshot(NS_PER_SEC); // 1s interval
        approx(s.interval_sec, 1.0);
        approx(s.capture_fps, 10.0);
        approx(s.sent_fps, 8.0);
        approx(s.dropped_percent, 20.0); // (10-8)/10*100
        approx(s.avg_latency_ms, 5.0); // 5000us
        approx(s.max_latency_ms, 5.0);
        // 8 * 10240 = 81920 bytes -> KB/frame = 10.
        approx(s.avg_frame_size_kb, 10.0);
        // 81920 bytes * 8 / 1e6 = 0.65536 Mbps.
        approx(s.throughput_mbps, 0.655_36);
    }

    #[test]
    fn snapshot_resets_the_interval() {
        let m = PipelineMetrics::new(0);
        for _ in 0..5 {
            m.record_capture();
            m.record_sent(2_000, 1_000);
        }
        let _ = m.snapshot(NS_PER_SEC);

        // Next interval: only new events count, and max latency starts fresh.
        m.record_capture();
        m.record_sent(9_000, 4_000);
        let s = m.snapshot(2 * NS_PER_SEC); // another 1s
        approx(s.capture_fps, 1.0);
        approx(s.sent_fps, 1.0);
        approx(s.avg_latency_ms, 9.0);
        approx(s.max_latency_ms, 9.0); // not 2.0 from the prior interval
        approx(s.dropped_percent, 0.0);
    }

    #[test]
    fn zero_interval_returns_zero_stats() {
        let m = PipelineMetrics::new(500);
        m.record_capture();
        m.record_sent(1_000, 1_000);
        // Same timestamp as start -> no elapsed time.
        assert_eq!(m.snapshot(500), Stats::ZERO);
    }

    #[test]
    fn no_sent_frames_avoids_divide_by_zero() {
        let m = PipelineMetrics::new(0);
        for _ in 0..3 {
            m.record_capture();
        }
        let s = m.snapshot(NS_PER_SEC);
        approx(s.capture_fps, 3.0);
        approx(s.sent_fps, 0.0);
        approx(s.dropped_percent, 100.0); // all captured, none sent
        approx(s.avg_latency_ms, 0.0);
        approx(s.avg_frame_size_kb, 0.0);
    }

    #[test]
    fn client_stats_projection() {
        let m = PipelineMetrics::new(0);
        m.record_capture();
        m.record_sent(3_000, 2_048);
        let s = m.snapshot(NS_PER_SEC);
        let c = s.client_stats();
        approx(c.capture_fps, s.capture_fps);
        approx(c.sent_fps, s.sent_fps);
        approx(c.dropped_percent, s.dropped_percent);
        approx(c.avg_latency_ms, s.avg_latency_ms);
        approx(c.max_latency_ms, s.max_latency_ms);
    }
}
