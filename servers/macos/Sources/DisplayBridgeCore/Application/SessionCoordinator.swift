import Foundation
import CoreMedia
import os

private let pipeLog = OSLog(subsystem: "com.displaybridge", category: "pipeline")

/// Simple atomic counter using os_unfair_lock.
private final class AtomicCounter: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _value: UInt64 = 0

    /// Increments and returns the NEW value.
    func add(_ n: UInt64) -> UInt64 {
        os_unfair_lock_lock(&_lock)
        _value += n
        let v = _value
        os_unfair_lock_unlock(&_lock)
        return v
    }
}

/// Lock-free gate that ensures at most 1 frame is in the TCP send pipeline.
/// If a frame is being sent, new frames are dropped (always show latest, never queue).
private final class PipelineGate: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _busy = false
    private var _totalFrames: UInt64 = 0
    private var _droppedFrames: UInt64 = 0

    /// Try to enter the gate. Returns true if acquired (not busy).
    /// If false, caller should DROP the frame.
    func tryEnter() -> Bool {
        os_unfair_lock_lock(&_lock)
        _totalFrames += 1
        guard !_busy else {
            _droppedFrames += 1
            let total = _totalFrames
            let dropped = _droppedFrames
            os_unfair_lock_unlock(&_lock)
            if dropped % 100 == 1 {
                os_signpost(.event, log: pipeLog, name: "frame-dropped", "dropped=%llu total=%llu", dropped, total)
            }
            return false
        }
        _busy = true
        os_unfair_lock_unlock(&_lock)
        return true
    }

    /// Release the gate — called when send completes.
    func leave() {
        os_unfair_lock_lock(&_lock)
        _busy = false
        os_unfair_lock_unlock(&_lock)
    }

    var stats: (total: UInt64, dropped: UInt64) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return (_totalFrames, _droppedFrames)
    }
}

/// Tracks per-frame timing and computes periodic FPS / latency stats.
private final class PipelineMetrics: @unchecked Sendable {
    struct Stats {
        let captureFPS: Double
        let sentFPS: Double
        let droppedPercent: Double
        let avgLatencyMs: Double
        let maxLatencyMs: Double
        let intervalSec: Double
    }

    private var _lock = os_unfair_lock()

    private var _captureCount: UInt64 = 0
    private var _sentCount: UInt64 = 0
    private var _totalLatencyUs: UInt64 = 0
    private var _maxLatencyUs: UInt64 = 0

    private var _lastSnapshotNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var _lastCaptureCount: UInt64 = 0
    private var _lastSentCount: UInt64 = 0
    private var _lastTotalLatencyUs: UInt64 = 0
    private var _lastMaxLatencyUs: UInt64 = 0

    func recordCapture() {
        os_unfair_lock_lock(&_lock)
        _captureCount += 1
        os_unfair_lock_unlock(&_lock)
    }

    func recordSent(latencyUs: UInt64) {
        os_unfair_lock_lock(&_lock)
        _sentCount += 1
        _totalLatencyUs += latencyUs
        if latencyUs > _maxLatencyUs {
            _maxLatencyUs = latencyUs
        }
        os_unfair_lock_unlock(&_lock)
    }

    func snapshot() -> Stats {
        os_unfair_lock_lock(&_lock)
        let now = DispatchTime.now().uptimeNanoseconds
        let deltaNs = now - _lastSnapshotNs
        let deltaCapture = _captureCount - _lastCaptureCount
        let deltaSent = _sentCount - _lastSentCount
        let deltaLatency = _totalLatencyUs - _lastTotalLatencyUs
        let maxLat = _maxLatencyUs

        _lastSnapshotNs = now
        _lastCaptureCount = _captureCount
        _lastSentCount = _sentCount
        _lastTotalLatencyUs = _totalLatencyUs
        _lastMaxLatencyUs = _maxLatencyUs
        _maxLatencyUs = 0
        os_unfair_lock_unlock(&_lock)

        let intervalSec = Double(deltaNs) / 1_000_000_000.0
        guard intervalSec > 0 else {
            return Stats(captureFPS: 0, sentFPS: 0, droppedPercent: 0,
                         avgLatencyMs: 0, maxLatencyMs: 0, intervalSec: 0)
        }

        let capFPS = Double(deltaCapture) / intervalSec
        let sentFPS = Double(deltaSent) / intervalSec
        let dropPct = deltaCapture > deltaSent
            ? Double(deltaCapture &- deltaSent) / Double(deltaCapture) * 100.0
            : 0.0
        let avgMs = deltaSent > 0
            ? Double(deltaLatency) / Double(deltaSent) / 1000.0
            : 0.0
        let maxMs = Double(maxLat) / 1000.0

        return Stats(captureFPS: capFPS, sentFPS: sentFPS,
                     droppedPercent: dropPct, avgLatencyMs: avgMs,
                     maxLatencyMs: maxMs, intervalSec: intervalSec)
    }
}

public struct ClientStats: Sendable {
    public let captureFPS: Double
    public let sentFPS: Double
    public let droppedPercent: Double
    public let avgLatencyMs: Double
    public let maxLatencyMs: Double
}

public actor SessionCoordinator {
    /// Called when the client handshake or config update arrives with its DeviceConfig.
    /// The handler should recreate VDM/encoder/capturer to match the client's resolution.
    public typealias ClientConfigHandler = @Sendable (DeviceConfig) async throws -> Void
    public typealias StatsHandler = @Sendable (ClientStats) -> Void

    private let capturer: any DisplayCapturing
    private let encoder: any VideoEncoding
    private let transport: any DataTransporting
    private let onClientConfig: ClientConfigHandler?
    private let onStatsUpdated: StatsHandler?

    private var session: DisplaySession?
    private var sequenceNumber: UInt64 = 0
    private var inputListenerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastReceivedTime: UInt64 = 0
    private var metrics: PipelineMetrics?

    public init(
        capturer: any DisplayCapturing,
        encoder: any VideoEncoding,
        transport: any DataTransporting,
        onClientConfig: ClientConfigHandler? = nil,
        onStatsUpdated: StatsHandler? = nil
    ) {
        self.capturer = capturer
        self.encoder = encoder
        self.transport = transport
        self.onClientConfig = onClientConfig
        self.onStatsUpdated = onStatsUpdated
    }

    public var currentState: SessionState {
        session?.state ?? .idle
    }

    public func startSession(config: DeviceConfig) async throws {
        var newSession = DisplaySession(config: config)
        newSession.transition(to: .connecting)
        session = newSession

        try await transport.connect()

        session?.transition(to: .negotiating)

        startInputListener()

        print("[SessionCoordinator] Connected. Waiting for client handshake...")
    }

    /// Waits until the session ends (client disconnects or error).
    /// Call after `startSession` to keep the pipeline alive.
    public func waitUntilDone() async {
        await inputListenerTask?.value
    }

    public func stopSession() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        inputListenerTask?.cancel()
        inputListenerTask = nil

        await capturer.stopCapture()
        await encoder.flush()
        await transport.disconnect()

        session?.transition(to: .disconnected)
        session = nil
        sequenceNumber = 0
    }

    private func startInputListener() {
        let stream = transport.receive()
        inputListenerTask = Task { [weak self] in
            do {
                for try await data in stream {
                    guard !Task.isCancelled else { break }
                    await self?.handleReceivedData(data)
                }
            } catch {
                if !Task.isCancelled {
                    print("[SessionCoordinator] Input listener error: \(error)")
                }
            }
        }
    }

    private func handleReceivedData(_ data: Data) async {
        lastReceivedTime = DispatchTime.now().uptimeNanoseconds
        do {
            let (type, _, _, payload) = try PacketFramer.parsePacket(from: data)
            switch type {
            case .handshakeReq:
                try await handleHandshakeReq(payload: payload)
            case .configUpdate:
                try await handleConfigUpdate(payload: payload)
            case .ping:
                let pongPacket = PacketFramer.createPacket(
                    type: .pong,
                    sequenceNumber: nextSequenceNumber(),
                    timestamp: currentTimestampMicros(),
                    payload: payload
                )
                try? await transport.send(pongPacket)
            default:
                print("[SessionCoordinator] Received unhandled packet type: \(type)")
            }
        } catch {
            print("[SessionCoordinator] Error parsing received data: \(error)")
        }
    }

    private func handleHandshakeReq(payload: Data) async throws {
        let clientConfig = try JSONDecoder().decode(DeviceConfig.self, from: payload)
        let stateStr: String = session?.state != nil ? "\(session!.state)" : "nil"
        print("[SessionCoordinator] Received handshake: \(clientConfig.width)x\(clientConfig.height) @ \(clientConfig.refreshRate)Hz (state=\(stateStr))")

        // Ignore duplicate handshakes if already streaming — prevents
        // virtual display recreation failure that kills the pipeline
        if session?.state == .streaming {
            print("[SessionCoordinator] Already streaming, ignoring duplicate handshake")
            return
        }

        // Reconfigure pipeline (VDM + encoder + capturer) to match client resolution
        try await reconfigurePipeline(with: clientConfig)

        // Send HANDSHAKE_ACK with the resolved config
        let ackPayload = try JSONEncoder().encode(clientConfig)
        let ackPacket = PacketFramer.createPacket(
            type: .handshakeAck,
            sequenceNumber: nextSequenceNumber(),
            timestamp: currentTimestampMicros(),
            payload: ackPayload
        )
        try await transport.send(ackPacket)

        session?.transition(to: .streaming)

        // Start the streaming pipeline
        try await startStreamingPipeline(config: clientConfig)

        // Start heartbeat to detect dead clients (e.g. killed through adb reverse proxy)
        startHeartbeat()
    }

    private func handleConfigUpdate(payload: Data) async throws {
        let newConfig = try JSONDecoder().decode(DeviceConfig.self, from: payload)
        print("[SessionCoordinator] CONFIG_UPDATE: \(newConfig.width)x\(newConfig.height) @ \(newConfig.refreshRate)Hz")

        // Stop current capture
        await capturer.stopCapture()

        // Reconfigure pipeline with new dimensions
        try await reconfigurePipeline(with: newConfig)

        // Restart streaming with new config
        try await startStreamingPipeline(config: newConfig)

        print("[SessionCoordinator] Pipeline reconfigured for new orientation.")
    }

    private func reconfigurePipeline(with config: DeviceConfig) async throws {
        if let onClientConfig {
            do {
                try await onClientConfig(config)
                print("[SessionCoordinator] Pipeline reconfigured: \(config.width)x\(config.height)")
            } catch {
                print("[SessionCoordinator] Pipeline reconfiguration failed: \(error)")
            }
        }

        session?.updateConfig(config)
    }

    private func startStreamingPipeline(config: DeviceConfig) async throws {
        let enc = self.encoder
        let trans = self.transport

        let gate = PipelineGate()
        let metrics = PipelineMetrics()
        self.metrics = metrics

        try await capturer.startCapture(config: config) { frame in
            metrics.recordCapture()
            guard gate.tryEnter() else { return }

            do {
                let encoded = try enc.encodeSync(frame)
                let packet = PacketFramer.wrapVideoFrame(encoded)

                trans.sendTracked(packet) {
                    let totalUs = (DispatchTime.now().uptimeNanoseconds - frame.captureTimeNs) / 1000
                    gate.leave()
                    metrics.recordSent(latencyUs: totalUs)
                }
            } catch {
                gate.leave()
                print("[PIPE] Encode error: \(error)")
            }
        }

        print("[SessionCoordinator] Pipeline active with backpressure gate.")
    }

    private func startHeartbeat() {
        lastReceivedTime = DispatchTime.now().uptimeNanoseconds
        let transport = self.transport
        let metrics = self.metrics

        heartbeatTask = Task { [weak self] in
            let pingInterval: UInt64 = 3_000_000_000   // 3 seconds
            let deadTimeout: UInt64 = 10_000_000_000   // 10 seconds no response = dead

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pingInterval)
                guard !Task.isCancelled else { break }

                // Pipeline stats
                if let s = metrics?.snapshot() {
                    print(String(format: "[STATS] capture=%.0ffps sent=%.0ffps | drop=%.0f%% | latency avg=%.1fms max=%.1fms",
                                 s.captureFPS, s.sentFPS, s.droppedPercent, s.avgLatencyMs, s.maxLatencyMs))
                    self?.onStatsUpdated?(ClientStats(
                        captureFPS: s.captureFPS, sentFPS: s.sentFPS,
                        droppedPercent: s.droppedPercent,
                        avgLatencyMs: s.avgLatencyMs, maxLatencyMs: s.maxLatencyMs
                    ))
                }

                // Check if client is alive BEFORE attempting to send PING.
                // This ensures the dead timeout works even if the write queue is
                // blocked by a slow USB video write.
                guard let lastTime = await self?.lastReceivedTime else { break }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastTime > deadTimeout {
                    print("[SessionCoordinator] Client heartbeat timeout — no response for \(deadTimeout / 1_000_000_000)s")
                    break
                }

                // Send PING (best-effort — don't break on failure)
                let seq = await self?.nextSequenceNumber() ?? 0
                let ts = await self?.currentTimestampMicros() ?? 0
                let ping = PacketFramer.createPacket(
                    type: .ping,
                    sequenceNumber: seq,
                    timestamp: ts,
                    payload: Data()
                )
                do {
                    try await transport.send(ping)
                } catch {
                    print("[SessionCoordinator] Heartbeat send failed: \(error)")
                }
            }

            // Client is dead — cancel the input listener to unblock waitUntilDone()
            await self?.inputListenerTask?.cancel()
        }
    }

    private func nextSequenceNumber() -> UInt64 {
        sequenceNumber += 1
        return sequenceNumber
    }

    private func currentTimestampMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
