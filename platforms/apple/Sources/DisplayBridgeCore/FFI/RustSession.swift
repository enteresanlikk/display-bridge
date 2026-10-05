import CDisplayBridgeFFI
import Foundation

/// The role a `RustSession` plays, mirroring `DisplayBridgeRole` in the C ABI.
public enum RustSessionRole: Sendable {
    /// Owns and captures a display; encodes and sends frames. (server)
    case source
    /// Receives frames, decodes and renders them. (client)
    case sink
}

/// Observable session lifecycle state, mirroring `DisplayBridgeSessionState`.
public enum RustSessionState: UInt32, Sendable {
    case idle = 0
    case connecting = 1
    case negotiating = 2
    case streaming = 3
    case disconnected = 4

    init(cRawState: UInt32) {
        self = RustSessionState(rawValue: cRawState) ?? .idle
    }
}

/// Per-interval pipeline stats, mirroring `DisplayBridgeClientStats`.
public struct RustClientStats: Sendable, Equatable {
    public let captureFps: Double
    public let sentFps: Double
    public let droppedPercent: Double
    public let avgLatencyMs: Double
    public let maxLatencyMs: Double

    init(cValue: DisplayBridgeClientStats) {
        self.captureFps = cValue.capture_fps
        self.sentFps = cValue.sent_fps
        self.droppedPercent = cValue.dropped_percent
        self.avgLatencyMs = cValue.avg_latency_ms
        self.maxLatencyMs = cValue.max_latency_ms
    }
}

/// The Swift-typed callback handlers a `RustSession` bridges the C vtable to.
///
/// Every handler is optional; a nil handler maps to a null C function pointer,
/// which the Rust driver null-checks. The driver may invoke these from its
/// internal reader / clock threads, so handlers must be thread-safe.
public struct RustSessionHandlers: Sendable {
    /// Write already-framed bytes to a native-owned transport (source/sink control + video).
    public var send: (@Sendable (Data) -> Void)?
    /// Source hook: (re)build the capture/encode pipeline for the config.
    public var reconfigure: (@Sendable (DeviceConfig) -> Void)?
    /// Source hook: start capturing/encoding for the config.
    public var startCapture: (@Sendable (DeviceConfig) -> Void)?
    /// Source hook: stop the current capture.
    public var stopCapture: (@Sendable () -> Void)?
    /// Sink hook: deliver a decode-ready NAL unit.
    public var decode: (@Sendable (_ nal: Data, _ isKeyframe: Bool, _ timestampMicros: UInt64) -> Void)?
    /// Observe session state transitions.
    public var onStateChange: (@Sendable (RustSessionState) -> Void)?
    /// Receive periodic pipeline stats (source only).
    public var onStats: (@Sendable (RustClientStats) -> Void)?
    /// Source hook: a pointer event arrived from the sink.
    public var onInput: (@Sendable (InputEvent) -> Void)?
    /// The peer refused the session (e.g. a wrong pairing code); the message is for the user.
    public var onError: (@Sendable (String) -> Void)?

    public init(
        send: (@Sendable (Data) -> Void)? = nil,
        reconfigure: (@Sendable (DeviceConfig) -> Void)? = nil,
        startCapture: (@Sendable (DeviceConfig) -> Void)? = nil,
        stopCapture: (@Sendable () -> Void)? = nil,
        decode: (@Sendable (_ nal: Data, _ isKeyframe: Bool, _ timestampMicros: UInt64) -> Void)? = nil,
        onStateChange: (@Sendable (RustSessionState) -> Void)? = nil,
        onStats: (@Sendable (RustClientStats) -> Void)? = nil,
        onInput: (@Sendable (InputEvent) -> Void)? = nil,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        self.send = send
        self.reconfigure = reconfigure
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.decode = decode
        self.onStateChange = onStateChange
        self.onStats = onStats
        self.onInput = onInput
        self.onError = onError
    }
}

/// A thin, safe Swift wrapper around a `DisplayBridgeSession*` from the Rust core.
///
/// The wrapper hands the C ABI an opaque `ctx` pointing at itself (retained for the
/// driver's lifetime) and a vtable of context-free C closures that recover `self`
/// from `ctx` and dispatch to the Swift `RustSessionHandlers`. This is the seam the
/// live `SessionCoordinator` / `ServerEngine` will adopt.
///
/// `@unchecked Sendable`: the Rust driver behind `handle` is internally synchronized (its
/// mutexes guard the state machine, transport, and pacing), and every call into it goes
/// through `whileOpen`, so `close()` — which frees the handle — waits for calls already in
/// flight and turns later ones into no-ops. That matters because callers race it for real:
/// the capture thread submits frames while a disconnect tears the session down.
public final class RustSession: @unchecked Sendable {
    /// The opaque `DisplayBridgeSession*` handle.
    private var handle: OpaquePointer!
    /// The retained-self pointer handed to the C ABI as `ctx`; released on `close()`.
    private var ctx: UnsafeMutableRawPointer!
    /// The Swift handlers the C callbacks dispatch to.
    fileprivate let handlers: RustSessionHandlers

    /// Guards `closed` / `inFlight`; signalled whenever an in-flight call returns.
    private let state = NSCondition()
    private var closed = false
    private var inFlight = 0

    /// Runs `body` (a call into the C ABI) unless the session is closed, and keeps
    /// `close()` from freeing the handle until `body` returns.
    private func whileOpen<R>(else fallback: R, _ body: () -> R) -> R {
        state.lock()
        if closed {
            state.unlock()
            return fallback
        }
        inFlight += 1
        state.unlock()
        defer {
            state.lock()
            inFlight -= 1
            state.broadcast()
            state.unlock()
        }
        return body()
    }

    /// Creates a session for `role`, wiring `handlers` into the C callback vtable.
    /// Returns nil if the Rust driver fails to create the session.
    public init?(role: RustSessionRole, handlers: RustSessionHandlers) {
        self.handlers = handlers
        self.handle = nil
        self.ctx = nil

        // All stored properties are initialized → `self` is now usable. Retain a
        // reference for the C side; it is released in `close()`.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        self.ctx = ctx

        let cRole = (role == .source) ? DisplayBridgeRole_Source : DisplayBridgeRole_Sink

        var cb = DisplayBridgeCallbacks()
        cb.ctx = ctx

        // Each closure captures nothing (state travels through `ctx`), so it converts
        // to a `@convention(c)` function pointer. `self` is recovered unretained.
        cb.send = { ctxPtr, data, len in
            guard let ctxPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            let bytes: Data
            if let data, len > 0 {
                bytes = Data(bytes: data, count: Int(len))
            } else {
                bytes = Data()
            }
            session.handlers.send?(bytes)
        }

        cb.reconfigure = { ctxPtr, cfgPtr in
            guard let ctxPtr, let cfgPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.reconfigure?(DeviceConfig(cValue: cfgPtr.pointee))
        }

        cb.start_capture = { ctxPtr, cfgPtr in
            guard let ctxPtr, let cfgPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.startCapture?(DeviceConfig(cValue: cfgPtr.pointee))
        }

        cb.stop_capture = { ctxPtr in
            guard let ctxPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.stopCapture?()
        }

        cb.decode = { ctxPtr, nal, len, isKeyframe, tsMicros in
            guard let ctxPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            let bytes: Data
            if let nal, len > 0 {
                bytes = Data(bytes: nal, count: Int(len))
            } else {
                bytes = Data()
            }
            session.handlers.decode?(bytes, isKeyframe, tsMicros)
        }

        cb.on_state_change = { ctxPtr, state in
            guard let ctxPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.onStateChange?(RustSessionState(cRawState: state))
        }

        cb.on_stats = { ctxPtr, stats in
            guard let ctxPtr else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.onStats?(RustClientStats(cValue: stats))
        }

        cb.on_input = { ctxPtr, event in
            guard let ctxPtr, let kind = InputEvent.Kind(rawValue: event.kind) else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.onInput?(InputEvent(
                kind: kind, button: event.button,
                x: event.x, y: event.y, dx: event.dx, dy: event.dy, pressure: event.pressure
            ))
        }

        cb.on_error = { ctxPtr, message in
            guard let ctxPtr, let message else { return }
            let session = Unmanaged<RustSession>.fromOpaque(ctxPtr).takeUnretainedValue()
            session.handlers.onError?(String(cString: message))
        }

        guard let created = displaybridge_session_create(cRole.rawValue, cb) else {
            // Creation failed: undo the retain so `self` can deallocate.
            Unmanaged<RustSession>.fromOpaque(ctx).release()
            return nil
        }
        self.handle = created
    }

    deinit {
        // The retained `ctx` keeps `self` alive until `close()` releases it, so by the
        // time `deinit` runs `close()` has normally already destroyed the handle. Guard
        // for the pathological case where the retain was somehow already dropped.
        state.lock()
        let alreadyClosed = closed
        state.unlock()
        if !alreadyClosed, let handle {
            displaybridge_session_destroy(handle)
        }
    }

    /// Destroys the underlying session (says goodbye to the peer, stops capture and
    /// threads, disconnects) and releases the retained self-reference. Idempotent, and
    /// safe to race with any other method. Must not be called from inside one of the
    /// session's own handlers.
    public func close() {
        state.lock()
        if closed {
            state.unlock()
            return
        }
        closed = true
        while inFlight > 0 {
            state.wait()
        }
        let ctx = self.ctx
        let handle = self.handle
        state.unlock()

        // Destroy first: this joins the driver's threads, after which no further
        // callback can fire, so releasing the retained self afterwards is safe.
        if let handle {
            displaybridge_session_destroy(handle)
        }
        if let ctx {
            Unmanaged<RustSession>.fromOpaque(ctx).release()
        }
    }

    // MARK: - Configuration

    /// Sets the display config a sink advertises in its handshake. Call before
    /// `connectTCP` on a sink; ignored by a source. Returns false on failure.
    @discardableResult
    public func setConfig(_ config: DeviceConfig) -> Bool {
        whileOpen(else: false) {
            withDeviceName(config.deviceName) { namePtr in
                var c = config.cValue(deviceName: namePtr)
                return displaybridge_session_set_config(handle, &c)
            }
        }
    }

    /// Source: require this code from every sink. Sink: present it in the handshake.
    /// Call before connecting. Returns false for an empty code.
    @discardableResult
    public func setPairingCode(_ code: String) -> Bool {
        whileOpen(else: false) {
            code.withCString { displaybridge_session_set_pairing_code(handle, $0) }
        }
    }

    // MARK: - Transport

    /// Builds a Rust-owned TCP transport, dials `host:port`, and starts the session.
    /// Returns false on any connection failure.
    @discardableResult
    public func connectTCP(host: String, port: UInt16) -> Bool {
        whileOpen(else: false) {
            host.withCString { hostPtr in
                displaybridge_session_connect_tcp(handle, hostPtr, port)
            }
        }
    }

    /// Signals that a native-owned transport has connected, driving the machine to
    /// `Negotiating` (and, for a sink, emitting the opening `HandshakeReq` — set its
    /// config first). Call exactly once, after the native transport is ready and before
    /// feeding bytes. Do NOT call when using the built-in Rust transport (`connectTCP`).
    public func notifyConnected() {
        whileOpen(else: ()) { displaybridge_session_notify_connected(handle) }
    }

    /// Feeds bytes received on a native-owned transport into the driver.
    public func feed(bytes: Data) {
        guard !bytes.isEmpty else { return }
        whileOpen(else: ()) {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                displaybridge_session_feed_bytes(handle, base, UInt(raw.count))
            }
        }
    }

    // MARK: - Sink input plane

    /// Forwards a pointer event to the source. Returns false unless this is a streaming sink.
    @discardableResult
    public func sendInput(_ event: InputEvent) -> Bool {
        whileOpen(else: false) {
            displaybridge_session_send_input(handle, DisplayBridgeInputEvent(
                kind: event.kind.rawValue, button: event.button,
                x: event.x, y: event.y, dx: event.dx, dy: event.dy, pressure: event.pressure
            ))
        }
    }

    // MARK: - Source data plane

    /// Whether the frame just captured should be encoded. False while not streaming or
    /// while the previous frame is still waiting for the wire; skip the frame then, before
    /// spending an encode on it (and before it can break the encoder's reference chain).
    public func wantsFrame() -> Bool {
        whileOpen(else: false) { displaybridge_session_wants_frame(handle) }
    }

    /// Hands an already hardware-encoded frame to the driver, which sends it from its own
    /// thread. Does not block on the write.
    public func submitFrame(_ data: Data, isKeyframe: Bool, captureTimeNs: UInt64) {
        guard !data.isEmpty else { return }
        whileOpen(else: ()) {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                displaybridge_session_submit_frame(handle, base, UInt(raw.count), isKeyframe, captureTimeNs)
            }
        }
    }

    /// The core's process-global monotonic clock, in nanoseconds. Stamp a frame's
    /// capture time with this and pass it to `submitFrame(captureTimeNs:)` so the
    /// driver's send-latency shares one epoch with the capture timestamp. Do NOT mix
    /// with `DispatchTime`/mach uptime — that underflows to zero latency.
    public static func monotonicNanoseconds() -> UInt64 {
        displaybridge_monotonic_ns()
    }
}

// MARK: - DeviceConfig <-> C bridging

extension DeviceConfig {
    /// Builds the value from the C struct, copying `device_name` into a Swift String.
    /// `cValue.codec`'s type is the (ambiguous) cbindgen enum, so we compare it to the
    /// imported constants rather than naming the type.
    init(cValue: DisplayBridgeDeviceConfig) {
        let name: String?
        if let namePtr = cValue.device_name {
            name = String(cString: namePtr)
        } else {
            name = nil
        }
        // H264 maps to .h264; Hevc and the reserved Av1 both map to .hevc.
        let codec: VideoCodec = (cValue.codec == DisplayBridgeVideoCodec_H264.rawValue) ? .h264 : .hevc
        self.init(
            width: Int(cValue.width),
            height: Int(cValue.height),
            refreshRate: Int(cValue.refresh_rate),
            codec: codec,
            deviceName: name
        )
    }

    /// Builds the C struct. `deviceName` must point at a C string that outlives the
    /// call (see `withDeviceName`).
    func cValue(deviceName: UnsafePointer<CChar>?) -> DisplayBridgeDeviceConfig {
        let cCodec = (codec == .hevc) ? DisplayBridgeVideoCodec_Hevc : DisplayBridgeVideoCodec_H264
        return DisplayBridgeDeviceConfig(
            width: Int32(width),
            height: Int32(height),
            refresh_rate: Int32(refreshRate),
            codec: cCodec.rawValue,
            device_name: deviceName
        )
    }
}

/// Runs `body` with a C string for `name` (or nil), valid only for the call's duration.
private func withDeviceName<R>(_ name: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let name else { return body(nil) }
    return name.withCString { body($0) }
}
