import CoreMedia
import IOSurface

public struct VideoFrame: Sendable {
    public let timestamp: CMTime
    public let surface: IOSurface
    public let width: Int
    public let height: Int
    /// Debug: uptime nanoseconds when frame was captured by ScreenCaptureKit
    public let captureTimeNs: UInt64

    public init(timestamp: CMTime, surface: IOSurface, width: Int, height: Int, captureTimeNs: UInt64 = 0) {
        self.timestamp = timestamp
        self.surface = surface
        self.width = width
        self.height = height
        self.captureTimeNs = captureTimeNs
    }
}
