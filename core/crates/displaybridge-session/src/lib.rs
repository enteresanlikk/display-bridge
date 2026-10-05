//! DisplayBridge session logic — the pure, shared core ported from the Swift
//! `SessionCoordinator`.
//!
//! Everything here is deterministic and I/O-free so it can be unit-tested and driven
//! from the FFI layer on any platform:
//!
//! * [`state`] — the [`SessionMachine`], an `event → commands` state machine that
//!   replicates the handshake / config-update / ping / heartbeat flow.
//! * [`pacing`] — the [`PipelineGate`] and [`PendingFrame`] frame-pacing primitives
//!   ("always send the newest frame, drop stale").
//! * [`metrics`] — [`PipelineMetrics`] with an injected clock and its [`Stats`] /
//!   [`ClientStats`] outputs.
//! * [`heartbeat`] — the pure ping-interval / dead-timeout policy.
//!
//! Wire framing and config types come from `displaybridge-protocol` and are re-used, never
//! redefined.

pub mod auth;
pub mod heartbeat;
pub mod metrics;
pub mod pacing;
pub mod state;

pub use auth::AuthThrottle;
pub use metrics::{ClientStats, PipelineMetrics, Stats};
pub use pacing::{PendingFrame, PipelineGate};
pub use state::{SessionCommand, SessionEvent, SessionMachine, SessionState};
