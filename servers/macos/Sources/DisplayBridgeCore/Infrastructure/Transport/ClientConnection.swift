import Foundation
import Network
import os

private let connLog = OSLog(subsystem: "com.displaybridge", category: "client-conn")

/// Buffer accumulator for TCP framing – collects raw chunks until a complete packet is available.
private final class ReceiveBuffer {
    var data = Data()
}

/// Wraps a single accepted NWConnection and implements `DataTransporting`.
/// Created by `ConnectionListener` for each incoming client.
public final class ClientConnection: @unchecked Sendable, DataTransporting {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var receiveContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    /// Unique identifier for this client session.
    public let clientID: UUID

    init(connection: NWConnection, clientID: UUID = UUID()) {
        self.connection = connection
        self.clientID = clientID
        self.queue = DispatchQueue(label: "com.displaybridge.client.\(clientID.uuidString.prefix(8))", qos: .userInteractive)
    }

    /// No-op — the connection is already established when handed to us by the listener.
    public func connect() async throws {
        // Connection is already in .ready state from ConnectionListener.
    }

    public func send(_ data: Data) async throws {
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
        connection.send(content: data, completion: .idempotent)
    }

    public func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            onComplete()
            if let error = error {
                print("[ClientConnection] Send error, closing stream: \(error)")
                self?.lock.lock()
                self?.receiveContinuation?.finish(throwing: error)
                self?.receiveContinuation = nil
                self?.lock.unlock()
            }
        })
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.receiveContinuation = continuation
            self.lock.unlock()

            continuation.onTermination = { @Sendable _ in }

            // Monitor connection state to detect peer disconnect
            self.connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    print("[ClientConnection] Connection failed: \(error)")
                    self?.lock.lock()
                    self?.receiveContinuation?.finish(throwing: error)
                    self?.receiveContinuation = nil
                    self?.lock.unlock()
                case .cancelled:
                    print("[ClientConnection] Connection cancelled")
                    self?.lock.lock()
                    self?.receiveContinuation?.finish()
                    self?.receiveContinuation = nil
                    self?.lock.unlock()
                default:
                    break
                }
            }

            let buffer = ReceiveBuffer()
            self.receiveLoop(continuation: continuation, buffer: buffer)
        }
    }

    private func receiveLoop(
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
                let lenStart = buffer.data.startIndex + 24
                let lenEnd = lenStart + 4
                let payloadLength = Int(
                    buffer.data[lenStart..<lenEnd]
                        .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                        .littleEndian
                )

                let totalPacketSize = PacketFramer.headerSize + payloadLength
                guard buffer.data.count >= totalPacketSize else {
                    break
                }

                let packet = Data(buffer.data.prefix(totalPacketSize))
                buffer.data.removeFirst(totalPacketSize)
                continuation.yield(packet)
            }

            if isComplete {
                continuation.finish()
                return
            }

            self?.receiveLoop(continuation: continuation, buffer: buffer)
        }
    }

    public func disconnect() async {
        lock.lock()
        receiveContinuation?.finish()
        receiveContinuation = nil
        lock.unlock()

        connection.cancel()
    }

    deinit {
        connection.cancel()
    }
}
