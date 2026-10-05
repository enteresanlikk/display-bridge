import CoreMedia
@preconcurrency import IOSurface

public struct VideoFrame: Sendable {
    public let timestamp: CMTime
    public let surface: IOSurface
    public let width: Int
    public let height: Int
    /// Debug: uptime nanoseconds when frame was captured by ScreenCaptureKit
    public let captureTimeNs: UInt64
    /// How much of the frame differs from the previous one, 0...1. 1 when unknown.
    public let changedFraction: Float

    public init(timestamp: CMTime, surface: IOSurface, width: Int, height: Int, captureTimeNs: UInt64 = 0, changedFraction: Float = 1) {
        self.timestamp = timestamp
        self.surface = surface
        self.width = width
        self.height = height
        self.captureTimeNs = captureTimeNs
        self.changedFraction = changedFraction
    }
}
