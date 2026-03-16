import CoreGraphics
import Foundation

// MARK: - Active Client Tracking

/// Tracks active per-client pipelines for graceful shutdown.
public final class ActiveClients: @unchecked Sendable {
    private var lock = NSLock()
    private var clients: [UUID: ClientEntry] = [:]

    struct ClientEntry {
        let coordinator: SessionCoordinator
        let vdm: VirtualDisplayManager
        var deviceName: String
        var task: Task<Void, Never>?
    }

    public init() {}

    func add(_ id: UUID, coordinator: SessionCoordinator, vdm: VirtualDisplayManager, deviceName: String = "Unknown", task: Task<Void, Never>? = nil) {
        lock.lock()
        clients[id] = ClientEntry(coordinator: coordinator, vdm: vdm, deviceName: deviceName, task: task)
        lock.unlock()
    }

    func setTask(_ id: UUID, task: Task<Void, Never>) {
        lock.lock()
        clients[id]?.task = task
        lock.unlock()
    }

    func updateDeviceName(_ id: UUID, name: String) {
        lock.lock()
        clients[id]?.deviceName = name
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        clients.removeValue(forKey: id)
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    /// Returns a snapshot of connected client info (id, deviceName).
    public var snapshot: [(id: UUID, deviceName: String)] {
        lock.lock()
        defer { lock.unlock() }
        return clients.map { ($0.key, $0.value.deviceName) }
    }

    public func stopAll() async {
        let snap: [UUID: ClientEntry] = lock.withLock {
            let s = clients
            clients.removeAll()
            return s
        }

        for (id, entry) in snap {
            entry.task?.cancel()
            await entry.coordinator.stopSession()
            entry.vdm.destroy()
            print("[Server] Cleaned up client \(id.uuidString.prefix(8))")
        }
    }
}

// MARK: - ServerEngine

/// Reusable server engine that manages the connection listener
/// and per-client pipelines. Used by both CLI and GUI.
public final class ServerEngine: @unchecked Sendable {
    private let activeClients = ActiveClients()
    private var listener: ConnectionListener?
    private var listenTask: Task<Void, Never>?
    private let lock = NSLock()

    public private(set) var isRunning = false
    public private(set) var port: UInt16

    // Callbacks — GUI uses these to update state
    public var onClientConnected: (@Sendable (UUID, String) -> Void)?
    public var onClientDisconnected: (@Sendable (UUID) -> Void)?
    public var onStateChanged: (@Sendable (Bool) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    public init(port: UInt16 = 7878) {
        self.port = port
    }

    public var clientCount: Int {
        activeClients.count
    }

    /// Starts the server: begins TCP listener and accepting clients.
    /// Waits until the TCP listener is actually ready before reporting success.
    public func start(defaultConfig: DeviceConfig) async {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        let connListener = ConnectionListener(port: port)

        // Wait for the NWListener to actually bind and become ready
        let listenerReady: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            connListener.onListenerReady = { ready in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ready)
            }

            lock.lock()
            listener = connListener
            lock.unlock()

            let connectionStream = connListener.start()

            self.listenTask = Task { [weak self] in
                for await clientConn in connectionStream {
                    guard let self = self else { break }
                    let clientID = clientConn.clientID
                    let shortID = clientID.uuidString.prefix(8)
                    print("[Server] TCP client \(shortID) connected. Active clients: \(self.activeClients.count + 1)")

                    let clientTask = Task {
                        await self.handleClient(transport: clientConn, clientID: clientID, defaultConfig: defaultConfig)
                    }
                    self.activeClients.setTask(clientID, task: clientTask)
                }
            }
        }

        if listenerReady {
            onStateChanged?(true)
            print("[ServerEngine] Server started on port \(port) (TCP)")
        } else {
            // Listener failed — clean up
            lock.lock()
            isRunning = false
            listener = nil
            lock.unlock()
            listenTask?.cancel()
            listenTask = nil
            onStateChanged?(false)
            onError?("Port \(port) kullanılamıyor — başka bir process kullanıyor olabilir.")
            print("[ServerEngine] Failed to start on port \(port)")
        }
    }

    // MARK: - Client Handling

    private func handleClient(transport: any DataTransporting, clientID: UUID, defaultConfig: DeviceConfig) async {
        let shortID = clientID.uuidString.prefix(8)

        let vdm = VirtualDisplayManager()
        let capturer = ScreenCapturer(virtualDisplayID: CGMainDisplayID())
        let encoder = VideoToolboxEncoder()
        var pipelineReady = false

        let coordinator = SessionCoordinator(
            capturer: capturer,
            encoder: encoder,
            transport: transport,
            onClientConfig: { [weak self] clientConfig in
                let deviceName = clientConfig.deviceName ?? "DisplayBridge"

                await capturer.stopCapture()

                let newID: CGDirectDisplayID
                if !pipelineReady {
                    do {
                        newID = try vdm.create(config: clientConfig, deviceName: deviceName)
                    } catch {
                        print("[Client \(shortID)] Virtual display creation failed: \(error), using main display")
                        newID = CGMainDisplayID()
                    }
                    print("[Client \(shortID)] Virtual display created: \(deviceName) (ID: \(newID))")
                    pipelineReady = true

                    self?.activeClients.updateDeviceName(clientID, name: deviceName)
                    self?.onClientConnected?(clientID, deviceName)
                } else {
                    newID = try vdm.recreate(config: clientConfig, deviceName: deviceName)
                    print("[Client \(shortID)] Virtual display recreated: \(deviceName) (ID: \(newID))")
                }

                capturer.updateDisplayID(newID)
                try encoder.setup(config: clientConfig)
                // Brief pause for VDM to appear in SCShareableContent
                try await Task.sleep(nanoseconds: 200_000_000)
                // Only cache the display — actual capture starts in startStreamingPipeline
                // with the handler already set (avoids SCStream idle frame issue)
                try await capturer.preStart(config: clientConfig)
            }
        )

        activeClients.add(clientID, coordinator: coordinator, vdm: vdm)

        do {
            try await coordinator.startSession(config: defaultConfig)
            print("[Client \(shortID)] Session started. Streaming...")
            await coordinator.waitUntilDone()
        } catch {
            print("[Client \(shortID)] Session error: \(error)")
        }

        // Client disconnected — cleanup
        await coordinator.stopSession()
        vdm.destroy()
        activeClients.remove(clientID)
        print("[Client \(shortID)] Disconnected. Active clients: \(activeClients.count)")

        onClientDisconnected?(clientID)
    }

    /// Stops the server: cancels the listener and cleans up all clients.
    public func stop() async {
        lock.lock()
        let lstn = listener
        listener = nil
        lock.unlock()

        lstn?.stop()
        listenTask?.cancel()
        listenTask = nil

        // stopAll cancels per-client tasks, stops coordinators, and destroys VDMs
        await activeClients.stopAll()

        lock.lock()
        isRunning = false
        lock.unlock()

        onStateChanged?(false)
    }
}
