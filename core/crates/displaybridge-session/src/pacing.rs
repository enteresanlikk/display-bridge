//! Frame-pacing primitives — a port of the Swift `PipelineGate` and `PendingFrame`.
//!
//! Together they implement the pipeline's "always send the newest frame, drop stale
//! frames, encode ahead" policy without ever queuing:
//! * [`PipelineGate`] keeps at most one frame in-flight on the transport.
//! * [`PendingFrame`] is a single-slot, latest-wins holder for the encoded frame that
//!   is ready to send.
//!
//! Only the primitives are ported here; the actual self-driving send loop lives in the
//! native driver. Both types are `Sync` (they use `std::sync::Mutex`) so the FFI layer
//! can share them across the capture, encode, and send threads (typically via `Arc`).

use std::sync::Mutex;

/// Gate that ensures at most one frame is in the send pipeline at a time.
///
/// The encoder/sender calls [`try_enter`](PipelineGate::try_enter) before handing a
/// frame to the transport: `true` means it acquired the gate and must eventually call
/// [`leave`](PipelineGate::leave); `false` means the pipeline is busy and the caller
/// must **drop** this frame (never queue it). Total and dropped counts are tracked for
/// metrics.
#[derive(Debug, Default)]
pub struct PipelineGate {
    inner: Mutex<GateInner>,
}

#[derive(Debug, Default)]
struct GateInner {
    busy: bool,
    total_frames: u64,
    dropped_frames: u64,
}

impl PipelineGate {
    /// Creates an idle gate.
    pub fn new() -> Self {
        Self::default()
    }

    /// Tries to enter the gate. Returns `true` if acquired (the pipeline was idle);
    /// returns `false` if a frame is already in flight, in which case the caller must
    /// drop the frame. Every call increments the total count; a rejected call also
    /// increments the dropped count.
    pub fn try_enter(&self) -> bool {
        let mut g = self.inner.lock().unwrap();
        g.total_frames += 1;
        if g.busy {
            g.dropped_frames += 1;
            return false;
        }
        g.busy = true;
        true
    }

    /// Releases the gate — called when the in-flight send completes.
    pub fn leave(&self) {
        let mut g = self.inner.lock().unwrap();
        g.busy = false;
    }

    /// Whether a frame is currently in flight.
    pub fn is_busy(&self) -> bool {
        self.inner.lock().unwrap().busy
    }

    /// Returns `(total_frames, dropped_frames)` seen so far.
    pub fn stats(&self) -> (u64, u64) {
        let g = self.inner.lock().unwrap();
        (g.total_frames, g.dropped_frames)
    }
}

/// Single-slot holder for the latest encoded frame ready to send.
///
/// The encoder writes the newest frame with [`set`](PendingFrame::set) (overwriting any
/// stale frame); the sender consumes it with [`take`](PendingFrame::take). This is the
/// "latest wins" buffer that guarantees the transport always sends the freshest frame.
#[derive(Debug, Default)]
pub struct PendingFrame {
    inner: Mutex<Option<Slot>>,
}

#[derive(Debug, Clone)]
struct Slot {
    packet: Vec<u8>,
    capture_time_ns: u64,
}

impl PendingFrame {
    /// Creates an empty holder.
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores a new pending frame, overwriting any previous (unsent) one.
    pub fn set(&self, packet: Vec<u8>, capture_time_ns: u64) {
        let mut slot = self.inner.lock().unwrap();
        *slot = Some(Slot {
            packet,
            capture_time_ns,
        });
    }

    /// Takes the pending frame, clearing the slot. Returns `None` if nothing is pending.
    pub fn take(&self) -> Option<(Vec<u8>, u64)> {
        let mut slot = self.inner.lock().unwrap();
        slot.take().map(|s| (s.packet, s.capture_time_ns))
    }

    /// Whether a frame is pending, without consuming it.
    pub fn has_pending(&self) -> bool {
        self.inner.lock().unwrap().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_allows_one_and_drops_while_busy() {
        let gate = PipelineGate::new();

        // First frame acquires the gate.
        assert!(gate.try_enter());
        assert!(gate.is_busy());

        // While busy, further frames are dropped.
        assert!(!gate.try_enter());
        assert!(!gate.try_enter());

        // 3 total, 2 dropped.
        assert_eq!(gate.stats(), (3, 2));

        // After leaving, the next frame is accepted again.
        gate.leave();
        assert!(!gate.is_busy());
        assert!(gate.try_enter());
        assert_eq!(gate.stats(), (4, 2));
    }

    #[test]
    fn gate_stats_start_at_zero() {
        let gate = PipelineGate::new();
        assert_eq!(gate.stats(), (0, 0));
        assert!(!gate.is_busy());
    }

    #[test]
    fn pending_latest_wins() {
        let pending = PendingFrame::new();
        assert!(!pending.has_pending());
        assert!(pending.take().is_none());

        pending.set(vec![1, 1, 1], 100);
        pending.set(vec![2, 2, 2], 200); // overwrites the stale frame
        assert!(pending.has_pending());

        // Only the newest frame survives.
        assert_eq!(pending.take(), Some((vec![2, 2, 2], 200)));
        // Taking clears the slot.
        assert!(!pending.has_pending());
        assert!(pending.take().is_none());
    }

    #[test]
    fn pending_set_after_take_works() {
        let pending = PendingFrame::new();
        pending.set(vec![9], 1);
        assert_eq!(pending.take(), Some((vec![9], 1)));
        pending.set(vec![8], 2);
        assert_eq!(pending.take(), Some((vec![8], 2)));
    }

    #[test]
    fn primitives_are_shareable_across_threads() {
        use std::sync::Arc;
        use std::thread;

        let gate = Arc::new(PipelineGate::new());
        let pending = Arc::new(PendingFrame::new());

        let handles: Vec<_> = (0..8)
            .map(|i| {
                let gate = Arc::clone(&gate);
                let pending = Arc::clone(&pending);
                thread::spawn(move || {
                    if gate.try_enter() {
                        pending.set(vec![i as u8], i);
                        gate.leave();
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }

        // Every attempt is counted; total == 8, dropped <= 7.
        let (total, dropped) = gate.stats();
        assert_eq!(total, 8);
        assert!(dropped <= 7);
    }
}
