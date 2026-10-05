import Foundation
import Testing
@testable import DisplayBridgeCore

/// End-to-end, in-process proof of the Swift↔Rust FFI boundary.
///
/// No sockets, no capture, no screen permission: we drive the Rust source driver
/// purely through `feed(bytes:)` / `submitFrame(...)` and assert on the packets it
/// emits through the `send` callback and the pipeline hooks it fires.
///
/// Uses swift-testing (`import Testing`) because the active toolchain is the
/// Command Line Tools, which ships swift-testing but not XCTest.

/// Collects the raw framed packets the Rust driver emits via the `send` callback.
/// The callback can fire from the driver's clock thread, so access is locked.
private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func record(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        packets.append(data)
    }

    var all: [Data] {
        lock.lock(); defer { lock.unlock() }
        return packets
    }

    /// The first emitted packet whose header type matches `type`, parsed.
    func firstPacket(ofType type: PacketType) -> (sequenceNumber: UInt64, timestamp: UInt64, payload: Data)? {
        for packet in all {
            if let parsed = try? PacketFramer.parsePacket(from: packet), parsed.type == type {
                return (parsed.sequenceNumber, parsed.timestamp, Data(parsed.payload))
            }
        }
        return nil
    }
}

/// A tiny lock-protected value box for callback results delivered off-thread.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
}

/// Drives a SOURCE session through: HandshakeReq in → (reconfigure + start_capture
/// fire, HandshakeAck out) → submitFrame → VideoFrame out.
@Test
func sourceHandshakeThenFrameRoundTrip() throws {
    let sends = SendRecorder()
    let reconfigured = Box<DeviceConfig?>(nil)
    let started = Box<DeviceConfig?>(nil)
    let reachedStreaming = Box<Bool>(false)

    let handlers = RustSessionHandlers(
        send: { data in sends.record(data) },
        reconfigure: { cfg in reconfigured.set(cfg) },
        startCapture: { cfg in started.set(cfg) },
        onStateChange: { state in
            if state == .streaming { reachedStreaming.set(true) }
        }
    )

    let session = try #require(RustSession(role: .source, handlers: handlers),
                               "failed to create Rust source session")
    defer { session.close() }

    // --- Feed a HandshakeReq (28-byte DBRG header + JSON DeviceConfig payload) ---
    let configJSON = #"{"width":1920,"height":1080,"refreshRate":60,"codec":"hevc"}"#
    let handshake = PacketFramer.createPacket(
        type: .handshakeReq,
        sequenceNumber: 1,
        timestamp: 1_000,
        payload: Data(configJSON.utf8)
    )
    session.feed(bytes: handshake)

    // feed_bytes runs synchronously on this thread, so the source-plane effects
    // (reconfigure, ack, start_capture, streaming) are all visible immediately.

    // reconfigure + start_capture fired with the negotiated 1920x1080@60 HEVC config.
    let expectedConfig = DeviceConfig(width: 1920, height: 1080, refreshRate: 60, codec: .hevc)
    #expect(reconfigured.get == expectedConfig, "reconfigure should fire with the handshake config")
    #expect(started.get == expectedConfig, "start_capture should fire with the handshake config")
    #expect(reachedStreaming.get, "state should transition to .streaming")

    // A HandshakeAck (type 0x02) was emitted via `send`, echoing the config JSON.
    let ack = try #require(sends.firstPacket(ofType: .handshakeAck),
                           "expected a HandshakeAck packet on the send callback")
    let echoed = try JSONDecoder().decode(DeviceConfig.self, from: ack.payload)
    #expect(echoed == expectedConfig, "ack payload should echo the negotiated config")

    // --- Now submit an encoded frame and expect a VideoFrame packet out ---
    let nal = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
    session.submitFrame(nal, isKeyframe: true, captureTimeNs: 12_345)
    // The frame leaves on the core's sender thread, not inside submitFrame.
    let deadline = Date().addingTimeInterval(3)
    while sends.firstPacket(ofType: .videoFrame) == nil && Date() < deadline { usleep(2000) }

    let video = try #require(sends.firstPacket(ofType: .videoFrame),
                             "expected a VideoFrame packet on the send callback")

    // Video payload layout: [0] keyframe flag, [1..3] reserved, [4...] NAL bytes.
    #expect(video.payload.count >= 4 + nal.count)
    let p = video.payload
    #expect(p[p.startIndex] == 1, "keyframe flag should be set")
    let carriedNAL = Data(p[(p.startIndex + 4)...])
    #expect(carriedNAL == nal, "VideoFrame payload should carry the submitted NAL bytes")
}

/// Proves the sink role + config marshalling seam: create a sink, cross the FFI
/// boundary with a marshalled `DeviceConfig` (incl. a non-nil `device_name`), and
/// tear down cleanly (idempotent close).
@Test
func sinkSessionLifecycleAndConfigMarshalling() throws {
    let sends = SendRecorder()
    let session = try #require(
        RustSession(role: .sink, handlers: RustSessionHandlers(send: { sends.record($0) })),
        "failed to create Rust sink session"
    )

    // set_config crosses the FFI boundary with a marshalled DeviceConfig + device_name.
    let ok = session.setConfig(
        DeviceConfig(width: 1280, height: 720, refreshRate: 60, codec: .h264, deviceName: "Test Sink")
    )
    #expect(ok, "setConfig should succeed on a live sink handle")

    session.close()
    // Second close is a no-op (idempotent) and must not crash.
    session.close()
}

/// The bitrate controller backs off when the link is saturated or frames are being
/// skipped, recovers only when the link is clearly idle, and otherwise holds still.
@Test
func bitrateControllerFollowsLinkLoad() {
    #expect(BitrateController.factor(linkBusy: 0.9, droppedPercent: 0) < 1)
    #expect(BitrateController.factor(linkBusy: 0.6, droppedPercent: 30) < 1)
    #expect(BitrateController.factor(linkBusy: 0.2, droppedPercent: 0) > 1)
    #expect(BitrateController.factor(linkBusy: 0.5, droppedPercent: 0) == 1)
    // Skips on an idle link (a burst after a still screen) are not a reason to back off:
    // measured on a phone, that rule drove 80 Mbps down to 19 and kept it there.
    #expect(BitrateController.factor(linkBusy: 0.15, droppedPercent: 5) > 1)
}

/// The frame-size governor: an oversized motion frame raises the quantizer floor in one
/// step by about what it takes to fit, the floor comes back down only slowly, and frames
/// with small changes always keep the sharp floor.
@Test
func frameSizeGovernorReactsPerFrame() {
    var g = FrameSizeGovernor()
    let start = g.motionQP
    #expect(g.floor(changedFraction: 0.02) == FrameSizeGovernor.detailQP)
    #expect(g.floor(changedFraction: 1) == start)

    // 4x over budget: two halvings, six steps each.
    g.observe(changedFraction: 1, frameBytes: 200_000, budgetBytes: 50_000)
    #expect(g.motionQP == min(FrameSizeGovernor.maxQP, start + 12))

    // Within budget: hold.
    let raised = g.motionQP
    g.observe(changedFraction: 1, frameBytes: 50_000, budgetBytes: 50_000)
    #expect(g.motionQP == raised)

    // Under budget: one step down only after a run of such frames.
    for _ in 0..<(FrameSizeGovernor.framesPerStepDown - 1) {
        g.observe(changedFraction: 1, frameBytes: 5_000, budgetBytes: 50_000)
    }
    #expect(g.motionQP == raised)
    g.observe(changedFraction: 1, frameBytes: 5_000, budgetBytes: 50_000)
    #expect(g.motionQP == raised - 1)

    // Small-change frames teach it nothing, whatever their size, and stay sharp.
    g.observe(changedFraction: 0.02, frameBytes: 900_000, budgetBytes: 50_000)
    #expect(g.motionQP == raised - 1)
    #expect(g.floor(changedFraction: 0.02) == FrameSizeGovernor.detailQP)
}

/// Touch gestures, as a sink's screen reports them, become the right pointer events.
@Test
func touchGesturesBecomePointerEvents() {
    let size = CGSize(width: 1000, height: 500)
    func kinds(_ events: [InputEvent]) -> [InputEvent.Kind] { events.map(\.kind) }

    // Tap: nothing is pressed until the finger lifts, then a click where it landed.
    var t = TouchGestureTranslator()
    #expect(kinds(t.handle(.began, points: [CGPoint(x: 250, y: 250)], remaining: 1, in: size)) == [.hover])
    #expect(t.handle(.moved, points: [CGPoint(x: 252, y: 251)], remaining: 1, in: size).isEmpty)
    let tap = t.handle(.ended, points: [CGPoint(x: 252, y: 251)], remaining: 0, in: size)
    #expect(kinds(tap) == [.down, .up])
    #expect(tap[0].x == 0.25 && tap[0].y == 0.5 && tap[0].button == 0)

    // Drag: the press starts where the finger landed, once it has clearly moved.
    t = TouchGestureTranslator()
    _ = t.handle(.began, points: [CGPoint(x: 100, y: 100)], remaining: 1, in: size)
    let start = t.handle(.moved, points: [CGPoint(x: 200, y: 100)], remaining: 1, in: size)
    #expect(kinds(start) == [.down, .move])
    #expect(start[0].x == 0.1 && start[1].x == 0.2)
    #expect(kinds(t.handle(.moved, points: [CGPoint(x: 300, y: 100)], remaining: 1, in: size)) == [.move])
    #expect(kinds(t.handle(.ended, points: [CGPoint(x: 300, y: 100)], remaining: 0, in: size)) == [.up])

    // Two fingers scroll and never click.
    t = TouchGestureTranslator()
    _ = t.handle(.began, points: [CGPoint(x: 400, y: 200)], remaining: 1, in: size)
    #expect(t.handle(.began, points: [CGPoint(x: 600, y: 200), CGPoint(x: 400, y: 200)], remaining: 2, in: size).isEmpty)
    let scroll = t.handle(.moved, points: [CGPoint(x: 600, y: 300), CGPoint(x: 400, y: 300)], remaining: 2, in: size)
    #expect(kinds(scroll) == [.scroll])
    #expect(scroll[0].dy == 0.2 && scroll[0].dx == 0 && scroll[0].x == 0.4)
    #expect(t.handle(.ended, points: [CGPoint(x: 600, y: 300)], remaining: 1, in: size).isEmpty)
    #expect(t.handle(.ended, points: [CGPoint(x: 400, y: 300)], remaining: 0, in: size).isEmpty)

    // Two fingers down and up in place: a secondary click.
    t = TouchGestureTranslator()
    _ = t.handle(.began, points: [CGPoint(x: 400, y: 200)], remaining: 1, in: size)
    _ = t.handle(.began, points: [CGPoint(x: 600, y: 200), CGPoint(x: 400, y: 200)], remaining: 2, in: size)
    let secondary = t.handle(.ended, points: [CGPoint(x: 600, y: 200), CGPoint(x: 400, y: 200)], remaining: 0, in: size)
    #expect(kinds(secondary) == [.down, .up])
    #expect(secondary.allSatisfy { $0.button == 1 })

    // A pen presses at once and carries its pressure.
    t = TouchGestureTranslator()
    let pen = t.handle(.began, points: [CGPoint(x: 500, y: 250)], remaining: 1, in: size, precise: true, pressure: 0.4)
    #expect(kinds(pen) == [.down] && pen[0].pressure == 0.4)
}
