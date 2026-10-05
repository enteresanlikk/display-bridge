import CoreVideo
import Foundation

/// Drives the macOS SINK role: turns this Mac into a second monitor that RECEIVES a remote
/// source's encoded screen, decodes it in hardware, and hands decoded `CVPixelBuffer`s to a
/// render surface. It is the sink-role counterpart of `SessionCoordinator`.
///
/// A sink DIALS the source, so this uses the Rust-owned TCP transport (`connectTCP`): the
/// core opens the socket, runs the handshake (advertising the sink's `DeviceConfig`), and
/// pumps received video frames back through the `decode` callback. The macOS side owns only
/// the native seam on the receive path — hardware decode (`VideoToolboxDecoder`) and render.
///
/// Framing, the handshake / ping / pong / disconnect state machine and reassembly all live in
/// Rust; this type just marshals the `decode` callback into the decoder and forwards decoded
/// pixel buffers to `onFrame`.
///
/// `@unchecked Sendable`: mutable state (`session`, `_state`) is guarded by `lock`; the C
/// callbacks travel through the `RustSession` wrapper's context-free closures.
public final class SinkCoordinator: @unchecked Sendable {
    /// Receives each decoded frame (pixel buffer + presentation timestamp in micros).
    public typealias FrameHandler = @Sendable (CVPixelBuffer, UInt64) -> Void
    /// Observes session lifecycle transitions.
    public typealias StateHandler = @Sendable (SessionState) -> Void

    private let decoder: VideoToolboxDecoder
    private let onFrame: FrameHandler
    private let onStateChange: StateHandler?
    private let onError: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var session: RustSession?
    private var _state: SessionState = .idle

    /// - Parameters:
    ///   - decoder: the hardware decoder to feed incoming NALs into. Its frame handler is
    ///     rewired to `onFrame`, so callers can pass a freshly constructed decoder.
    ///   - onFrame: the ultimate consumer of decoded pixel buffers (the render surface).
    ///   - onStateChange: optional lifecycle observer.
    public init(
        decoder: VideoToolboxDecoder,
        onFrame: @escaping FrameHandler,
        onStateChange: StateHandler? = nil,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        self.decoder = decoder
        self.onFrame = onFrame
        self.onStateChange = onStateChange
        self.onError = onError
        // Route the decoder's output to our consumer.
        decoder.setFrameHandler(onFrame)
    }

    public var currentState: SessionState {
        lock.withLock { _state }
    }

    // MARK: - Lifecycle

    /// Creates the sink core, advertises `config`, and dials `host:port`. Returns once the
    /// TCP connection is established and the handshake has begun; decoded frames then arrive
    /// asynchronously on `onFrame`. Throws if the session can't be created or the dial fails.
    /// `pairingCode` is the code shown on the source; required unless it runs unpaired.
    public func start(host: String, port: UInt16, config: DeviceConfig, pairingCode: String? = nil) throws {
        setState(.connecting)

        let decoder = self.decoder
        let onStateChange = self.onStateChange

        let handlers = RustSessionHandlers(
            // The core hands us a decode-ready Annex-B access unit; feed it to the HW decoder.
            decode: { nal, isKeyframe, tsMicros in
                decoder.decode(nal: nal, isKeyframe: isKeyframe, timestampMicros: tsMicros)
            },
            onStateChange: { [weak self] state in
                let mapped = SessionState(rustState: state)
                self?.setState(mapped)
                onStateChange?(mapped)
            },
            onError: onError
        )

        guard let session = RustSession(role: .sink, handlers: handlers) else {
            setState(.disconnected)
            throw SessionError.sessionCreationFailed
        }

        // Advertise the sink's display config in the handshake BEFORE dialing.
        guard session.setConfig(config) else {
            session.close()
            setState(.disconnected)
            throw SessionError.invalidConfig("setConfig failed for \(config.width)x\(config.height)")
        }

        if let pairingCode {
            session.setPairingCode(pairingCode)
        }

        lock.withLock { self.session = session }
        setState(.negotiating)

        // Rust-owned dial: opens the socket, drives Idle → Negotiating, emits HandshakeReq,
        // and starts the reader thread that will fire the `decode` callback per frame.
        guard session.connectTCP(host: host, port: port) else {
            session.close()
            lock.withLock { self.session = nil }
            setState(.disconnected)
            throw SessionError.sessionCreationFailed
        }

        print("[SinkCoordinator] Dialed \(host):\(port), advertising "
            + "\(config.width)x\(config.height)@\(config.refreshRate) \(config.codec).")
    }

    /// Forwards a pointer event to the source so it can be injected into the shared
    /// display. Returns false when not streaming.
    @discardableResult
    public func sendInput(_ event: InputEvent) -> Bool {
        lock.withLock { session }?.sendInput(event) ?? false
    }

    /// Tears down the session (stops the reader thread, disconnects). Idempotent.
    public func stop() {
        let session = lock.withLock { let s = self.session; self.session = nil; return s }
        session?.close()
        decoder.flush()
        setState(.disconnected)
    }

    // MARK: - Internals

    private func setState(_ s: SessionState) {
        lock.withLock { _state = s }
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
