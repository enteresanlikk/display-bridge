public protocol VideoEncoding: Sendable {
    func setup(config: DeviceConfig) throws
    /// Synchronous encode — blocks calling thread until HW encoder finishes (~1ms).
    /// Use this for real-time pipelines to avoid Task/async scheduling overhead.
    func encodeSync(_ frame: VideoFrame) throws -> EncodedFrame
    func encode(_ frame: VideoFrame) async throws -> EncodedFrame
    func flush() async
}
