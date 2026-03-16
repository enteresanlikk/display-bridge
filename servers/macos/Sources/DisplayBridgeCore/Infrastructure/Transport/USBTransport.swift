import Foundation
import Network
import os

private let transportLog = OSLog(subsystem: "com.displaybridge", category: "transport")

public enum USBTransportError: Error, Sendable {
    case connectionFailed(String)
    case sendFailed(String)
    case notConnected
    case alreadyListening
    case listenerFailed(String)
}

/// Buffer accumulator for TCP framing – collects raw chunks until a complete packet is available.
private final class ReceiveBuffer {
    var data = Data()
}

/// TCP listener-based transport for the server side.
/// Listens on a port and accepts a single client connection.
/// The client (Android/iOS) connects via adb reverse / iproxy.
public final class USBTransport: @unchecked Sendable, DataTransporting {
    private let host: String
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.displaybridge.usbtransport", qos: .userInteractive)
    private let lock = NSLock()

    private var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    public init(host: String = "127.0.0.1", port: UInt16 = 7878) {
        self.host = host
        self.port = port
    }

    /// Starts listening and waits for a client to connect.
    public func connect() async throws {
        if lock.withLock({ listener != nil }) {
            throw USBTransportError.alreadyListening
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm for low latency
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw USBTransportError.listenerFailed(error.localizedDescription)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[USBTransport] Listening on port \(self.port)...")
                case .failed(let error):
                    resumeOnce(.failure(USBTransportError.listenerFailed(error.localizedDescription)))
                case .cancelled:
                    resumeOnce(.failure(USBTransportError.listenerFailed("Listener cancelled")))
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }
                print("[USBTransport] Client connected!")

                newConnection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.lock.lock()
                        self.connection = newConnection
                        self.lock.unlock()
                        resumeOnce(.success(()))
                    case .failed(let error):
                        resumeOnce(.failure(USBTransportError.connectionFailed(error.localizedDescription)))
                    default:
                        break
                    }
                }

                newConnection.start(queue: self.queue)
            }

            self.lock.lock()
            self.listener = nwListener
            self.lock.unlock()

            nwListener.start(queue: self.queue)
        }
    }

    public func send(_ data: Data) async throws {
        guard let connection = lock.withLock({ connection }) else {
            throw USBTransportError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: USBTransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func sendNonBlocking(_ data: Data) {
        lock.lock()
        guard let connection = connection else {
            lock.unlock()
            return
        }
        lock.unlock()

        connection.send(content: data, completion: .idempotent)
    }

    public func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void) {
        lock.lock()
        guard let connection = connection else {
            lock.unlock()
            onComplete()
            return
        }
        lock.unlock()

        connection.send(content: data, completion: .contentProcessed { _ in
            onComplete()
        })
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.receiveContinuation = continuation
            guard let connection = self.connection else {
                self.lock.unlock()
                continuation.finish(throwing: USBTransportError.notConnected)
                return
            }
            self.lock.unlock()

            continuation.onTermination = { @Sendable _ in }

            let buffer = ReceiveBuffer()
            self.receiveLoop(connection: connection, continuation: continuation, buffer: buffer)
        }
    }

    private func receiveLoop(
        connection: NWConnection,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        buffer: ReceiveBuffer
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let error = error {
                continuation.finish(throwing: error)
                return
            }

            if let data = content, !data.isEmpty {
                buffer.data.append(data)
            }

            // Extract complete packets from the buffer
            while buffer.data.count >= PacketFramer.headerSize {
                // Read payload length from header bytes [24..27]
                let lenStart = buffer.data.startIndex + 24
                let lenEnd = lenStart + 4
                let payloadLength = Int(
                    buffer.data[lenStart..<lenEnd]
                        .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                        .littleEndian
                )

                let totalPacketSize = PacketFramer.headerSize + payloadLength
                guard buffer.data.count >= totalPacketSize else {
                    break // Wait for more data
                }

                // Extract complete packet and yield it
                let packet = Data(buffer.data.prefix(totalPacketSize))
                buffer.data.removeFirst(totalPacketSize)
                continuation.yield(packet)
            }

            if isComplete {
                continuation.finish()
                return
            }

            self?.receiveLoop(connection: connection, continuation: continuation, buffer: buffer)
        }
    }

    public func disconnect() async {
        let (conn, lstn) = lock.withLock {
            let c = connection
            let l = listener
            connection = nil
            listener = nil
            receiveContinuation?.finish()
            receiveContinuation = nil
            return (c, l)
        }

        conn?.cancel()
        lstn?.cancel()
    }

    deinit {
        connection?.cancel()
        listener?.cancel()
    }
}
