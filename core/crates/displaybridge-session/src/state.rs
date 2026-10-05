//! Session state machine — a pure `event → commands` port of the Swift
//! `SessionCoordinator`.
//!
//! The machine holds no I/O, no clock, no threads. The driver (the native shell
//! or FFI layer) owns the transport, the pipeline, and the wall clock; it feeds
//! [`SessionEvent`]s in and applies the [`SessionCommand`]s that come back. Every
//! timestamp the machine needs is injected on the event, which keeps the whole
//! thing deterministic and unit-testable.
//!
//! ## Ported behaviour
//! * `HandshakeReq` → decode + validate config, ignore a duplicate handshake while
//!   already `Streaming`, otherwise reconfigure the pipeline, reply `HandshakeAck`
//!   echoing the config JSON, transition to `Streaming`, start capture, and arm the
//!   heartbeat.
//! * `ConfigUpdate` → stop capture, reconfigure, restart capture (no ack, stays
//!   `Streaming`). Ignored before the handshake.
//!
//! ## Pairing
//! With [`SessionMachine::require_pairing`] set, a `HandshakeReq` must carry the
//! matching `pairingCode`; otherwise the machine replies `Error` and closes. See
//! [`crate::auth`].
//! * `Ping` → reply `Pong` echoing the ping payload.
//! * `Disconnect` → tear the session down.
//! * `Tick` → heartbeat: emit a `Ping` every 3s and close the session once the peer
//!   has been silent past the 10s dead timeout (see [`crate::heartbeat`]).
//!
//! Outgoing packets carry a monotonically increasing sequence number, mirroring the
//! Swift `nextSequenceNumber` counter.

use std::sync::{Arc, Mutex};

use displaybridge_protocol::{DeviceConfig, PacketType};

use crate::auth::{self, AuthThrottle};
use crate::heartbeat;

/// The lifecycle states of a session, matching the Swift `SessionState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    /// No session yet.
    Idle,
    /// The transport is being established.
    Connecting,
    /// Connected; waiting for the peer's handshake.
    Negotiating,
    /// Handshake complete; frames are flowing.
    Streaming,
    /// The session has ended.
    Disconnected,
}

/// An event fed into the machine by the driver.
///
/// Timestamps are injected rather than read from a clock so the machine stays pure.
/// Two clocks are used, matching the Swift code:
/// * `now_micros` — wall-clock microseconds, written into outgoing packet headers.
/// * `now_ns` — monotonic nanoseconds, used for the heartbeat / dead-peer timers.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    /// The transport finished connecting (`Idle` → `Connecting` → `Negotiating`).
    Connected,
    /// A packet arrived from the peer.
    PacketReceived {
        /// The received packet's type.
        packet_type: PacketType,
        /// The received packet's payload bytes.
        payload: Vec<u8>,
        /// Wall-clock microseconds, used for any reply packet's timestamp.
        now_micros: u64,
        /// Monotonic nanoseconds, recorded as the last-received time for heartbeat.
        now_ns: u64,
    },
    /// A periodic tick from the driver's clock, used to drive the heartbeat.
    Tick {
        /// Wall-clock microseconds, used for a heartbeat ping's timestamp.
        now_micros: u64,
        /// Monotonic nanoseconds, compared against the last-received / last-ping times.
        now_ns: u64,
    },
}

/// A side effect the driver should perform. The machine never performs I/O itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionCommand {
    /// Update the observable session state to `state`.
    TransitionTo(SessionState),
    /// Frame and send a packet. The machine owns the sequence counter, so the driver
    /// can hand these fields straight to `PacketFramer::create_packet`.
    SendPacket {
        /// The packet type to send.
        packet_type: PacketType,
        /// The sequence number assigned by the machine.
        sequence_number: u64,
        /// The wall-clock timestamp (micros) for the header.
        timestamp_micros: u64,
        /// The packet payload.
        payload: Vec<u8>,
    },
    /// Recreate the capture/encode pipeline (virtual display + encoder + capturer) to
    /// match `config`. Corresponds to Swift `reconfigurePipeline`.
    ReconfigurePipeline(DeviceConfig),
    /// Start the capture/streaming pipeline for `config`.
    StartCapture(DeviceConfig),
    /// Stop the current capture.
    StopCapture,
    /// Tear the session down (stop capture, flush, notify + close transport).
    Close,
}

/// The session state machine.
///
/// Construct with [`SessionMachine::new`], feed [`SessionEvent`]s through
/// [`SessionMachine::on_event`], and apply the returned commands in order.
#[derive(Debug)]
pub struct SessionMachine {
    state: SessionState,
    config: Option<DeviceConfig>,
    sequence_number: u64,
    last_received_ns: u64,
    last_ping_ns: u64,
    /// The code a sink must present, plus the source-wide failed-attempt counter.
    pairing: Option<(String, Arc<Mutex<AuthThrottle>>)>,
}

impl Default for SessionMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionMachine {
    /// Creates a fresh machine in the [`SessionState::Idle`] state.
    pub fn new() -> Self {
        Self {
            state: SessionState::Idle,
            config: None,
            sequence_number: 0,
            last_received_ns: 0,
            last_ping_ns: 0,
            pairing: None,
        }
    }

    /// Makes this (source) machine refuse any handshake that does not carry `code`.
    /// `throttle` is shared across all of the source's sessions so guesses spread
    /// over many connections still hit one limit.
    pub fn require_pairing(&mut self, code: String, throttle: Arc<Mutex<AuthThrottle>>) {
        self.pairing = Some((code, throttle));
    }

    /// The current session state.
    pub fn state(&self) -> SessionState {
        self.state
    }

    /// The most recently negotiated config, if any.
    pub fn config(&self) -> Option<&DeviceConfig> {
        self.config.as_ref()
    }

    /// The last sequence number handed out (0 before any packet was sent).
    pub fn sequence_number(&self) -> u64 {
        self.sequence_number
    }

    /// Feeds one event into the machine and returns the commands the driver must apply,
    /// in order.
    pub fn on_event(&mut self, event: SessionEvent) -> Vec<SessionCommand> {
        match event {
            SessionEvent::Connected => self.on_connected(),
            SessionEvent::PacketReceived {
                packet_type,
                payload,
                now_micros,
                now_ns,
            } => {
                // Every received packet resets the dead-peer timer (Swift sets
                // `lastReceivedTime` at the top of `handleReceivedData`).
                self.last_received_ns = now_ns;
                self.on_packet(packet_type, &payload, now_micros, now_ns)
            }
            SessionEvent::Tick { now_micros, now_ns } => self.on_tick(now_micros, now_ns),
        }
    }

    /// Mirrors `startSession`: `Idle` → `Connecting` (begins connecting) →
    /// `Negotiating` (connected, waiting for the client handshake).
    fn on_connected(&mut self) -> Vec<SessionCommand> {
        if self.state != SessionState::Idle {
            return Vec::new();
        }
        self.state = SessionState::Negotiating;
        vec![
            SessionCommand::TransitionTo(SessionState::Connecting),
            SessionCommand::TransitionTo(SessionState::Negotiating),
        ]
    }

    fn on_packet(
        &mut self,
        packet_type: PacketType,
        payload: &[u8],
        now_micros: u64,
        now_ns: u64,
    ) -> Vec<SessionCommand> {
        match packet_type {
            PacketType::HandshakeReq => self.on_handshake(payload, now_micros, now_ns),
            PacketType::ConfigUpdate => self.on_config_update(payload),
            PacketType::Ping => {
                // Reply Pong, echoing the ping payload back verbatim.
                let seq = self.next_sequence_number();
                vec![SessionCommand::SendPacket {
                    packet_type: PacketType::Pong,
                    sequence_number: seq,
                    timestamp_micros: now_micros,
                    payload: payload.to_vec(),
                }]
            }
            PacketType::Disconnect => self.close(),
            // InputEvent, VideoFrame, HandshakeAck, Pong, Error: handled elsewhere or
            // ignored here (Swift logs an "unhandled packet type").
            _ => Vec::new(),
        }
    }

    fn on_handshake(
        &mut self,
        payload: &[u8],
        now_micros: u64,
        now_ns: u64,
    ) -> Vec<SessionCommand> {
        let mut config = match parse_config(payload) {
            Some(c) => c,
            None => {
                log::warn!("handshake: could not decode DeviceConfig payload");
                return Vec::new();
            }
        };
        // Taken out here so the code is never stored or echoed in the ack.
        let presented = config.pairing_code.take();
        if config.validate().is_err() {
            log::warn!(
                "handshake: invalid config {}x{}@{}Hz",
                config.width,
                config.height,
                config.refresh_rate
            );
            return Vec::new();
        }

        // Ignore duplicate handshakes while already streaming — recreating the virtual
        // display mid-stream kills the pipeline.
        if self.state == SessionState::Streaming {
            return Vec::new();
        }

        if let Some((code, throttle)) = &self.pairing {
            let mut throttle = throttle.lock().unwrap();
            let reason = if throttle.is_locked(now_ns) {
                Some("Too many wrong pairing codes. Try again in a minute.")
            } else if !auth::codes_match(code, presented.as_deref().unwrap_or("")) {
                throttle.record_failure(now_ns);
                Some("Wrong or missing pairing code.")
            } else {
                None
            };
            drop(throttle);
            if let Some(reason) = reason {
                let seq = self.next_sequence_number();
                let mut cmds = vec![SessionCommand::SendPacket {
                    packet_type: PacketType::Error,
                    sequence_number: seq,
                    timestamp_micros: now_micros,
                    payload: reason.as_bytes().to_vec(),
                }];
                cmds.extend(self.close());
                return cmds;
            }
        }

        // Echo the resolved config back in the ack (Swift re-encodes `clientConfig`).
        let ack_payload = match config.to_json() {
            Ok(json) => json.into_bytes(),
            Err(_) => return Vec::new(),
        };

        let seq = self.next_sequence_number();
        self.config = Some(config.clone());
        self.state = SessionState::Streaming;

        // Arm the heartbeat: `last_received_ns` was set by the caller; seed the ping
        // timer so the first ping fires ~one interval later.
        self.last_ping_ns = now_ns;

        vec![
            SessionCommand::ReconfigurePipeline(config.clone()),
            SessionCommand::SendPacket {
                packet_type: PacketType::HandshakeAck,
                sequence_number: seq,
                timestamp_micros: now_micros,
                payload: ack_payload,
            },
            SessionCommand::TransitionTo(SessionState::Streaming),
            SessionCommand::StartCapture(config),
        ]
    }

    fn on_config_update(&mut self, payload: &[u8]) -> Vec<SessionCommand> {
        // Only a peer that completed the handshake may reconfigure; otherwise this
        // would start capture for a sink that never paired.
        if self.state != SessionState::Streaming {
            return Vec::new();
        }
        let mut config = match parse_config(payload) {
            Some(c) => c,
            None => {
                log::warn!("config_update: could not decode DeviceConfig payload");
                return Vec::new();
            }
        };
        config.pairing_code = None;
        if config.validate().is_err() {
            log::warn!(
                "config_update: invalid config {}x{}@{}Hz",
                config.width,
                config.height,
                config.refresh_rate
            );
            return Vec::new();
        }

        self.config = Some(config.clone());

        // Stop the current capture, reconfigure for the new dimensions, restart.
        vec![
            SessionCommand::StopCapture,
            SessionCommand::ReconfigurePipeline(config.clone()),
            SessionCommand::StartCapture(config),
        ]
    }

    fn on_tick(&mut self, now_micros: u64, now_ns: u64) -> Vec<SessionCommand> {
        // Heartbeat only runs while streaming.
        if self.state != SessionState::Streaming {
            return Vec::new();
        }

        // Dead peer: no packet received within the timeout → close.
        if heartbeat::is_dead(self.last_received_ns, now_ns) {
            return self.close();
        }

        // Otherwise ping on the interval.
        if heartbeat::should_ping(self.last_ping_ns, now_ns) {
            self.last_ping_ns = now_ns;
            let seq = self.next_sequence_number();
            return vec![SessionCommand::SendPacket {
                packet_type: PacketType::Ping,
                sequence_number: seq,
                timestamp_micros: now_micros,
                payload: Vec::new(),
            }];
        }

        Vec::new()
    }

    fn close(&mut self) -> Vec<SessionCommand> {
        self.state = SessionState::Disconnected;
        vec![
            SessionCommand::TransitionTo(SessionState::Disconnected),
            SessionCommand::Close,
        ]
    }

    /// Increments and returns the next sequence number (mirrors `nextSequenceNumber`;
    /// the first value handed out is `1`).
    fn next_sequence_number(&mut self) -> u64 {
        self.sequence_number += 1;
        self.sequence_number
    }
}

/// Decodes a `DeviceConfig` from a JSON payload, returning `None` on any error.
fn parse_config(payload: &[u8]) -> Option<DeviceConfig> {
    let s = std::str::from_utf8(payload).ok()?;
    DeviceConfig::from_json(s).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use displaybridge_protocol::{PacketFramer, VideoCodec};

    fn cfg(w: i32, h: i32, r: i32) -> DeviceConfig {
        DeviceConfig::new(w, h, r, VideoCodec::Hevc)
    }

    fn handshake_payload(config: &DeviceConfig) -> Vec<u8> {
        config.to_json().unwrap().into_bytes()
    }

    /// Drives a machine through Connected + a valid handshake, leaving it Streaming.
    fn streaming_machine(config: &DeviceConfig) -> SessionMachine {
        let mut m = SessionMachine::new();
        let _ = m.on_event(SessionEvent::Connected);
        let _ = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::HandshakeReq,
            payload: handshake_payload(config),
            now_micros: 1_000,
            now_ns: 1_000_000_000,
        });
        assert_eq!(m.state(), SessionState::Streaming);
        m
    }

    #[test]
    fn connected_moves_through_connecting_to_negotiating() {
        let mut m = SessionMachine::new();
        assert_eq!(m.state(), SessionState::Idle);
        let cmds = m.on_event(SessionEvent::Connected);
        assert_eq!(
            cmds,
            vec![
                SessionCommand::TransitionTo(SessionState::Connecting),
                SessionCommand::TransitionTo(SessionState::Negotiating),
            ]
        );
        assert_eq!(m.state(), SessionState::Negotiating);

        // A second Connected is a no-op.
        assert!(m.on_event(SessionEvent::Connected).is_empty());
    }

    #[test]
    fn handshake_reconfigures_acks_transitions_and_starts_capture() {
        let mut m = SessionMachine::new();
        let _ = m.on_event(SessionEvent::Connected);

        let config = cfg(1920, 1080, 60);
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::HandshakeReq,
            payload: handshake_payload(&config),
            now_micros: 42,
            now_ns: 5_000_000_000,
        });

        assert_eq!(cmds.len(), 4);
        assert_eq!(cmds[0], SessionCommand::ReconfigurePipeline(config.clone()));
        match &cmds[1] {
            SessionCommand::SendPacket {
                packet_type,
                sequence_number,
                timestamp_micros,
                payload,
            } => {
                assert_eq!(*packet_type, PacketType::HandshakeAck);
                assert_eq!(*sequence_number, 1); // first seq handed out
                assert_eq!(*timestamp_micros, 42);
                // Ack echoes the config JSON.
                let echoed = DeviceConfig::from_json(std::str::from_utf8(payload).unwrap()).unwrap();
                assert_eq!(echoed, config);
            }
            other => panic!("expected SendPacket, got {other:?}"),
        }
        assert_eq!(cmds[2], SessionCommand::TransitionTo(SessionState::Streaming));
        assert_eq!(cmds[3], SessionCommand::StartCapture(config.clone()));

        assert_eq!(m.state(), SessionState::Streaming);
        assert_eq!(m.config(), Some(&config));
    }

    #[test]
    fn duplicate_handshake_ignored_while_streaming() {
        let config = cfg(2960, 1848, 120);
        let mut m = streaming_machine(&config);

        // A second handshake (even with a different resolution) is ignored.
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::HandshakeReq,
            payload: handshake_payload(&cfg(800, 600, 30)),
            now_micros: 2_000,
            now_ns: 2_000_000_000,
        });
        assert!(cmds.is_empty());
        assert_eq!(m.state(), SessionState::Streaming);
        // Config unchanged.
        assert_eq!(m.config(), Some(&config));
    }

    #[test]
    fn invalid_handshake_config_produces_no_commands() {
        let mut m = SessionMachine::new();
        let _ = m.on_event(SessionEvent::Connected);

        // 0 width is out of range.
        let bad = cfg(0, 1080, 60);
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::HandshakeReq,
            payload: handshake_payload(&bad),
            now_micros: 1,
            now_ns: 1,
        });
        assert!(cmds.is_empty());
        assert_eq!(m.state(), SessionState::Negotiating);
    }

    fn handshake(m: &mut SessionMachine, config: &DeviceConfig, now_ns: u64) -> Vec<SessionCommand> {
        m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::HandshakeReq,
            payload: handshake_payload(config),
            now_micros: 1,
            now_ns,
        })
    }

    fn paired_machine(throttle: &Arc<Mutex<AuthThrottle>>) -> SessionMachine {
        let mut m = SessionMachine::new();
        m.require_pairing("123456".into(), throttle.clone());
        let _ = m.on_event(SessionEvent::Connected);
        m
    }

    fn with_code(code: &str) -> DeviceConfig {
        DeviceConfig { pairing_code: Some(code.into()), ..cfg(1920, 1080, 60) }
    }

    fn is_rejected(cmds: &[SessionCommand]) -> bool {
        matches!(cmds.first(), Some(SessionCommand::SendPacket { packet_type: PacketType::Error, .. }))
            && cmds.last() == Some(&SessionCommand::Close)
            && !cmds.iter().any(|c| matches!(c, SessionCommand::StartCapture(_)))
    }

    #[test]
    fn pairing_rejects_a_missing_or_wrong_code_and_never_starts_capture() {
        let throttle = Arc::new(Mutex::new(AuthThrottle::default()));

        let mut m = paired_machine(&throttle);
        assert!(is_rejected(&handshake(&mut m, &cfg(1920, 1080, 60), 1)));
        assert_eq!(m.state(), SessionState::Disconnected);

        let mut m = paired_machine(&throttle);
        assert!(is_rejected(&handshake(&mut m, &with_code("000000"), 2)));
    }

    #[test]
    fn pairing_accepts_the_right_code_without_echoing_it() {
        let throttle = Arc::new(Mutex::new(AuthThrottle::default()));
        let mut m = paired_machine(&throttle);
        let cmds = handshake(&mut m, &with_code("123456"), 1);

        assert_eq!(m.state(), SessionState::Streaming);
        let ack = cmds.iter().find_map(|c| match c {
            SessionCommand::SendPacket { packet_type: PacketType::HandshakeAck, payload, .. } => Some(payload),
            _ => None,
        });
        let ack = String::from_utf8(ack.expect("an ack was sent").clone()).unwrap();
        assert!(!ack.contains("123456") && !ack.contains("pairingCode"));
        assert_eq!(m.config().unwrap().pairing_code, None);
    }

    #[test]
    fn pairing_locks_out_even_the_right_code_after_repeated_failures() {
        let throttle = Arc::new(Mutex::new(AuthThrottle::default()));
        for i in 0..auth::MAX_FAILURES as u64 {
            assert!(is_rejected(&handshake(&mut paired_machine(&throttle), &with_code("000000"), i)));
        }
        // Locked: a guesser on a fresh connection gets nothing, right code or not.
        assert!(is_rejected(&handshake(&mut paired_machine(&throttle), &with_code("123456"), 10)));
        // After the window the right code works again.
        let mut m = paired_machine(&throttle);
        handshake(&mut m, &with_code("123456"), auth::LOCKOUT_NS + 10);
        assert_eq!(m.state(), SessionState::Streaming);
    }

    #[test]
    fn config_update_before_the_handshake_is_ignored() {
        let mut m = SessionMachine::new();
        let _ = m.on_event(SessionEvent::Connected);
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::ConfigUpdate,
            payload: handshake_payload(&cfg(1920, 1080, 60)),
            now_micros: 1,
            now_ns: 1,
        });
        assert!(cmds.is_empty());
        assert_eq!(m.state(), SessionState::Negotiating);
    }

    #[test]
    fn config_update_stops_reconfigures_and_restarts() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));

        let new_config = cfg(1080, 1920, 60); // rotated
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::ConfigUpdate,
            payload: handshake_payload(&new_config),
            now_micros: 10,
            now_ns: 6_000_000_000,
        });

        assert_eq!(
            cmds,
            vec![
                SessionCommand::StopCapture,
                SessionCommand::ReconfigurePipeline(new_config.clone()),
                SessionCommand::StartCapture(new_config.clone()),
            ]
        );
        // Stays streaming, config updated, no ack sent.
        assert_eq!(m.state(), SessionState::Streaming);
        assert_eq!(m.config(), Some(&new_config));
    }

    #[test]
    fn ping_replies_with_pong_echoing_payload() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        let seq_before = m.sequence_number();

        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::Ping,
            payload: vec![0xDE, 0xAD],
            now_micros: 777,
            now_ns: 2_000_000_000,
        });

        assert_eq!(
            cmds,
            vec![SessionCommand::SendPacket {
                packet_type: PacketType::Pong,
                sequence_number: seq_before + 1,
                timestamp_micros: 777,
                payload: vec![0xDE, 0xAD],
            }]
        );
    }

    #[test]
    fn disconnect_closes_the_session() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::Disconnect,
            payload: Vec::new(),
            now_micros: 0,
            now_ns: 2_000_000_000,
        });
        assert_eq!(
            cmds,
            vec![
                SessionCommand::TransitionTo(SessionState::Disconnected),
                SessionCommand::Close,
            ]
        );
        assert_eq!(m.state(), SessionState::Disconnected);
    }

    #[test]
    fn a_sent_packet_can_be_framed_by_the_driver() {
        // Sanity: the SendPacket fields feed straight into PacketFramer.
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        let cmds = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::Ping,
            payload: vec![1, 2, 3],
            now_micros: 9,
            now_ns: 2_000_000_000,
        });
        if let SessionCommand::SendPacket {
            packet_type,
            sequence_number,
            timestamp_micros,
            payload,
        } = &cmds[0]
        {
            let pkt = PacketFramer::create_packet(
                *packet_type,
                *sequence_number,
                *timestamp_micros,
                payload,
            );
            let (header, parsed) = PacketFramer::parse_packet(&pkt).unwrap();
            assert_eq!(header.packet_type, PacketType::Pong);
            assert_eq!(parsed, &[1, 2, 3]);
        } else {
            panic!("expected SendPacket");
        }
    }

    #[test]
    fn tick_before_interval_does_nothing() {
        // Handshake seeds last_received/last_ping at now_ns = 1s.
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        // 1s later: below the 3s ping interval.
        let cmds = m.on_event(SessionEvent::Tick {
            now_micros: 100,
            now_ns: 2_000_000_000,
        });
        assert!(cmds.is_empty());
    }

    #[test]
    fn tick_after_interval_sends_ping() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        let seq_before = m.sequence_number();
        // 4s after the 1s handshake → 3s elapsed since last ping.
        let cmds = m.on_event(SessionEvent::Tick {
            now_micros: 100,
            now_ns: 4_000_000_000,
        });
        assert_eq!(
            cmds,
            vec![SessionCommand::SendPacket {
                packet_type: PacketType::Ping,
                sequence_number: seq_before + 1,
                timestamp_micros: 100,
                payload: Vec::new(),
            }]
        );

        // A ping just sent → the next immediate tick is a no-op.
        let cmds2 = m.on_event(SessionEvent::Tick {
            now_micros: 101,
            now_ns: 4_000_000_001,
        });
        assert!(cmds2.is_empty());
    }

    #[test]
    fn tick_past_dead_timeout_closes() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        // last_received was 1s; 12s now → >10s dead timeout.
        let cmds = m.on_event(SessionEvent::Tick {
            now_micros: 0,
            now_ns: 12_000_000_000,
        });
        assert_eq!(
            cmds,
            vec![
                SessionCommand::TransitionTo(SessionState::Disconnected),
                SessionCommand::Close,
            ]
        );
        assert_eq!(m.state(), SessionState::Disconnected);
    }

    #[test]
    fn tick_ignored_when_not_streaming() {
        let mut m = SessionMachine::new();
        let _ = m.on_event(SessionEvent::Connected);
        // Negotiating, not streaming.
        let cmds = m.on_event(SessionEvent::Tick {
            now_micros: 0,
            now_ns: 999_000_000_000,
        });
        assert!(cmds.is_empty());
    }

    #[test]
    fn received_packet_resets_dead_timer() {
        let mut m = streaming_machine(&cfg(1920, 1080, 60));
        // A ping arrives at 9s, resetting last_received.
        let _ = m.on_event(SessionEvent::PacketReceived {
            packet_type: PacketType::Ping,
            payload: Vec::new(),
            now_micros: 0,
            now_ns: 9_000_000_000,
        });
        // At 12s that's only 3s of silence → not dead (still pings though).
        let cmds = m.on_event(SessionEvent::Tick {
            now_micros: 0,
            now_ns: 12_000_000_000,
        });
        // Not a Close.
        assert!(!cmds.contains(&SessionCommand::Close));
    }
}
