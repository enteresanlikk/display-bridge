import Foundation
import Network

/// Listens on a TCP port and yields each new client as a `ClientConnection`
/// via an `AsyncStream`. Used by main.swift to orchestrate multiple clients.
public final class ConnectionListener: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let lock = NSLock()

    public init(port: UInt16 = 7878) {
        self.port = port
    }

    /// Callback fired when listener state changes. `true` = ready, `false` = failed/cancelled.
    public var onListenerReady: ((@Sendable (Bool) -> Void))?

    /// Starts listening and returns a stream of accepted client connections.
    /// Each yielded `ClientConnection` is already in `.ready` state.
    public func start() -> AsyncStream<ClientConnection> {
        return AsyncStream { continuation in
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 5
            tcpOptions.keepaliveInterval = 5
            tcpOptions.keepaliveCount = 3
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)

            let queue = DispatchQueue(label: "com.displaybridge.listener", qos: .userInteractive)

            guard let nwListener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.port)!) else {
                print("[ConnectionListener] Failed to create listener on port \(self.port)")
                self.onListenerReady?(false)
                continuation.finish()
                return
            }

            let onReady = self.onListenerReady
            nwListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[ConnectionListener] Listening on port \(self.port)...")
                    onReady?(true)
                case .failed(let error):
                    print("[ConnectionListener] Listener failed: \(error)")
                    onReady?(false)
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { newConnection in
                let clientID = UUID()
                print("[ConnectionListener] New connection from client \(clientID.uuidString.prefix(8))")

                newConnection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let client = ClientConnection(connection: newConnection, clientID: clientID)
                        continuation.yield(client)
                    case .failed(let error):
                        print("[ConnectionListener] Connection \(clientID.uuidString.prefix(8)) failed: \(error)")
                        newConnection.cancel()
                    case .cancelled:
                        print("[ConnectionListener] Connection \(clientID.uuidString.prefix(8)) cancelled")
                    default:
                        break
                    }
                }

                newConnection.start(queue: queue)
            }

            continuation.onTermination = { @Sendable _ in
                nwListener.cancel()
            }

            self.lock.lock()
            self.listener = nwListener
            self.lock.unlock()

            nwListener.start(queue: queue)
        }
    }

    /// Stops the listener and finishes the connection stream.
    public func stop() {
        lock.lock()
        let lstn = listener
        listener = nil
        lock.unlock()

        lstn?.cancel()
    }
}
