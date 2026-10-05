public protocol DisplayCapturing: Sendable {
    func startCapture(config: DeviceConfig, handler: @escaping @Sendable (VideoFrame) -> Void) async throws
    func stopCapture() async
}
