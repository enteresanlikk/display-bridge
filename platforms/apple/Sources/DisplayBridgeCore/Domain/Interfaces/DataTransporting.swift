import Foundation

public enum USBTransportError: Error, Sendable {
    case connectionFailed(String)
    case sendFailed(String)
    case notConnected
    case alreadyListening
    case listenerFailed(String)
}

public protocol DataTransporting: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    /// Send with completion callback — used for backpressure tracking.
    /// onComplete fires when TCP stack accepts the data (provides natural flow control).
    func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void)
    func receive() -> AsyncThrowingStream<Data, Error>
    func disconnect() async
}
