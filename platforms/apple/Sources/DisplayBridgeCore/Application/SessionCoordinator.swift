#if os(macOS)
import Foundation

/// Per-interval pipeline stats surfaced to the GUI/CLI. Mirrors the Rust `ClientStats`
/// the core computes; the coordinator just maps `RustClientStats` into this public shape.
public struct ClientStats: Sendable {
    public let captureFPS: Double
    public let sentFPS: Double
    public let droppedPercent: Double
    public let avgLatencyMs: Double
    public let maxLatencyMs: Double
    /// Average hardware-encode time per frame, in milliseconds.
    public let encodeMs: Double
    /// Average encoded frame size, in kilobytes.
    public let frameKB: Double
    /// Encoded bitrate actually produced over the interval, in megabits per second.
    public let mbps: Double
    /// Share of the interval the transport spent writing, 0...100. Near 100 means the
    /// link, not the encoder, is what limits the frame rate.
    public let linkBusyPercent: Double
}

/// Decides how to move the encoder bitrate from how loaded the link was over the last
/// second. The aim is a link that is busy about half the time: a frame then spends half a
/// frame interval on the wire, and there is room for a burst.
///
/// Skipped frames only count together with a busy link. On their own they are not
/// evidence of a slow link (one large frame after a still screen skips a few), and backing
/// off on them alone ratchets the bitrate down to where it can never recover.
enum BitrateController {
    /// The factor to scale the bitrate by: below 1 to back off, above 1 to recover, 1 to hold.
    static func factor(linkBusy: Double, droppedPercent: Double) -> Double {
        if linkBusy >= 0.7 || (linkBusy >= 0.5 && droppedPercent >= 10) { return 0.8 }
        if linkBusy <= 0.35 { return 1.1 }
        return 1
    }
}

/// Time the transport spent inside writes since the last reading.
private final class LinkLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var busyNs: UInt64 = 0
    private var since = RustSession.monotonicNanoseconds()

    func record(busyNs: UInt64) {
        lock.lock()
        self.busyNs += busyNs
        lock.unlock()
    }

    /// The busy fraction (0...1) since the previous call, and starts a new interval.
    func take() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = RustSession.monotonicNanoseconds()
        let elapsed = now - since
        let busy = busyNs
        busyNs = 0
        since = now
        return elapsed > 0 ? min(1, Double(busy) / Double(elapsed)) : 0
    }
}

/// Per-interval encoder numbers the Rust core can't see (it only receives the bytes).
private final class EncodeTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var encodeNs: UInt64 = 0
    private var bytes = 0

    func record(encodeNs: UInt64, bytes: Int) {
        lock.lock()
        frames += 1
        self.encodeNs += encodeNs
        self.bytes += bytes
        lock.unlock()
    }

    /// Returns the interval's averages and starts a new interval. Stats tick once a second.
    func take() -> (encodeMs: Double, frameKB: Double, mbps: Double) {
        lock.lock()
        defer { frames = 0; encodeNs = 0; bytes = 0; lock.unlock() }
        guard frames > 0 else { return (0, 0, 0) }
        return (
            Double(encodeNs) / Double(frames) / 1_000_000,
            Double(bytes) / Double(frames) / 1000,
            Double(bytes) * 8 / 1_000_000
        )
    }
}

/// Bridges an `async` body into a synchronous C callback context.
///
/// The Rust driver invokes `reconfigure` / `start_capture` / `stop_capture` synchronously
/// and treats the return as completion, but the native pipeline work (`onClientConfig`,
/// `capturer.startCapture/stopCapture`) is `async`. We run it on a `Task` and block the
/// calling thread on a semaphore until it finishes.
///
/// SAFETY: the caller MUST invoke this only from a dedicated thread (the coordinator's
/// `feedQueue` or `closeQueue`), never from a Swift cooperative-pool thread — otherwise
/// blocking here while the `Task` needs a pool thread could starve the pool.
///
/// The wait is bounded. ScreenCaptureKit calls occasionally never return; an unbounded
/// wait here would hold the Rust core inside `feed` forever, and with it `stopSession`,
/// which waits for calls in flight before freeing the session.
private func blockingAwait(_ what: String, _ body: @escaping @Sendable () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await body()
        sem.signal()
    }
    if sem.wait(timeout: .now() + 15) == .timedOut {
        print("[SessionCoordinator] \(what) did not finish within 15s; continuing without it")
    }
}

/// Holds the `RustSession` so the (context-free) C handler closures can reach it for
/// `submitFrame`/`close` without a capture cycle through the coordinator.
private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RustSession?
    func set(_ s: RustSession?) { lock.lock(); value = s; lock.unlock() }
    func get() -> RustSession? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Drives one client session by delegating protocol/pacing to the Rust core via
/// `RustSession(role: .source)`. The macOS side now owns only the native seams:
/// virtual display + screen capture + hardware encode (via `onClientConfig`, `capturer`,
/// `encoder`) and byte-level transport I/O (`transport`). Framing, the handshake/ping/
/// pong/disconnect state machine, frame pacing, metrics and heartbeat all live in Rust.
///
/// Public API is intentionally identical to the pre-FFI coordinator so `ServerEngine`,
/// the CLI and the app compile unchanged.
public final class SessionCoordinator: @unchecked Sendable {
    /// Called when the client handshake or config update arrives with its DeviceConfig.
    /// The handler recreates VDM/encoder/capturer to match the client's resolution.
    public typealias ClientConfigHandler = @Sendable (DeviceConfig) async throws -> Void
    public typealias StatsHandler = @Sendable (ClientStats) -> Void
    /// Called for each pointer event the client sends back (touch, pen, mouse).
    public typealias InputHandler = @Sendable (InputEvent) -> Void

    private let capturer: any DisplayCapturing
    private let encoder: any VideoEncoding
    private let transport: any DataTransporting
    private let onClientConfig: ClientConfigHandler?
    private let onStatsUpdated: StatsHandler?
    private let onInput: InputHandler?
    private let pairingCode: String?

    /// The Rust core, shared with the C handler closures via `sessionBox`.
    private let sessionBox = SessionBox()

    // Dedicated serial queues so the synchronous C callbacks can block safely (off the
    // Swift cooperative pool). `feedQueue` runs `feed` + the handshake-path callbacks;
    // `closeQueue` runs `close()` so its `stop_capture` callback can block too.
    private let feedQueue: DispatchQueue
    private let closeQueue: DispatchQueue

    private let lock = NSLock()
    private var _state: SessionState = .idle
    private var receiveTask: Task<Void, Never>?
    private var stopRequested = false
    private var disconnectRequested = false

    public init(
        capturer: any DisplayCapturing,
        encoder: any VideoEncoding,
        transport: any DataTransporting,
        onClientConfig: ClientConfigHandler? = nil,
        onStatsUpdated: StatsHandler? = nil,
        onInput: InputHandler? = nil,
        pairingCode: String? = nil
    ) {
        self.capturer = capturer
        self.encoder = encoder
        self.transport = transport
        self.onClientConfig = onClientConfig
        self.onStatsUpdated = onStatsUpdated
        self.onInput = onInput
        self.pairingCode = pairingCode
        let suffix = UUID().uuidString.prefix(8)
        self.feedQueue = DispatchQueue(label: "com.displaybridge.session.feed.\(suffix)")
        self.closeQueue = DispatchQueue(label: "com.displaybridge.session.close.\(suffix)")
    }

    public var currentState: SessionState {
        lock.withLock { _state }
    }

    private func setState(_ s: SessionState) {
        lock.withLock { _state = s }
    }

    // MARK: - Lifecycle

    public func startSession(config: DeviceConfig) async throws {
        setState(.connecting)

        try await transport.connect()

        // Build the C handler vtable. These closures run on Rust threads / the coordinator's
        // dedicated queues; they capture the native seams directly (never `self` strongly,
        // except a weak ref for state observation) to avoid a retain cycle through the core.
        let capturer = self.capturer
        let encoder = self.encoder
        let transport = self.transport
        let onClientConfig = self.onClientConfig
        let onStatsUpdated = self.onStatsUpdated
        let onInput = self.onInput
        let box = self.sessionBox
        let timing = EncodeTiming()
        let link = LinkLoad()

        let handlers = RustSessionHandlers(
            // Blocking write: return only once the transport has accepted the bytes. This
            // is the backpressure signal the Rust source send-chain paces against.
            send: { data in
                let started = RustSession.monotonicNanoseconds()
                let sem = DispatchSemaphore(value: 0)
                transport.sendTracked(data) { sem.signal() }
                sem.wait()
                link.record(busyNs: RustSession.monotonicNanoseconds() - started)
            },
            // Rebuild the capture/encode pipeline for the client's config, synchronously.
            reconfigure: { config in
                blockingAwait("Pipeline reconfiguration") {
                    guard let onClientConfig else { return }
                    do {
                        try await onClientConfig(config)
                        print("[SessionCoordinator] Pipeline reconfigured: \(config.width)x\(config.height)")
                    } catch {
                        print("[SessionCoordinator] Pipeline reconfiguration failed: \(error)")
                    }
                }
            },
            // Start real capture; each captured frame is HW-encoded and handed to the core,
            // which frames + paces + sends it (pacing now lives entirely in Rust).
            startCapture: { config in
                blockingAwait("Capture start") {
                    do {
                        try await capturer.startCapture(config: config) { frame in
                            // Skip, before encoding, any frame the wire isn't ready for.
                            guard let session = box.get(), session.wantsFrame() else { return }
                            // Stamp capture time on the CORE's monotonic clock (not the
                            // capturer's DispatchTime uptime) so the driver's send-latency
                            // shares one epoch with it — otherwise latency underflows to 0.
                            let captureNs = RustSession.monotonicNanoseconds()
                            do {
                                let enc = try encoder.encodeSync(frame)
                                timing.record(
                                    encodeNs: RustSession.monotonicNanoseconds() - captureNs,
                                    bytes: enc.data.count
                                )
                                session.submitFrame(
                                    enc.data,
                                    isKeyframe: enc.isKeyFrame,
                                    captureTimeNs: captureNs
                                )
                            } catch {
                                print("[PIPE] Encode error: \(error)")
                            }
                        }
                        print("[SessionCoordinator] Capture started: \(config.width)x\(config.height)")
                    } catch {
                        print("[SessionCoordinator] startCapture failed: \(error)")
                    }
                }
            },
            stopCapture: {
                blockingAwait("Capture stop") { await capturer.stopCapture() }
            },
            onStateChange: { [weak self] state in
                self?.handleStateChange(state, transport: transport)
            },
            onStats: { stats in
                let enc = timing.take()
                let busy = link.take()
                let factor = BitrateController.factor(linkBusy: busy, droppedPercent: stats.droppedPercent)
                if factor != 1, stats.captureFps > 0 {
                    let bps = encoder.scaleBitrate(by: factor)
                    if bps > 0 {
                        print(String(
                            format: "[SessionCoordinator] Link %.0f%% busy, %.0f%% of frames skipped: bitrate -> %.0f Mbps",
                            busy * 100, stats.droppedPercent, Double(bps) / 1_000_000
                        ))
                    }
                }
                onStatsUpdated?(ClientStats(
                    captureFPS: stats.captureFps,
                    sentFPS: stats.sentFps,
                    droppedPercent: stats.droppedPercent,
                    avgLatencyMs: stats.avgLatencyMs,
                    maxLatencyMs: stats.maxLatencyMs,
                    encodeMs: enc.encodeMs,
                    frameKB: enc.frameKB,
                    mbps: enc.mbps,
                    linkBusyPercent: busy * 100
                ))
            },
            onInput: onInput
        )

        guard let session = RustSession(role: .source, handlers: handlers) else {
            throw SessionError.sessionCreationFailed
        }
        // Must be in place before any handshake bytes are fed.
        if let pairingCode {
            session.setPairingCode(pairingCode)
        }
        box.set(session)

        setState(.negotiating)

        // Announce the native transport is up: drives the machine Idle → Negotiating so it
        // will accept the client's HandshakeReq. Must precede any fed bytes.
        session.notifyConnected()

        // Pump received bytes into the core. No Swift-side packet parsing anymore — the core
        // reframes and runs the whole protocol. Each `feed` hops onto `feedQueue` so the
        // synchronous C callbacks it fires can block without starving the cooperative pool.
        let stream = transport.receive()
        let feedQueue = self.feedQueue
        let task = Task {
            do {
                for try await data in stream {
                    if Task.isCancelled { break }
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        feedQueue.async {
                            session.feed(bytes: data)
                            cont.resume()
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("[SessionCoordinator] Receive loop error: \(error)")
                }
            }
        }
        lock.withLock { receiveTask = task }

        print("[SessionCoordinator] Connected. Waiting for client handshake...")
    }

    /// Waits until the session ends (client disconnects, transport closes, or `stopSession`).
    public func waitUntilDone() async {
        let task = lock.withLock { receiveTask }
        await task?.value
    }

    public func stopSession() async {
        let shouldStop: Bool = lock.withLock {
            if stopRequested { return false }
            stopRequested = true
            return true
        }
        guard shouldStop else { return }

        let task = lock.withLock { receiveTask }

        // Close the core first: it sends the explicit Disconnect packet (critical for USB
        // AOA, where the client can't otherwise detect disconnect) and stops capture via
        // the `stop_capture` callback — all synchronous, so run on `closeQueue` where the
        // callback may safely block.
        if let session = sessionBox.get() {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                closeQueue.async {
                    session.close()
                    cont.resume()
                }
            }
            sessionBox.set(nil)
        }

        // Now tear down the native transport, which ends the receive stream.
        await transport.disconnect()

        task?.cancel()
        await task?.value

        setState(.disconnected)
        lock.withLock { receiveTask = nil }
    }

    // MARK: - Core observers

    private func handleStateChange(_ state: RustSessionState, transport: any DataTransporting) {
        setState(SessionState(rustState: state))
        guard state == .disconnected else { return }

        // The core reports the session ended (peer Disconnect, heartbeat timeout, or our own
        // close). Tear down the native transport once so the receive stream finishes and
        // `waitUntilDone` returns. `transport.disconnect()` is idempotent.
        let shouldDisconnect: Bool = lock.withLock {
            if disconnectRequested { return false }
            disconnectRequested = true
            return true
        }
        guard shouldDisconnect else { return }
        Task { await transport.disconnect() }
    }
}

private extension SessionState {
    init(rustState: RustSessionState) {
        switch rustState {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .negotiating: self = .negotiating
        case .streaming: self = .streaming
        case .disconnected: self = .disconnected
        }
    }
}
#endif
