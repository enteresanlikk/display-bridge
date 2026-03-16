import CoreMedia
import Foundation
import IOSurface
import os
import ScreenCaptureKit

private let pipelineLog = OSLog(subsystem: "com.displaybridge", category: "pipeline")

public enum ScreenCapturerError: Error, Sendable {
    case displayNotFound(CGDirectDisplayID)
    case streamCreationFailed
    case noSurfaceInSampleBuffer
}

public final class ScreenCapturer: NSObject, DisplayCapturing, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var handler: (@Sendable (VideoFrame) -> Void)?
    private var virtualDisplayID: CGDirectDisplayID
    private let streamQueue = DispatchQueue(label: "com.displaybridge.screencapturer", qos: .userInteractive)

    /// Cached display reference from warmup.
    private var cachedDisplay: SCDisplay?
    /// Whether the stream is already running.
    private var isStreaming = false

    public init(virtualDisplayID: CGDirectDisplayID) {
        self.virtualDisplayID = virtualDisplayID
        super.init()
    }

    /// Updates the target display ID. Call after stopping capture and before restarting.
    public func updateDisplayID(_ newID: CGDirectDisplayID) {
        self.virtualDisplayID = newID
        self.cachedDisplay = nil
    }

    /// Pre-scans displays and caches the display reference.
    /// Retries a few times for newly created virtual displays to appear.
    public func preStart(config: DeviceConfig) async throws {
        // Virtual displays may take a moment to appear in SCShareableContent.
        // Retry up to 5 times (total ~1s) before giving up.
        for attempt in 1...5 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            if let display = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                cachedDisplay = display
                print("[ScreenCapturer] Display found: \(display.displayID) (\(display.width)x\(display.height))")
                return
            }

            print("[ScreenCapturer] Virtual display \(virtualDisplayID) not yet visible (attempt \(attempt)/5, available: \(content.displays.map { $0.displayID }))")
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw ScreenCapturerError.displayNotFound(virtualDisplayID)
    }

    public func startCapture(
        config: DeviceConfig,
        handler: @escaping @Sendable (VideoFrame) -> Void
    ) async throws {
        self.handler = handler

        // Always stop any existing stream and start fresh.
        // SCStream stops delivering image data for idle virtual displays,
        // so we must start a new stream with the handler already set.
        if isStreaming, let oldStream = self.stream {
            print("[ScreenCapturer] Stopping pre-started stream to restart fresh.")
            try? await oldStream.stopCapture()
            self.stream = nil
            self.isStreaming = false
        }

        let display: SCDisplay
        if let cached = cachedDisplay {
            display = cached
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let found = content.displays.first(where: { $0.displayID == virtualDisplayID }) else {
                throw ScreenCapturerError.displayNotFound(virtualDisplayID)
            }
            display = found
        }

        print("[ScreenCapturer] Starting capture on display \(display.displayID) (\(display.width)x\(display.height))")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.refreshRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 3
        streamConfig.showsCursor = true

        if #available(macOS 14.0, *) {
            streamConfig.captureResolution = .best
        }

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)

        try await newStream.startCapture()
        self.stream = newStream
        self.isStreaming = true
        print("[ScreenCapturer] Capture started. Handler is set, frames flowing.")
    }

    public func stopCapture() async {
        guard let stream = self.stream else { return }
        self.stream = nil
        self.handler = nil
        self.isStreaming = false
        do {
            try await stream.stopCapture()
        } catch {
            // Ignore "already stopped" errors during shutdown
        }
    }

    // MARK: - SCStreamOutput

    private var _frameCallbackCount: Int = 0

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        _frameCallbackCount += 1
        if _frameCallbackCount <= 3 || _frameCallbackCount % 300 == 0 {
            let hasHandler = handler != nil
            let hasImage = sampleBuffer.imageBuffer != nil
            print("[ScreenCapturer] frame #\(_frameCallbackCount) hasImage=\(hasImage) hasHandler=\(hasHandler)")
        }

        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        guard let handler = handler else { return }

        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        guard let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let captureTime = DispatchTime.now().uptimeNanoseconds
        os_signpost(.event, log: pipelineLog, name: "frame-captured", "capture_ns=%llu w=%d h=%d", captureTime, width, height)

        let frame = VideoFrame(
            timestamp: timestamp,
            surface: surface,
            width: width,
            height: height,
            captureTimeNs: captureTime
        )

        handler(frame)
    }
}
