import Foundation

public protocol DataTransporting: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    /// Fire-and-forget send for latency-sensitive data (video frames).
    /// Does not wait for the send to complete.
    func sendNonBlocking(_ data: Data)
    /// Send with completion callback — used for backpressure tracking.
    /// onComplete fires when TCP stack accepts the data (provides natural flow control).
    func sendTracked(_ data: Data, onComplete: @escaping @Sendable () -> Void)
    func receive() -> AsyncThrowingStream<Data, Error>
    func disconnect() async
}
