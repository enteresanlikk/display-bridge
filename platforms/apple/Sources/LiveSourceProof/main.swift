// In-process, end-to-end proof of the REWIRED live macOS source pipeline
// (`swift run LiveSourceProof`).
//
// It drives the real `SessionCoordinator` (now backed by `RustSession(role: .source)`)
// with fakes — no ScreenCaptureKit, no sockets, no permissions — and a real
// `RustSession(role: .sink)` standing in for the Android client:
//
//   sink.setConfig + notifyConnected
//     → HandshakeReq  ──(loopback transport)──▶  coordinator's source core
//     → reconfigure(config) + startCapture(config)  fire on the native seams
//     → HandshakeAck  ──(loopback transport)──▶  sink → Streaming
//   fake capturer emits one frame → fake encoder → submitFrame
//     → VideoFrame    ──(loopback transport)──▶  sink → decode
//
// Asserts the handshake reconfigured/started capture at the sink's resolution and that
// the sink decoded the exact NAL bytes with the keyframe flag. Exits non-zero on failure.
import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import DisplayBridgeCore

// ---- Tiny test helpers ------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  PASS: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
}

/// Thread-safe one-slot box.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

func waitUntil(timeout: TimeInterval, _ cond: @escaping () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        usleep(2000)
    }
    return cond()
}

// ---- Fakes ------------------------------------------------------------------

/// Loopback transport: forwards the source's framed bytes to the sink core, and injects
/// the sink's framed bytes into the source's receive stream. Opaque bytes both ways —
/// framing lives entirely in the Rust core.
final class LoopbackTransport: DataTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let deliveryQueue = DispatchQueue(label: "proof.loopback.to-sink")

    /// Set by the proof to forward source-sent bytes into the sink core (`sink.feed`).
    var deliverToSink: (@Sendable (Data) -> Void)?

    func connect() async throws {}

    func send(_ data: Data) async throws { deliverToSink?(data) }

    func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void) {
        let deliver = deliverToSink
        // Deliver on a separate queue so the (blocking) source send handler's semaphore is
        // signalled from a different thread — exactly like a real NWConnection/USB write.
        deliveryQueue.async {
            deliver?(data)
            onComplete()
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            self.lock.lock(); self.continuation = cont; self.lock.unlock()
        }
    }

    /// Sink → source: bytes the sink core emitted arrive on the source's receive stream.
    func injectFromSink(_ data: Data) {
        let cont = lock.withLock { continuation }
        cont?.yield(data)
    }

    func disconnect() async {
        let cont = lock.withLock { let c = continuation; continuation = nil; return c }
        cont?.finish()
    }
}

/// Fake screen capturer: records the config it was started with and emits frames on demand.
final class FakeCapturer: DisplayCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (VideoFrame) -> Void)?
    let startedConfig = Box<DeviceConfig?>(nil)
    let capturing = Box<Bool>(false)

    func startCapture(config: DeviceConfig, handler: @escaping @Sendable (VideoFrame) -> Void) async throws {
        lock.withLock { self.handler = handler }
        startedConfig.set(config)
        capturing.set(true)
    }

    func stopCapture() async {
        lock.withLock { handler = nil }
        capturing.set(false)
    }

    /// Push one captured frame through the pipeline.
    func emit(_ frame: VideoFrame) {
        let h = lock.withLock { handler }
        h?(frame)
    }
}

/// Fake encoder: returns a fixed NAL as a keyframe regardless of input.
final class FakeEncoder: VideoEncoding, @unchecked Sendable {
    let nal: Data
    init(nal: Data) { self.nal = nal }
    func setup(config: DeviceConfig) throws {}
    func encodeSync(_ frame: VideoFrame) throws -> EncodedFrame {
        EncodedFrame(timestamp: frame.timestamp, data: nal, isKeyFrame: true, sequenceNumber: 0)
    }
    func encode(_ frame: VideoFrame) async throws -> EncodedFrame { try encodeSync(frame) }
    func flush() async {}
}

func makeDummySurface() -> IOSurface? {
    let props: [IOSurfacePropertyKey: Any] = [
        .width: 16,
        .height: 16,
        .bytesPerElement: 4,
        .bytesPerRow: 64,
        .pixelFormat: kCVPixelFormatType_32BGRA,
    ]
    return IOSurface(properties: props)
}

// ---- Scenario ---------------------------------------------------------------

print("[rewired source: handshake -> reconfigure/startCapture -> frame decoded by sink]")

let expected = DeviceConfig(width: 1280, height: 720, refreshRate: 60, codec: .h264, deviceName: "Proof Sink")
let nal = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0xCA, 0xFE, 0xBA, 0xBE, 0x42])

let transport = LoopbackTransport()
let capturer = FakeCapturer()
let encoder = FakeEncoder(nal: nal)
let reconfigured = Box<DeviceConfig?>(nil)
let receivedInput = Box<InputEvent?>(nil)

// The coordinator under test — the exact production type ServerEngine builds.
let coordinator = SessionCoordinator(
    capturer: capturer,
    encoder: encoder,
    transport: transport,
    onClientConfig: { cfg in reconfigured.set(cfg) },
    onStatsUpdated: nil,
    onInput: { receivedInput.set($0) },
    pairingCode: "482913"
)

// The peer: a real sink core. Its `send` loops back to the source; `decode` records NALs.
let sinkStreaming = DispatchSemaphore(value: 0)
let decoded = Box<(Data, Bool)?>(nil)
let decodeArrived = DispatchSemaphore(value: 0)

let sinkHandlers = RustSessionHandlers(
    send: { data in transport.injectFromSink(data) },
    decode: { nalBytes, isKeyframe, _ in
        decoded.set((nalBytes, isKeyframe))
        decodeArrived.signal()
    },
    onStateChange: { state in if state == .streaming { sinkStreaming.signal() } }
)

guard let sink = RustSession(role: .sink, handlers: sinkHandlers) else {
    print("FAIL: could not create sink RustSession"); exit(2)
}
transport.deliverToSink = { [weak sink] data in sink?.feed(bytes: data) }
_ = sink.setConfig(expected)
sink.setPairingCode("482913")

// Bring up the source coordinator (sets up the receive pump + source notifyConnected).
do {
    try await coordinator.startSession(config: DeviceConfig(width: 1, height: 1, refreshRate: 60, codec: .hevc))
} catch {
    print("FAIL: startSession threw \(error)"); exit(2)
}

// Kick the sink: emits HandshakeReq → source core → reconfigure/startCapture → ack → sink Streaming.
sink.notifyConnected()

if sinkStreaming.wait(timeout: .now() + 3) == .timedOut {
    check(false, "sink reached Streaming (handshake completed)")
    print("\(failures) FAILURES"); exit(1)
}
check(true, "sink reached Streaming (handshake round-trip)")

// The source's StartCapture command runs synchronously as part of processing the handshake;
// wait for the fake capturer to have been started before emitting a frame.
_ = waitUntil(timeout: 3) { capturer.capturing.get() }

check(reconfigured.get().map { $0.width == expected.width && $0.height == expected.height
    && $0.refreshRate == expected.refreshRate && $0.codec == expected.codec } ?? false,
    "reconfigure fired with sink resolution 1280x720@60 h264")
check(capturer.startedConfig.get().map { $0.width == expected.width && $0.height == expected.height
    && $0.refreshRate == expected.refreshRate && $0.codec == expected.codec } ?? false,
    "startCapture fired with sink resolution 1280x720@60 h264")

// Capture one frame → encode → submitFrame → VideoFrame → sink decode.
guard let surface = makeDummySurface() else { print("FAIL: could not create IOSurface"); exit(2) }
let frame = VideoFrame(
    timestamp: CMTime(value: 0, timescale: 1_000_000),
    surface: surface, width: 16, height: 16, captureTimeNs: 42
)
capturer.emit(frame)

if decodeArrived.wait(timeout: .now() + 3) == .timedOut {
    check(false, "sink decoded the streamed frame")
} else if let (gotNal, gotKey) = decoded.get() {
    check(gotNal == nal, "sink decoded the exact NAL bytes")
    check(gotKey == true, "sink saw the keyframe flag")
} else {
    check(false, "sink decode delivered a payload")
}

// Sink → source input: a pointer event must reach the coordinator's onInput intact.
let tap = InputEvent(kind: .down, button: 1, x: 0.25, y: 0.75, pressure: 0.5)
check(sink.sendInput(tap), "streaming sink accepted the pointer event")
_ = waitUntil(timeout: 3) { receivedInput.get() != nil }
check(receivedInput.get() == tap, "source onInput received the exact pointer event")

// Tearing the session down while the capture thread is still pushing frames used to
// free the Rust handle under it (segfault in submit_frame). Keep frames flowing from
// another thread across stopSession and make sure we get to the other side.
let hammering = Box<Bool>(true)
let hammerDone = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    while hammering.get() { capturer.emit(frame) }
    hammerDone.signal()
}
usleep(50_000)
await coordinator.stopSession()
check(!capturer.capturing.get(), "stopSession stopped the capture")
hammering.set(false)
hammerDone.wait()
check(true, "frames submitted during teardown did not crash")

sink.close()
check(!sink.sendInput(tap), "a closed session ignores calls instead of touching a freed handle")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
