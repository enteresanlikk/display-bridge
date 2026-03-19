import CoreMedia
import Foundation
import IOSurface
import VideoToolbox

public enum VideoEncoderError: Error, Sendable {
    case sessionCreationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case noDataReturned
    case notConfigured
}

/// Context passed through the VTCompressionSession output callback.
/// Uses a closure + semaphore for synchronous (zero-overhead) encoding.
private final class EncoderOutputContext {
    let completion: (Result<EncodedFrame, Error>) -> Void
    let sequenceNumber: UInt64
    let codec: VideoCodec

    init(completion: @escaping (Result<EncodedFrame, Error>) -> Void, sequenceNumber: UInt64, codec: VideoCodec) {
        self.completion = completion
        self.sequenceNumber = sequenceNumber
        self.codec = codec
    }
}

public final class VideoToolboxEncoder: @unchecked Sendable, VideoEncoding {
    private var compressionSession: VTCompressionSession?
    private var sequenceCounter: UInt64 = 0
    private var isConfigured = false
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentCodec: VideoCodec = .hevc
    private let lock = NSLock()

    /// Maximum bitrate in bits/sec. Set before `setup()` to limit for bandwidth-constrained transports.
    /// USB 2.0 AOA: ~200 Mbps practical limit. TCP: effectively unlimited.
    public var maxBitrate: Int = 500_000_000

    public init() {}

    /// Sets up the compression session with the given configuration.
    /// Skips re-creation if already configured for the same resolution.
    public func setup(config: DeviceConfig) throws {
        lock.lock()

        if isConfigured && currentWidth == config.width && currentHeight == config.height && currentCodec == config.codec {
            lock.unlock()
            return
        }

        defer { lock.unlock() }

        teardownSession()

        let codec: CMVideoCodecType
        switch config.codec {
        case .hevc:
            codec = kCMVideoCodecType_HEVC
        case .h264:
            codec = kCMVideoCodecType_H264
        }

        var session: VTCompressionSession?

        // VTCompressionSession output callback — delivers encoded data via closure
        let outputCallback: VTCompressionOutputCallback = { _, sourceFrameRefCon, status, infoFlags, sampleBuffer in
            guard let sourceFrameRefCon = sourceFrameRefCon else { return }
            let context = Unmanaged<EncoderOutputContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()

            if status != noErr {
                context.completion(.failure(VideoEncoderError.encodingFailed(status)))
                return
            }

            guard let sampleBuffer = sampleBuffer else {
                context.completion(.failure(VideoEncoderError.noDataReturned))
                return
            }

            // Check if this is a key frame
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            var isKeyFrame = true
            if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attachments, 0),
                    to: CFDictionary.self
                )
                if let notSync = CFDictionaryGetValue(dict,
                    unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)) {
                    isKeyFrame = !(unsafeBitCast(notSync, to: CFBoolean.self) == kCFBooleanTrue)
                }
            }

            // Extract the encoded data
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                context.completion(.failure(VideoEncoderError.noDataReturned))
                return
            }

            var totalLength: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let dataStatus = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )

            guard dataStatus == kCMBlockBufferNoErr, let dataPointer = dataPointer else {
                context.completion(.failure(VideoEncoderError.noDataReturned))
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Convert HVCC (length-prefixed) to Annex B (start-code-prefixed) format
            var annexBData = Data(capacity: totalLength + 128)
            let startCodeData = Data([0x00, 0x00, 0x00, 0x01])

            // For keyframes, extract and prepend parameter sets (HEVC: VPS/SPS/PPS, H.264: SPS/PPS)
            if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var paramSetCount: Int = 0

                switch context.codec {
                case .hevc:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        formatDesc, parameterSetIndex: 0,
                        parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                        parameterSetCountOut: &paramSetCount, nalUnitHeaderLengthOut: nil
                    )
                    for i in 0..<paramSetCount {
                        var paramPointer: UnsafePointer<UInt8>?
                        var paramSize: Int = 0
                        let s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                            formatDesc, parameterSetIndex: i,
                            parameterSetPointerOut: &paramPointer,
                            parameterSetSizeOut: &paramSize,
                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                        )
                        if s == noErr, let p = paramPointer {
                            annexBData.append(startCodeData)
                            annexBData.append(p, count: paramSize)
                        }
                    }

                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formatDesc, parameterSetIndex: 0,
                        parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                        parameterSetCountOut: &paramSetCount, nalUnitHeaderLengthOut: nil
                    )
                    for i in 0..<paramSetCount {
                        var paramPointer: UnsafePointer<UInt8>?
                        var paramSize: Int = 0
                        let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            formatDesc, parameterSetIndex: i,
                            parameterSetPointerOut: &paramPointer,
                            parameterSetSizeOut: &paramSize,
                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                        )
                        if s == noErr, let p = paramPointer {
                            annexBData.append(startCodeData)
                            annexBData.append(p, count: paramSize)
                        }
                    }
                }
            }

            // Convert each HVCC NAL unit: replace 4-byte length prefix with start code
            let raw = UnsafeRawPointer(dataPointer)
            var offset = 0
            while offset + 4 <= totalLength {
                let nalLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
                offset += 4
                guard offset + nalLength <= totalLength else { break }
                annexBData.append(startCodeData)
                annexBData.append(UnsafeBufferPointer(
                    start: raw.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                    count: nalLength
                ))
                offset += nalLength
            }

            let encodedFrame = EncodedFrame(
                timestamp: pts,
                data: annexBData,
                isKeyFrame: isKeyFrame,
                sequenceNumber: context.sequenceNumber
            )

            context.completion(.success(encodedFrame))
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: codec,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: config.width,
                kCVPixelBufferHeightKey: config.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        // Configure session properties for low-latency, high-quality encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Zero frame delay: encoder outputs immediately without internal buffering
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Adaptive bitrate: 0.4 bits/pixel/frame — sharp text at any resolution
        // Capped by maxBitrate (USB 2.0 = 200 Mbps, TCP = 500 Mbps)
        //   TCP:  1080p@120→100M  4K@60→199M  4K@120→398M
        //   USB:  1080p@120→100M  4K@60→199M  4K@120→200M (capped)
        let pixelsPerFrame = config.width * config.height
        let targetBitrate = Double(pixelsPerFrame) * 0.4 * Double(config.refreshRate)
        let bitrate = max(50_000_000, min(maxBitrate, Int(targetBitrate)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Hard cap: 25% headroom above average for keyframe bursts
        let dataRateLimits: [Int] = [bitrate / 8 * 5 / 4, 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: config.refreshRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: config.refreshRate as CFNumber)
        let profileLevel: CFString = config.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                           value: profileLevel)

        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        self.isConfigured = true
        self.currentWidth = config.width
        self.currentHeight = config.height
        self.currentCodec = config.codec
    }

    /// Synchronous encode — blocks the calling thread until hardware encoder finishes.
    /// This is the fast path for real-time video: no Task scheduling, no async overhead.
    /// Call from a dedicated thread (e.g., ScreenCaptureKit's streamQueue).
    public func encodeSync(_ frame: VideoFrame) throws -> EncodedFrame {
        lock.lock()
        guard let session = compressionSession, isConfigured else {
            lock.unlock()
            throw VideoEncoderError.notConfigured
        }
        let seq = sequenceCounter
        let codec = currentCodec
        sequenceCounter += 1
        lock.unlock()

        // Create a pixel buffer backed by the IOSurface for zero-copy
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            frame.surface,
            [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            &unmanagedPixelBuffer
        )

        guard cvStatus == kCVReturnSuccess, let unmanagedPB = unmanagedPixelBuffer else {
            throw VideoEncoderError.encodingFailed(cvStatus)
        }
        let pixelBuffer = unmanagedPB.takeRetainedValue()

        let sem = DispatchSemaphore(value: 0)
        var encodeResult: Result<EncodedFrame, Error>?

        let context = EncoderOutputContext(
            completion: { result in
                encodeResult = result
                sem.signal()
            },
            sequenceNumber: seq,
            codec: codec
        )
        let refcon = Unmanaged.passRetained(context).toOpaque()

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: frame.timestamp,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )

        let waitResult = sem.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            throw VideoEncoderError.encodingFailed(-1)
        }

        guard let result = encodeResult else {
            throw VideoEncoderError.noDataReturned
        }
        return try result.get()
    }

    public func encode(_ frame: VideoFrame) async throws -> EncodedFrame {
        return try encodeSync(frame)
    }

    public func flush() async {
        guard let session = lock.withLock({ compressionSession }) else {
            return
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    private func teardownSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        isConfigured = false
        sequenceCounter = 0
        currentWidth = 0
        currentHeight = 0
    }

    deinit {
        teardownSession()
    }
}
