//! The session driver — the impure orchestrator behind the C ABI.
//!
//! This is the Rust port of what lived in the Swift `SessionCoordinator` /
//! `ServerEngine` and the Kotlin `ClientSession`: it owns the wall clock, wires a
//! [`SessionMachine`] to a transport and the native pipeline callbacks, runs the
//! frame-pacing send chain, and spins the heartbeat/stats clock thread.
//!
//! The pure decision logic stays in `displaybridge-session`; everything with side effects
//! (I/O, threads, reading the clock) lives here.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Process-global monotonic clock. Exposed to native code via
/// [`crate::ffi::displaybridge_monotonic_ns`] so that capture timestamps stamped on the
/// native side and the driver's send-time reads share one epoch. Without this, the
/// per-driver `Instant` epoch differs from a platform's capture clock (e.g. Apple's
/// `DispatchTime` uptime), and `now - capture_ns` underflows to 0 — the "latency always
/// zero" bug.
pub(crate) fn monotonic_ns() -> u64 {
    static ANCHOR: OnceLock<Instant> = OnceLock::new();
    ANCHOR.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

use displaybridge_protocol::{
    DeviceConfig, EncodedFrame, InputEvent, PacketFramer, PacketType, Role,
};
use displaybridge_session::{
    AuthThrottle, PendingFrame, PipelineMetrics, SessionCommand, SessionEvent, SessionMachine,
    SessionState,
};
use displaybridge_transport::{TcpTransport, Transport};

use crate::types::{DisplayBridgeCallbacks, DisplayBridgeSessionState, SafeCallbacks};

/// Failed pairing attempts across every source session in this process.
fn auth_throttle() -> Arc<Mutex<AuthThrottle>> {
    static THROTTLE: OnceLock<Arc<Mutex<AuthThrottle>>> = OnceLock::new();
    THROTTLE.get_or_init(Default::default).clone()
}

/// How often the clock thread wakes to feed a `Tick` and sample stats.
const TICK_INTERVAL: Duration = Duration::from_millis(1000);

/// Upper bound on how long the idle sender thread sleeps between checks. Wake-ups are
/// signalled, so this only bounds how late it notices a stop.
const SEND_IDLE_POLL: Duration = Duration::from_millis(100);

/// Granularity of the clock thread's sleep, so `destroy` can join it promptly.
const TICK_POLL: Duration = Duration::from_millis(200);

/// The driver. Held behind an `Arc` so the transport reader thread and the clock
/// thread can reference it (via `Weak`) without keeping it alive past `destroy`.
pub(crate) struct Driver {
    role: Role,
    callbacks: SafeCallbacks,

    /// The pure state machine. Locked briefly to compute commands, never held while
    /// invoking native callbacks or blocking on transport I/O.
    machine: Mutex<SessionMachine>,

    /// Built-in Rust transport (TCP). `None` when native owns the transport and
    /// pushes bytes via `feed_bytes` + the `send` callback.
    transport: Mutex<Option<Box<dyn Transport + Send>>>,

    /// Receive reassembly buffer for the native-owned transport path.
    recv_buffer: Mutex<Vec<u8>>,

    /// The sink's display config, advertised in its `HandshakeReq`. Unused by a source.
    config: Mutex<Option<DeviceConfig>>,

    /// The pairing code a sink presents in its `HandshakeReq`. A source's required
    /// code lives in the machine instead.
    pairing_code: Mutex<Option<String>>,

    // --- Source data-plane pacing ---
    /// The one encoded frame waiting for the sender thread. The capture thread fills it
    /// and returns at once, so it can encode the next frame while this one is on the
    /// wire; the pipeline is as fast as the slower of encode and send, not their sum.
    pending: Arc<PendingFrame>,
    /// Signalled when `pending` is filled or the session stops.
    send_wake: Arc<(Mutex<()>, Condvar)>,
    sender_thread: Mutex<Option<JoinHandle<()>>>,
    metrics: Mutex<Option<PipelineMetrics>>,

    /// Sequence counter for outgoing video frames (source) / control packets we
    /// originate (sink handshake). Control replies from the machine carry their own.
    out_seq: AtomicU64,

    /// True once capture has started (source) or the ack arrived (sink).
    streaming: AtomicBool,
    /// True once the session has been torn down; guards against double-close.
    closed: AtomicBool,
    /// True once the peer has sent anything. A peer that never spoke gets no goodbye.
    peer_seen: AtomicBool,

    /// Clock thread handle and its stop flag.
    tick_thread: Mutex<Option<JoinHandle<()>>>,
    stop_threads: Arc<AtomicBool>,
}

impl Driver {
    /// Creates a driver and starts its background clock thread.
    pub fn create(role: Role, callbacks: DisplayBridgeCallbacks) -> Arc<Self> {
        let driver = Arc::new(Driver {
            role,
            callbacks: SafeCallbacks(callbacks),
            machine: Mutex::new(SessionMachine::new()),
            transport: Mutex::new(None),
            recv_buffer: Mutex::new(Vec::new()),
            config: Mutex::new(None),
            pairing_code: Mutex::new(None),
            pending: Arc::new(PendingFrame::new()),
            send_wake: Arc::new((Mutex::new(()), Condvar::new())),
            sender_thread: Mutex::new(None),
            metrics: Mutex::new(None),
            out_seq: AtomicU64::new(0),
            streaming: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            peer_seen: AtomicBool::new(false),
            tick_thread: Mutex::new(None),
            stop_threads: Arc::new(AtomicBool::new(false)),
        });
        driver.spawn_clock_thread();
        if role == Role::Source {
            driver.spawn_sender_thread();
        }
        driver
    }

    // ---------------------------------------------------------------------
    // Clock helpers (only the FFI layer may read a real clock).
    // ---------------------------------------------------------------------

    /// Wall-clock microseconds since the Unix epoch (used for packet timestamps).
    fn now_micros(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_micros() as u64)
            .unwrap_or(0)
    }

    /// Monotonic nanoseconds on the process-global clock (used for heartbeat timers and
    /// send-latency). Shares its epoch with native capture timestamps via
    /// [`crate::ffi::displaybridge_monotonic_ns`].
    fn now_ns(&self) -> u64 {
        monotonic_ns()
    }

    // ---------------------------------------------------------------------
    // Configuration.
    // ---------------------------------------------------------------------

    /// Stores the config a sink advertises in its handshake. Call before connecting.
    pub fn set_config(&self, config: DeviceConfig) {
        *self.config.lock().unwrap() = Some(config);
    }

    /// Source: require `code` from every sink. Sink: present `code` in the handshake.
    /// Call before connecting.
    pub fn set_pairing_code(&self, code: String) {
        match self.role {
            Role::Source => self
                .machine
                .lock()
                .unwrap()
                .require_pairing(code, auth_throttle()),
            Role::Sink => *self.pairing_code.lock().unwrap() = Some(code),
        }
    }

    // ---------------------------------------------------------------------
    // Transport wiring.
    // ---------------------------------------------------------------------

    /// Builds a Rust-owned TCP transport, wires its callbacks to this driver, dials,
    /// and feeds a `Connected` event. Returns `false` on any failure.
    pub fn connect_tcp(self: &Arc<Self>, host: &str, port: u16) -> bool {
        let mut transport = match TcpTransport::new((host, port)) {
            Ok(t) => t,
            Err(e) => {
                log::warn!("connect_tcp: build transport failed: {e}");
                return false;
            }
        };

        // Reader/closed callbacks hold a Weak so they never keep the driver alive.
        let weak_pkt: Weak<Driver> = Arc::downgrade(self);
        transport.set_on_packet(Box::new(move |packet| {
            if let Some(d) = weak_pkt.upgrade() {
                d.on_transport_packet(packet);
            }
        }));
        let weak_closed: Weak<Driver> = Arc::downgrade(self);
        transport.set_on_closed(Box::new(move || {
            if let Some(d) = weak_closed.upgrade() {
                d.on_transport_closed();
            }
        }));

        if let Err(e) = transport.connect() {
            log::warn!("connect_tcp: connect failed: {e}");
            return false;
        }

        *self.transport.lock().unwrap() = Some(Box::new(transport));
        self.on_connected();
        true
    }

    /// Native-owned transport path: tell the driver the transport just connected, so
    /// it drives the machine to `Negotiating` and (for a sink) emits the opening
    /// `HandshakeReq`. This is the native-transport counterpart of the `Connected`
    /// event that [`connect_tcp`](Self::connect_tcp) feeds automatically. Call exactly
    /// once, after the native transport is ready and before feeding any bytes. Only
    /// use with a native-owned transport (not with the built-in Rust transport, which
    /// already fires this).
    pub fn notify_connected(self: &Arc<Self>) {
        self.on_connected();
    }

    /// Native-owned transport path: buffer received bytes, reframe, and process each
    /// complete packet. Used by the Android USB shell.
    pub fn feed_bytes(&self, data: &[u8]) {
        let packets = {
            let mut buf = self.recv_buffer.lock().unwrap();
            buf.extend_from_slice(data);
            PacketFramer::extract_packets(&mut buf)
        };
        for p in packets {
            self.on_transport_packet(p);
        }
    }

    /// Writes framed bytes over whichever transport is active. Returns whether the
    /// write was accepted.
    fn send_bytes(&self, data: &[u8]) -> bool {
        // Prefer the built-in Rust transport.
        {
            let mut guard = self.transport.lock().unwrap();
            if let Some(t) = guard.as_mut() {
                return t.send(data).is_ok();
            }
        }
        // Otherwise hand the bytes to the native-owned transport.
        if let Some(send) = self.callbacks.0.send {
            send(self.callbacks.ctx(), data.as_ptr(), data.len());
            return true;
        }
        false
    }

    // ---------------------------------------------------------------------
    // Event ingestion.
    // ---------------------------------------------------------------------

    /// The transport finished connecting. Drives the machine to `Negotiating` and,
    /// for a sink, sends the opening `HandshakeReq` with its advertised config.
    fn on_connected(self: &Arc<Self>) {
        let cmds = self.machine.lock().unwrap().on_event(SessionEvent::Connected);
        self.execute(cmds);

        if self.role == Role::Sink {
            let config = self.config.lock().unwrap().clone();
            match config {
                Some(mut cfg) => match {
                    cfg.pairing_code = self.pairing_code.lock().unwrap().clone();
                    cfg.to_json()
                } {
                    Ok(json) => {
                        let seq = self.out_seq.fetch_add(1, Ordering::Relaxed) + 1;
                        let pkt = PacketFramer::create_packet(
                            PacketType::HandshakeReq,
                            seq,
                            self.now_micros(),
                            json.as_bytes(),
                        );
                        self.send_bytes(&pkt);
                    }
                    Err(e) => log::warn!("sink handshake: config to_json failed: {e}"),
                },
                None => log::warn!("sink connected without a config; call set_config first"),
            }
        }
    }

    /// A complete packet arrived from the peer.
    fn on_transport_packet(&self, packet: Vec<u8>) {
        self.peer_seen.store(true, Ordering::Release);
        let (header, payload) = match PacketFramer::parse_packet(&packet) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("dropping malformed packet: {e}");
                return;
            }
        };

        // Feed the machine: it resets the dead-peer timer, answers Ping with Pong,
        // handles the source handshake, and closes on Disconnect. It ignores the
        // sink-only packet types (HandshakeAck / VideoFrame), returning no commands.
        let cmds = self.machine.lock().unwrap().on_event(SessionEvent::PacketReceived {
            packet_type: header.packet_type,
            payload: payload.to_vec(),
            now_micros: self.now_micros(),
            now_ns: self.now_ns(),
        });
        self.execute(cmds);

        // Sink data-plane handling that the pure machine deliberately leaves alone.
        if self.role == Role::Sink {
            match header.packet_type {
                PacketType::HandshakeAck => {
                    // The source accepted us; the native decoder can configure itself
                    // (it already knows the config it advertised). Surface Streaming.
                    self.streaming.store(true, Ordering::Release);
                    self.emit_state(SessionState::Streaming);
                }
                PacketType::VideoFrame => {
                    match PacketFramer::unwrap_video_frame(
                        payload,
                        header.sequence_number,
                        header.timestamp_micros,
                    ) {
                        Ok(frame) => self.deliver_decoded(&frame),
                        Err(e) => log::warn!("sink: bad video frame payload: {e}"),
                    }
                }
                PacketType::Error => {
                    if let (Some(cb), Ok(msg)) =
                        (self.callbacks.0.on_error, std::ffi::CString::new(payload))
                    {
                        cb(self.callbacks.ctx(), msg.as_ptr());
                    }
                }
                _ => {}
            }
        }

        // Source: pointer input from the sink. Only honoured while streaming, so a
        // peer that never completed the handshake can't drive the pointer.
        if self.role == Role::Source
            && header.packet_type == PacketType::InputEvent
            && self.streaming.load(Ordering::Acquire)
        {
            match InputEvent::decode(payload) {
                Ok(event) => {
                    if let Some(cb) = self.callbacks.0.on_input {
                        cb(self.callbacks.ctx(), event.into());
                    }
                }
                Err(e) => log::warn!("source: bad input event: {e}"),
            }
        }
    }

    /// The transport closed (peer hang-up, I/O error, or local disconnect).
    fn on_transport_closed(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.streaming.store(false, Ordering::Release);
        self.stop_threads.store(true, Ordering::Release);
        self.emit_state(SessionState::Disconnected);
    }

    // ---------------------------------------------------------------------
    // Command executor — the single place SessionCommands become side effects.
    // ---------------------------------------------------------------------

    fn execute(&self, cmds: Vec<SessionCommand>) {
        for cmd in cmds {
            match cmd {
                SessionCommand::TransitionTo(state) => self.emit_state(state),
                SessionCommand::SendPacket {
                    packet_type,
                    sequence_number,
                    timestamp_micros,
                    payload,
                } => {
                    let pkt = PacketFramer::create_packet(
                        packet_type,
                        sequence_number,
                        timestamp_micros,
                        &payload,
                    );
                    self.send_bytes(&pkt);
                }
                SessionCommand::ReconfigurePipeline(config) => {
                    self.callbacks
                        .call_with_config(self.callbacks.0.reconfigure, &config);
                }
                SessionCommand::StartCapture(config) => {
                    // Fresh metrics interval for this streaming session.
                    *self.metrics.lock().unwrap() = Some(PipelineMetrics::new(self.now_ns()));
                    self.streaming.store(true, Ordering::Release);
                    self.callbacks
                        .call_with_config(self.callbacks.0.start_capture, &config);
                }
                SessionCommand::StopCapture => {
                    self.streaming.store(false, Ordering::Release);
                    if let Some(cb) = self.callbacks.0.stop_capture {
                        cb(self.callbacks.ctx());
                    }
                }
                SessionCommand::Close => self.do_close(),
            }
        }
    }

    /// Tears the session down: notify the peer, stop capture, and drop the transport.
    fn do_close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.streaming.store(false, Ordering::Release);

        // Best-effort explicit Disconnect so the peer (esp. USB) notices immediately.
        // Skipped for a peer that never said anything: nobody is reading, and over USB
        // that write only returns after a multi-second timeout.
        if self.peer_seen.load(Ordering::Acquire) {
            let pkt = PacketFramer::create_packet(PacketType::Disconnect, 0, self.now_micros(), &[]);
            self.send_bytes(&pkt);
        }

        if let Some(cb) = self.callbacks.0.stop_capture {
            cb(self.callbacks.ctx());
        }

        self.stop_threads.store(true, Ordering::Release);
        if let Some(t) = self.transport.lock().unwrap().as_mut() {
            t.disconnect();
        }
    }

    // ---------------------------------------------------------------------
    // Native callback emitters.
    // ---------------------------------------------------------------------

    fn emit_state(&self, state: SessionState) {
        if let Some(cb) = self.callbacks.0.on_state_change {
            cb(self.callbacks.ctx(), DisplayBridgeSessionState::from(state));
        }
    }

    fn deliver_decoded(&self, frame: &EncodedFrame) {
        if let Some(cb) = self.callbacks.0.decode {
            cb(
                self.callbacks.ctx(),
                frame.data.as_ptr(),
                frame.data.len(),
                frame.is_keyframe,
                frame.timestamp_micros,
            );
        }
    }

    // ---------------------------------------------------------------------
    // Sink input plane — forward a pointer event to the source.
    // ---------------------------------------------------------------------

    /// Frames `event` as an `InputEvent` packet and sends it to the source. Returns
    /// `false` if this is not a streaming sink or the write was not accepted.
    pub fn send_input(&self, event: &InputEvent) -> bool {
        if self.role != Role::Sink || !self.streaming.load(Ordering::Acquire) {
            return false;
        }
        let seq = self.out_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let pkt = PacketFramer::create_packet(
            PacketType::InputEvent,
            seq,
            self.now_micros(),
            &event.encode(),
        );
        self.send_bytes(&pkt)
    }

    // ---------------------------------------------------------------------
    // Source data plane — submit an already-encoded frame.
    // ---------------------------------------------------------------------

    /// Whether the native pipeline should encode the frame it just captured. `false`
    /// while not streaming, or while the previous frame is still waiting for the wire:
    /// the link is the bottleneck, and the frame must be skipped *before* encoding. An
    /// encoded frame that is then dropped leaves a hole in the reference chain and
    /// corrupts the picture until the next keyframe; a frame never encoded does not.
    pub fn wants_frame(&self) -> bool {
        if !self.streaming.load(Ordering::Acquire) {
            return false;
        }
        if self.pending.has_pending() {
            // Captured but skipped: counts towards the dropped percentage.
            if let Some(m) = self.metrics.lock().unwrap().as_ref() {
                m.record_capture();
            }
            return false;
        }
        true
    }

    /// Accepts a hardware-encoded frame from the native source pipeline and hands it to
    /// the sender thread. Returns immediately; the blocking write happens off this
    /// thread. Callers should ask [`wants_frame`](Self::wants_frame) before encoding.
    pub fn submit_frame(&self, encoded: &[u8], is_keyframe: bool, capture_time_ns: u64) {
        if !self.streaming.load(Ordering::Acquire) {
            return;
        }

        if let Some(m) = self.metrics.lock().unwrap().as_ref() {
            m.record_capture();
        }

        // A caller that skipped `wants_frame` may still arrive while a frame is staged;
        // keep the staged one, since later frames reference it.
        if self.pending.has_pending() {
            return;
        }

        let seq = self.out_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let frame = EncodedFrame {
            data: encoded.to_vec(),
            is_keyframe,
            sequence_number: seq,
            timestamp_micros: self.now_micros(),
        };
        let packet = PacketFramer::wrap_video_frame(&frame);
        self.pending.set(packet, capture_time_ns);

        // Taking the lock before notifying means the sender can't miss the wake-up
        // between checking `pending` and going to sleep.
        let (lock, wake) = &*self.send_wake;
        let _guard = lock.lock().unwrap();
        wake.notify_one();
    }

    fn spawn_sender_thread(self: &Arc<Self>) {
        let weak: Weak<Driver> = Arc::downgrade(self);
        let pending = self.pending.clone();
        let send_wake = self.send_wake.clone();
        let stop = self.stop_threads.clone();
        let handle = thread::Builder::new()
            .name("displaybridge-ffi-send".into())
            .spawn(move || loop {
                {
                    let (lock, wake) = &*send_wake;
                    let mut guard = lock.lock().unwrap();
                    while !pending.has_pending() && !stop.load(Ordering::Acquire) {
                        guard = wake.wait_timeout(guard, SEND_IDLE_POLL).unwrap().0;
                    }
                }
                if stop.load(Ordering::Acquire) {
                    break;
                }
                let Some(driver) = weak.upgrade() else { break };
                driver.send_pending();
            })
            .ok();
        *self.sender_thread.lock().unwrap() = handle;
    }

    /// Sends the staged frame (a blocking write, which is the pipeline's backpressure)
    /// and records how long it took from capture to the wire.
    fn send_pending(&self) {
        let Some((packet, capture_ns)) = self.pending.take() else {
            return;
        };
        let size = packet.len() as u64;
        self.send_bytes(&packet);
        let latency_us = self.now_ns().saturating_sub(capture_ns) / 1000;
        if let Some(m) = self.metrics.lock().unwrap().as_ref() {
            m.record_sent(latency_us, size);
        }
    }

    // ---------------------------------------------------------------------
    // Clock thread.
    // ---------------------------------------------------------------------

    fn spawn_clock_thread(self: &Arc<Self>) {
        let weak: Weak<Driver> = Arc::downgrade(self);
        let stop = self.stop_threads.clone();
        let handle = thread::Builder::new()
            .name("displaybridge-ffi-clock".into())
            .spawn(move || {
                let mut elapsed = Duration::ZERO;
                loop {
                    if stop.load(Ordering::Acquire) {
                        break;
                    }
                    thread::sleep(TICK_POLL);
                    elapsed += TICK_POLL;
                    if elapsed < TICK_INTERVAL {
                        continue;
                    }
                    elapsed = Duration::ZERO;

                    let Some(driver) = weak.upgrade() else { break };
                    driver.on_tick();
                }
            })
            .ok();
        *self.tick_thread.lock().unwrap() = handle;
    }

    /// One clock tick: drive the machine's heartbeat and emit a stats snapshot.
    fn on_tick(&self) {
        let cmds = self.machine.lock().unwrap().on_event(SessionEvent::Tick {
            now_micros: self.now_micros(),
            now_ns: self.now_ns(),
        });
        self.execute(cmds);

        // Source stats: snapshot the interval and report it.
        if let Some(cb) = self.callbacks.0.on_stats {
            let snapshot = self
                .metrics
                .lock()
                .unwrap()
                .as_ref()
                .map(|m| m.snapshot(self.now_ns()));
            if let Some(stats) = snapshot {
                cb(self.callbacks.ctx(), stats.client_stats().into());
            }
        }
    }

    // ---------------------------------------------------------------------
    // Teardown.
    // ---------------------------------------------------------------------

    /// Stops all threads and disconnects the transport. Called from `displaybridge_session_destroy`
    /// before the handle is freed. Idempotent.
    pub fn shutdown(&self) {
        // Destroying a live session must end it the same way a peer Disconnect does:
        // tell the peer and stop capture. Otherwise the native capture keeps running
        // and submits frames to a handle that is about to be freed. No-op if the
        // session already closed.
        self.do_close();
        self.stop_threads.store(true, Ordering::Release);
        if let Some(h) = self.tick_thread.lock().unwrap().take() {
            let _ = h.join();
        }
        self.send_wake.1.notify_all();
        if let Some(h) = self.sender_thread.lock().unwrap().take() {
            let _ = h.join();
        }
        // Dropping the transport shuts down its socket; its reader thread then exits.
        if let Some(mut t) = self.transport.lock().unwrap().take() {
            t.disconnect();
        }
    }
}
