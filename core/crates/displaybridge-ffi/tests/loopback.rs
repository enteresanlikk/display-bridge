//! End-to-end loopback tests that exercise the C ABI without any native code.
//!
//! A `TcpListenerTransport` stands in for the peer on the other end of the wire, and
//! the driver's own `displaybridge_session_connect_tcp` dials it. We assert the real handshake
//! direction: the **sink** connects and sends `HandshakeReq`; the **source** replies
//! `HandshakeAck` and starts capture.

use std::ffi::{c_void, CString};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;

use displaybridge_ffi::{
    displaybridge_monotonic_ns, displaybridge_session_connect_tcp, displaybridge_session_create,
    displaybridge_session_destroy, displaybridge_session_feed_bytes, displaybridge_session_notify_connected,
    displaybridge_session_send_input, displaybridge_session_set_config, displaybridge_session_set_pairing_code,
    displaybridge_session_submit_frame, displaybridge_session_wants_frame,
    DisplayBridgeCallbacks, DisplayBridgeClientStats, DisplayBridgeDeviceConfig, DisplayBridgeInputEvent,
    DisplayBridgePlatform, DisplayBridgeRole, DisplayBridgeSessionState, DisplayBridgeVideoCodec,
};
use displaybridge_protocol::{DeviceConfig, PacketFramer, PacketType, VideoCodec};
use displaybridge_transport::{TcpListenerTransport, TcpTransport, Transport};

const TIMEOUT: Duration = Duration::from_secs(3);

/// Shared state the C callbacks write into.
#[derive(Default)]
struct TestCtx {
    decoded: Mutex<Vec<(Vec<u8>, bool, u64)>>,
    states: Mutex<Vec<u32>>,
    reconfigure_calls: AtomicUsize,
    start_capture_calls: AtomicUsize,
    stop_capture_calls: AtomicUsize,
    last_config: Mutex<Option<(i32, i32, i32)>>,
    /// The platform the sink reported, as the source's `reconfigure` callback saw it.
    last_platform: Mutex<Option<DisplayBridgePlatform>>,
    /// Framed bytes the session emitted through the native `send` callback
    /// (used by the in-process native-transport loopback test).
    out: Mutex<Vec<Vec<u8>>>,
    /// Latest avg send-latency reported via the `on_stats` callback.
    last_avg_latency_ms: Mutex<Option<f64>>,
    /// Pointer events delivered through the source's `on_input` callback.
    inputs: Mutex<Vec<DisplayBridgeInputEvent>>,
    /// Refusal messages delivered through the sink's `on_error` callback.
    errors: Mutex<Vec<String>>,
}

/// `on_error` callback: records why the peer refused the session.
extern "C" fn cb_error(ctx: *mut c_void, message: *const std::ffi::c_char) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    let msg = unsafe { std::ffi::CStr::from_ptr(message) }.to_string_lossy().into_owned();
    c.errors.lock().unwrap().push(msg);
}

/// `on_input` callback: records the pointer event the source was asked to inject.
extern "C" fn cb_input(ctx: *mut c_void, event: DisplayBridgeInputEvent) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    c.inputs.lock().unwrap().push(event);
}

/// `on_stats` callback: records the reported average send latency.
extern "C" fn cb_stats(ctx: *mut c_void, stats: DisplayBridgeClientStats) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    *c.last_avg_latency_ms.lock().unwrap() = Some(stats.avg_latency_ms);
}

/// Native `send` callback: stashes the framed bytes for the test to forward to the peer.
extern "C" fn cb_send(ctx: *mut c_void, data: *const u8, len: usize) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
    c.out.lock().unwrap().push(bytes);
}

fn empty_callbacks(ctx: *mut c_void) -> DisplayBridgeCallbacks {
    DisplayBridgeCallbacks {
        ctx,
        send: None,
        reconfigure: None,
        start_capture: None,
        stop_capture: None,
        decode: None,
        on_state_change: None,
        on_stats: None,
        on_input: None,
        on_error: None,
    }
}

extern "C" fn cb_decode(
    ctx: *mut c_void,
    nal: *const u8,
    len: usize,
    is_keyframe: bool,
    timestamp_micros: u64,
) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    let data = unsafe { std::slice::from_raw_parts(nal, len) }.to_vec();
    c.decoded
        .lock()
        .unwrap()
        .push((data, is_keyframe, timestamp_micros));
}

extern "C" fn cb_state(ctx: *mut c_void, state: DisplayBridgeSessionState) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    c.states.lock().unwrap().push(state as u32);
}

extern "C" fn cb_reconfigure(ctx: *mut c_void, config: *const DisplayBridgeDeviceConfig) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    c.reconfigure_calls.fetch_add(1, Ordering::SeqCst);
    if let Some(cfg) = unsafe { config.as_ref() } {
        *c.last_platform.lock().unwrap() = Some(cfg.platform);
        *c.last_config.lock().unwrap() = Some((cfg.width, cfg.height, cfg.refresh_rate));
    }
}

extern "C" fn cb_start_capture(ctx: *mut c_void, config: *const DisplayBridgeDeviceConfig) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    c.start_capture_calls.fetch_add(1, Ordering::SeqCst);
    if let Some(cfg) = unsafe { config.as_ref() } {
        *c.last_config.lock().unwrap() = Some((cfg.width, cfg.height, cfg.refresh_rate));
    }
}

extern "C" fn cb_stop_capture(ctx: *mut c_void) {
    let c = unsafe { &*(ctx as *const TestCtx) };
    c.stop_capture_calls.fetch_add(1, Ordering::SeqCst);
}

/// Binds a loopback listener and returns the peer transport (already reading, with a
/// channel of the packets it receives) plus the address the driver should dial.
fn start_peer() -> (
    u16,
    mpsc::Receiver<TcpTransport>,
    mpsc::Receiver<Vec<u8>>,
    TcpListenerTransport,
) {
    let mut listener = TcpListenerTransport::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();

    let (peer_tx, peer_rx) = mpsc::channel();
    let (pkt_tx, pkt_rx) = mpsc::channel();
    listener.accept_loop(Box::new(move |mut t: TcpTransport| {
        let pkt_tx = pkt_tx.clone();
        t.set_on_packet(Box::new(move |p| {
            let _ = pkt_tx.send(p);
        }));
        t.connect().unwrap();
        let _ = peer_tx.send(t);
    }));

    (port, peer_rx, pkt_rx, listener)
}

fn recv_packet(rx: &mpsc::Receiver<Vec<u8>>) -> (PacketType, Vec<u8>, u64, u64) {
    let raw = rx.recv_timeout(TIMEOUT).expect("packet within timeout");
    let (header, payload) = PacketFramer::parse_packet(&raw).expect("valid packet");
    (
        header.packet_type,
        payload.to_vec(),
        header.sequence_number,
        header.timestamp_micros,
    )
}

#[test]
fn sink_connects_sends_handshake_and_decodes_frames() {
    let ctx = Box::new(TestCtx::default());
    let ctx_ptr = &*ctx as *const TestCtx as *mut c_void;

    let (port, peer_rx, peer_pkts, _listener) = start_peer();

    // Build a SINK session with a decode + state callback.
    let mut callbacks = empty_callbacks(ctx_ptr);
    callbacks.decode = Some(cb_decode);
    callbacks.on_state_change = Some(cb_state);
    let handle = displaybridge_session_create(DisplayBridgeRole::Sink, callbacks);
    assert!(!handle.is_null());

    // The sink advertises this config in its HandshakeReq.
    let name = CString::new("TestSink").unwrap();
    let cfg = DisplayBridgeDeviceConfig {
        width: 1920,
        height: 1080,
        refresh_rate: 60,
        codec: DisplayBridgeVideoCodec::Hevc,
        device_name: name.as_ptr(),
        platform: DisplayBridgePlatform::Unknown,
    };
    assert!(unsafe { displaybridge_session_set_config(handle, &cfg) });

    // Connect: the driver dials the peer and sends its HandshakeReq.
    let host = CString::new("127.0.0.1").unwrap();
    assert!(unsafe { displaybridge_session_connect_tcp(handle, host.as_ptr(), port) });

    // The test peer (playing the source) accepts and reads the HandshakeReq.
    let mut peer = peer_rx.recv_timeout(TIMEOUT).expect("peer accepted");
    let (ptype, payload, _, _) = recv_packet(&peer_pkts);
    assert_eq!(ptype, PacketType::HandshakeReq);
    let got = DeviceConfig::from_json(std::str::from_utf8(&payload).unwrap()).unwrap();
    assert_eq!(got.width, 1920);
    assert_eq!(got.height, 1080);
    assert_eq!(got.device_name.as_deref(), Some("TestSink"));

    // Peer replies HandshakeAck, echoing the config.
    let ack = PacketFramer::create_packet(PacketType::HandshakeAck, 1, 100, &payload);
    peer.send(&ack).unwrap();

    // Peer streams a couple of video frames.
    let frame_a = DeviceFrame::key(vec![0xAA, 0xBB, 0xCC], 5, 111);
    let frame_b = DeviceFrame::delta(vec![0x01, 0x02], 6, 222);
    peer.send(&frame_a.wrapped()).unwrap();
    peer.send(&frame_b.wrapped()).unwrap();

    // The sink decode callback must receive both NALs with correct keyframe flags.
    let decoded = wait_for(TIMEOUT, || {
        let d = ctx.decoded.lock().unwrap();
        if d.len() >= 2 {
            Some(d.clone())
        } else {
            None
        }
    })
    .expect("two frames decoded");

    assert_eq!(decoded[0].0, vec![0xAA, 0xBB, 0xCC]);
    assert!(decoded[0].1, "first frame is a keyframe");
    assert_eq!(decoded[0].2, 111);
    assert_eq!(decoded[1].0, vec![0x01, 0x02]);
    assert!(!decoded[1].1, "second frame is a delta frame");

    // A Streaming state transition was surfaced on the HandshakeAck.
    assert!(ctx
        .states
        .lock()
        .unwrap()
        .contains(&(DisplayBridgeSessionState::Streaming as u32)));

    unsafe { displaybridge_session_destroy(handle) };
    peer.disconnect();
    drop(ctx);
}

#[test]
fn source_replies_ack_starts_capture_and_streams_frames() {
    let ctx = Box::new(TestCtx::default());
    let ctx_ptr = &*ctx as *const TestCtx as *mut c_void;

    let (port, peer_rx, peer_pkts, _listener) = start_peer();

    // Build a SOURCE session with reconfigure/start_capture/state callbacks.
    let mut callbacks = empty_callbacks(ctx_ptr);
    callbacks.reconfigure = Some(cb_reconfigure);
    callbacks.start_capture = Some(cb_start_capture);
    callbacks.on_state_change = Some(cb_state);
    let handle = displaybridge_session_create(DisplayBridgeRole::Source, callbacks);
    assert!(!handle.is_null());

    // The source dials the peer (which plays the sink) and waits for the handshake.
    let host = CString::new("127.0.0.1").unwrap();
    assert!(unsafe { displaybridge_session_connect_tcp(handle, host.as_ptr(), port) });
    let mut peer = peer_rx.recv_timeout(TIMEOUT).expect("peer accepted");

    // Peer (sink) sends a HandshakeReq with its config.
    let sink_cfg = DeviceConfig::new(1280, 720, 30, VideoCodec::H264);
    let req = PacketFramer::create_packet(
        PacketType::HandshakeReq,
        1,
        10,
        sink_cfg.to_json().unwrap().as_bytes(),
    );
    peer.send(&req).unwrap();

    // The source must reconfigure, start capture, and reply HandshakeAck.
    let (ptype, ack_payload, _, _) = recv_packet(&peer_pkts);
    assert_eq!(ptype, PacketType::HandshakeAck);
    let echoed = DeviceConfig::from_json(std::str::from_utf8(&ack_payload).unwrap()).unwrap();
    assert_eq!(echoed, sink_cfg);

    let started = wait_for(TIMEOUT, || {
        if ctx.start_capture_calls.load(Ordering::SeqCst) >= 1 {
            Some(())
        } else {
            None
        }
    });
    assert!(started.is_some(), "start_capture was invoked");
    assert!(ctx.reconfigure_calls.load(Ordering::SeqCst) >= 1);
    assert_eq!(*ctx.last_config.lock().unwrap(), Some((1280, 720, 30)));

    // Now feed an encoded frame; a framed VideoFrame must go out on the wire.
    let nal = vec![0xDE, 0xAD, 0xBE, 0xEF];
    unsafe { displaybridge_session_submit_frame(handle, nal.as_ptr(), nal.len(), true, 42) };

    // The peer receives it (skip past any control packets like Ping just in case).
    let mut video_payload = None;
    for _ in 0..5 {
        let (ptype, payload, _, _) = recv_packet(&peer_pkts);
        if ptype == PacketType::VideoFrame {
            video_payload = Some(payload);
            break;
        }
    }
    let payload = video_payload.expect("received a VideoFrame");
    let frame = PacketFramer::unwrap_video_frame(&payload, 0, 0).unwrap();
    assert_eq!(frame.data, nal);
    assert!(frame.is_keyframe);

    unsafe { displaybridge_session_destroy(handle) };
    peer.disconnect();
    drop(ctx);
}

/// Native-owned-transport loopback with NO sockets: two driver sessions (a source and
/// a sink) wired directly through the `send` ↔ `feed_bytes` path, kicked by
/// `notify_connected`. This is exactly the transport-agnostic path the macOS live
/// `SessionCoordinator`/`ServerEngine` rewire uses (Swift owns the socket/USB I/O and
/// only shuttles bytes across the FFI). Control packets are sent synchronously inside
/// the call that triggers them; video frames go out on the driver's sender thread, so
/// those are awaited.
#[test]
fn native_transport_inprocess_source_sink_loopback() {
    fn drain_to(from: &TestCtx, to_handle: *mut displaybridge_ffi::DisplayBridgeSession) {
        let msgs: Vec<Vec<u8>> = from.out.lock().unwrap().drain(..).collect();
        for m in msgs {
            unsafe { displaybridge_session_feed_bytes(to_handle, m.as_ptr(), m.len()) };
        }
    }

    let source_ctx = Box::new(TestCtx::default());
    let sink_ctx = Box::new(TestCtx::default());
    let source_ptr = &*source_ctx as *const TestCtx as *mut c_void;
    let sink_ptr = &*sink_ctx as *const TestCtx as *mut c_void;

    // Source: send + reconfigure + start_capture + state.
    let mut s_cb = empty_callbacks(source_ptr);
    s_cb.send = Some(cb_send);
    s_cb.reconfigure = Some(cb_reconfigure);
    s_cb.start_capture = Some(cb_start_capture);
    s_cb.on_state_change = Some(cb_state);
    s_cb.on_input = Some(cb_input);
    let source = displaybridge_session_create(DisplayBridgeRole::Source, s_cb);
    assert!(!source.is_null());

    // Sink: send + decode + state.
    let mut k_cb = empty_callbacks(sink_ptr);
    k_cb.send = Some(cb_send);
    k_cb.decode = Some(cb_decode);
    k_cb.on_state_change = Some(cb_state);
    let sink = displaybridge_session_create(DisplayBridgeRole::Sink, k_cb);
    assert!(!sink.is_null());

    // The sink advertises its config, then "connects" over its native transport.
    let name = CString::new("InProcSink").unwrap();
    let cfg = DisplayBridgeDeviceConfig {
        width: 2400,
        height: 1080,
        refresh_rate: 90,
        codec: DisplayBridgeVideoCodec::Hevc,
        device_name: name.as_ptr(),
        platform: DisplayBridgePlatform::Unknown,
    };
    assert!(unsafe { displaybridge_session_set_config(sink, &cfg) });

    let tap = DisplayBridgeInputEvent {
        kind: 0,
        button: 0,
        x: 0.25,
        y: 0.5,
        dx: 0.0,
        dy: 0.0,
        pressure: 1.0,
    };

    // Before the handshake a sink can't send input at all.
    assert!(!unsafe { displaybridge_session_send_input(sink, tap) });

    // 1. Sink connected -> emits HandshakeReq; forward it to the source.
    unsafe { displaybridge_session_notify_connected(sink) };
    drain_to(&sink_ctx, source);

    // The source reconfigured + started capture at the sink's advertised resolution.
    assert!(source_ctx.reconfigure_calls.load(Ordering::SeqCst) >= 1);
    assert!(source_ctx.start_capture_calls.load(Ordering::SeqCst) >= 1);
    assert_eq!(*source_ctx.last_config.lock().unwrap(), Some((2400, 1080, 90)));
    // The sink left its platform unset, so the core reported the one it runs on.
    let here = DisplayBridgePlatform::from(displaybridge_protocol::Platform::current());
    assert_ne!(here, DisplayBridgePlatform::Unknown);
    assert_eq!(*source_ctx.last_platform.lock().unwrap(), Some(here));

    // 2. Forward the source's HandshakeAck back to the sink -> it goes Streaming.
    drain_to(&source_ctx, sink);
    assert!(sink_ctx
        .states
        .lock()
        .unwrap()
        .contains(&(DisplayBridgeSessionState::Streaming as u32)));

    // 3. The source submits an encoded frame; it is framed, paced, and sent; forward
    //    it to the sink, which decodes the exact NAL with its keyframe flag intact.
    let nal = vec![0x11, 0x22, 0x33, 0x44];
    assert!(unsafe { displaybridge_session_wants_frame(source) });
    unsafe { displaybridge_session_submit_frame(source, nal.as_ptr(), nal.len(), true, 7) };
    wait_for(TIMEOUT, || (!source_ctx.out.lock().unwrap().is_empty()).then_some(())).expect("frame sent");
    drain_to(&source_ctx, sink);

    let decoded = sink_ctx.decoded.lock().unwrap().clone();
    assert_eq!(decoded.len(), 1, "sink decoded exactly one frame");
    assert_eq!(decoded[0].0, nal, "NAL bytes round-tripped source->sink");
    assert!(decoded[0].1, "keyframe flag preserved");

    // 4. The sink sends a pointer event; the source hands it to `on_input` intact.
    assert!(unsafe { displaybridge_session_send_input(sink, tap) });
    drain_to(&sink_ctx, source);
    {
        let inputs = source_ctx.inputs.lock().unwrap();
        assert_eq!(inputs.len(), 1, "source received exactly one input event");
        assert_eq!((inputs[0].kind, inputs[0].button), (0, 0));
        assert_eq!((inputs[0].x, inputs[0].y, inputs[0].pressure), (0.25, 0.5, 1.0));
    }

    // An unknown kind is refused at the boundary, and only a sink may send input.
    assert!(!unsafe { displaybridge_session_send_input(sink, DisplayBridgeInputEvent { kind: 9, ..tap }) });
    assert!(!unsafe { displaybridge_session_send_input(source, tap) });

    unsafe { displaybridge_session_destroy(source) };
    unsafe { displaybridge_session_destroy(sink) };
    drop(source_ctx);
    drop(sink_ctx);
}

/// Regression test for a use-after-free crash: destroying a streaming source (what the
/// shell does when its transport drops) must stop capture and send `Disconnect` before
/// the handle is freed, or the native capture thread keeps submitting frames to it.
#[test]
fn destroying_a_streaming_source_stops_capture_and_says_goodbye() {
    let ctx = Box::new(TestCtx::default());
    let mut cb = empty_callbacks(&*ctx as *const TestCtx as *mut c_void);
    cb.send = Some(cb_send);
    cb.start_capture = Some(cb_start_capture);
    cb.stop_capture = Some(cb_stop_capture);
    let handle = displaybridge_session_create(DisplayBridgeRole::Source, cb);

    let cfg = DeviceConfig::new(1280, 720, 60, VideoCodec::Hevc);
    let req = PacketFramer::create_packet(PacketType::HandshakeReq, 1, 10, cfg.to_json().unwrap().as_bytes());
    unsafe { displaybridge_session_feed_bytes(handle, req.as_ptr(), req.len()) };
    assert_eq!(ctx.start_capture_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ctx.stop_capture_calls.load(Ordering::SeqCst), 0);

    unsafe { displaybridge_session_destroy(handle) };

    assert_eq!(ctx.stop_capture_calls.load(Ordering::SeqCst), 1, "capture stopped exactly once");
    let out = ctx.out.lock().unwrap();
    let (last, _) = PacketFramer::parse_packet(out.last().unwrap()).unwrap();
    assert_eq!(last.packet_type, PacketType::Disconnect);
}

/// A session whose peer never said a word (a phone plugged in with the app closed) is
/// torn down silently: writing a goodbye nobody reads costs seconds over USB.
#[test]
fn destroying_a_session_that_never_heard_from_its_peer_sends_nothing() {
    let ctx = Box::new(TestCtx::default());
    let mut cb = empty_callbacks(&*ctx as *const TestCtx as *mut c_void);
    cb.send = Some(cb_send);
    let handle = displaybridge_session_create(DisplayBridgeRole::Source, cb);
    unsafe { displaybridge_session_notify_connected(handle) };
    unsafe { displaybridge_session_destroy(handle) };
    assert!(ctx.out.lock().unwrap().is_empty());
}

/// The capture thread must never wait for the wire. With a link that takes 150 ms per
/// write, submitting a frame returns at once; while that frame is in flight exactly one
/// more may be staged, and after that `wants_frame` says "skip" so the caller does not
/// encode a frame that would have to be dropped.
#[test]
fn slow_link_does_not_block_the_capture_thread() {
    extern "C" fn slow_send(ctx: *mut c_void, data: *const u8, len: usize) {
        let is_video = len > 4 && unsafe { *data.add(4) } == PacketType::VideoFrame as u8;
        if is_video {
            std::thread::sleep(Duration::from_millis(150));
        }
        cb_send(ctx, data, len);
    }

    let ctx = Box::new(TestCtx::default());
    let mut cb = empty_callbacks(&*ctx as *const TestCtx as *mut c_void);
    cb.send = Some(slow_send);
    cb.start_capture = Some(cb_start_capture);
    let handle = displaybridge_session_create(DisplayBridgeRole::Source, cb);

    assert!(!unsafe { displaybridge_session_wants_frame(handle) }, "not streaming yet");
    let cfg = DeviceConfig::new(1280, 720, 60, VideoCodec::Hevc);
    let req = PacketFramer::create_packet(PacketType::HandshakeReq, 1, 10, cfg.to_json().unwrap().as_bytes());
    unsafe { displaybridge_session_feed_bytes(handle, req.as_ptr(), req.len()) };

    let nal = [0x01u8, 0x02, 0x03];
    let started = std::time::Instant::now();
    assert!(unsafe { displaybridge_session_wants_frame(handle) });
    unsafe { displaybridge_session_submit_frame(handle, nal.as_ptr(), nal.len(), true, 1) };
    assert!(started.elapsed() < Duration::from_millis(100), "submit returned without waiting for the write");

    // Frame 1 is now in the slow write: one more frame fits behind it, a third does not.
    std::thread::sleep(Duration::from_millis(30));
    assert!(unsafe { displaybridge_session_wants_frame(handle) });
    unsafe { displaybridge_session_submit_frame(handle, nal.as_ptr(), nal.len(), false, 2) };
    assert!(!unsafe { displaybridge_session_wants_frame(handle) }, "slot full: skip before encoding");

    // Both staged frames reach the wire, in order, and then the pipeline accepts again.
    let frames = |c: &TestCtx| {
        c.out.lock().unwrap().iter().filter(|p| p[4] == PacketType::VideoFrame as u8).count()
    };
    wait_for(TIMEOUT, || (frames(&ctx) == 2).then_some(())).expect("both frames sent");
    assert!(unsafe { displaybridge_session_wants_frame(handle) });

    unsafe { displaybridge_session_destroy(handle) };
}

/// Pairing over the C ABI: a source that requires a code refuses a sink presenting the
/// wrong one (the sink is told why, capture never starts, no frame leaves), and
/// accepts a sink presenting the right one.
#[test]
fn pairing_code_gates_the_handshake() {
    fn pair(sink_code: &str) -> (Box<TestCtx>, Box<TestCtx>) {
        let source_ctx = Box::new(TestCtx::default());
        let sink_ctx = Box::new(TestCtx::default());

        let mut s_cb = empty_callbacks(&*source_ctx as *const TestCtx as *mut c_void);
        s_cb.send = Some(cb_send);
        s_cb.start_capture = Some(cb_start_capture);
        let source = displaybridge_session_create(DisplayBridgeRole::Source, s_cb);

        let mut k_cb = empty_callbacks(&*sink_ctx as *const TestCtx as *mut c_void);
        k_cb.send = Some(cb_send);
        k_cb.decode = Some(cb_decode);
        k_cb.on_error = Some(cb_error);
        let sink = displaybridge_session_create(DisplayBridgeRole::Sink, k_cb);

        let required = CString::new("482913").unwrap();
        let presented = CString::new(sink_code).unwrap();
        assert!(unsafe { displaybridge_session_set_pairing_code(source, required.as_ptr()) });
        assert!(unsafe { displaybridge_session_set_pairing_code(sink, presented.as_ptr()) });

        let cfg = DisplayBridgeDeviceConfig {
            width: 1280,
            height: 720,
            refresh_rate: 60,
            codec: DisplayBridgeVideoCodec::Hevc,
            device_name: std::ptr::null(),
            platform: DisplayBridgePlatform::Unknown,
        };
        assert!(unsafe { displaybridge_session_set_config(sink, &cfg) });

        let forward = |from: &TestCtx, to| {
            let msgs: Vec<Vec<u8>> = from.out.lock().unwrap().drain(..).collect();
            for m in msgs {
                unsafe { displaybridge_session_feed_bytes(to, m.as_ptr(), m.len()) };
            }
        };
        unsafe { displaybridge_session_notify_connected(source) };
        unsafe { displaybridge_session_notify_connected(sink) };
        forward(&sink_ctx, source); // HandshakeReq
        forward(&source_ctx, sink); // HandshakeAck, or Error + Disconnect

        // Whatever happened, try to stream a frame and send input.
        let nal = [0xAAu8, 0xBB];
        unsafe { displaybridge_session_submit_frame(source, nal.as_ptr(), nal.len(), true, 1) };
        // The frame (if the session is streaming at all) leaves on the sender thread.
        std::thread::sleep(Duration::from_millis(150));
        forward(&source_ctx, sink);

        unsafe { displaybridge_session_destroy(source) };
        unsafe { displaybridge_session_destroy(sink) };
        (source_ctx, sink_ctx)
    }

    let (source, sink) = pair("000000");
    assert_eq!(source.start_capture_calls.load(Ordering::SeqCst), 0, "capture must not start");
    assert!(sink.decoded.lock().unwrap().is_empty(), "no frame may reach an unpaired sink");
    assert_eq!(sink.errors.lock().unwrap().len(), 1, "the sink is told why it was refused");
    assert!(sink.errors.lock().unwrap()[0].contains("pairing code"));

    let (source, sink) = pair("482913");
    assert_eq!(source.start_capture_calls.load(Ordering::SeqCst), 1);
    assert_eq!(sink.decoded.lock().unwrap().len(), 1);
    assert!(sink.errors.lock().unwrap().is_empty());
}

/// Regression test for the "latency always zero" bug: the driver's send-latency read
/// and the native capture stamp must share one epoch (the core's monotonic clock). We
/// stamp `capture_ns` from `displaybridge_monotonic_ns`, wait a real 5 ms, then submit;
/// the driver reads the same clock at send time, so the reported avg latency must reflect
/// the ~5 ms gap — not underflow to 0.
#[test]
fn source_reports_nonzero_send_latency() {
    let ctx = Box::new(TestCtx::default());
    let ctx_ptr = &*ctx as *const TestCtx as *mut c_void;

    let mut cb = empty_callbacks(ctx_ptr);
    cb.send = Some(cb_send); // discard outgoing bytes
    cb.reconfigure = Some(cb_reconfigure);
    cb.start_capture = Some(cb_start_capture);
    cb.on_stats = Some(cb_stats);
    let handle = displaybridge_session_create(DisplayBridgeRole::Source, cb);
    assert!(!handle.is_null());

    // Drive the source to Streaming by feeding a HandshakeReq (source works from idle).
    let cfg = DeviceConfig::new(1280, 720, 60, VideoCodec::Hevc);
    let req = PacketFramer::create_packet(
        PacketType::HandshakeReq,
        1,
        10,
        cfg.to_json().unwrap().as_bytes(),
    );
    unsafe { displaybridge_session_feed_bytes(handle, req.as_ptr(), req.len()) };
    assert!(ctx.start_capture_calls.load(Ordering::SeqCst) >= 1);

    // Stamp capture on the core clock, wait a real 5 ms, then submit.
    let capture_ns = displaybridge_monotonic_ns();
    std::thread::sleep(Duration::from_millis(5));
    let nal = vec![0xDE, 0xAD];
    unsafe { displaybridge_session_submit_frame(handle, nal.as_ptr(), nal.len(), true, capture_ns) };

    // The ~1 s stats tick reports avg latency; it must clearly reflect the 5 ms gap.
    let avg = wait_for(TIMEOUT, || *ctx.last_avg_latency_ms.lock().unwrap())
        .expect("a stats snapshot arrived");
    assert!(avg >= 3.0, "latency should reflect the ~5ms gap, got {avg}ms (0 => the epoch-mismatch bug)");
    assert!(avg < 500.0, "latency sanity upper bound, got {avg}ms");

    unsafe { displaybridge_session_destroy(handle) };
    drop(ctx);
}

// --- small test helpers ---

/// A video frame the test peer sends to the sink.
struct DeviceFrame {
    data: Vec<u8>,
    is_keyframe: bool,
    seq: u64,
    ts: u64,
}

impl DeviceFrame {
    fn key(data: Vec<u8>, seq: u64, ts: u64) -> Self {
        Self {
            data,
            is_keyframe: true,
            seq,
            ts,
        }
    }
    fn delta(data: Vec<u8>, seq: u64, ts: u64) -> Self {
        Self {
            data,
            is_keyframe: false,
            seq,
            ts,
        }
    }
    fn wrapped(&self) -> Vec<u8> {
        let frame = displaybridge_protocol::EncodedFrame {
            data: self.data.clone(),
            is_keyframe: self.is_keyframe,
            sequence_number: self.seq,
            timestamp_micros: self.ts,
        };
        PacketFramer::wrap_video_frame(&frame)
    }
}

/// Polls `f` until it returns `Some` or the deadline elapses.
fn wait_for<T>(timeout: Duration, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    let start = std::time::Instant::now();
    loop {
        if let Some(v) = f() {
            return Some(v);
        }
        if start.elapsed() >= timeout {
            return None;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
