import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoDecoderError: Error, Sendable {
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
}

/// Hardware H.265 / H.264 decoder, the sink-side counterpart of `VideoToolboxEncoder`.
///
/// Input is the exact Annex-B byte stream the encoder produces: each NAL prefixed with a
/// 3- or 4-byte start code, and on keyframes the parameter sets (HEVC: VPS+SPS+PPS,
/// H.264: SPS+PPS) prepended, also start-code-prefixed. Output is decoded `CVPixelBuffer`s
/// delivered on VideoToolbox's async decode thread via `onDecodedFrame`.
///
/// Pipeline per `decode(...)`:
///   1. Split the Annex-B blob into NAL units on start codes.
///   2. On a keyframe, collect the parameter-set NALs and (re)build a
///      `CMVideoFormatDescription`; recreate the `VTDecompressionSession` if it changed.
///   3. Convert the VCL (slice) NALs from Annex-B to AVCC (4-byte length prefix), wrap in a
///      `CMBlockBuffer` + `CMSampleBuffer` carrying the format description and timing, and
///      hand it to the session.
///
/// Robustness: delta frames that arrive before the first format description are logged and
/// dropped; malformed input is skipped, never fatal.
///
/// `@unchecked Sendable`: all mutable state (`formatDescription`, `session`, the cached
/// parameter sets) is guarded by `lock`; VideoToolbox serializes its own callback delivery.
public final class VideoToolboxDecoder: @unchecked Sendable {
    /// Delivered for every successfully decoded frame, on VideoToolbox's decode thread.
    public typealias DecodedFrameHandler = @Sendable (CVPixelBuffer, UInt64) -> Void

    private let codec: VideoCodec
    private var onDecodedFrame: DecodedFrameHandler

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    /// The parameter-set bytes the current `formatDescription` was built from; used to detect
    /// a real change (resolution / stream restart) so we only rebuild the session when needed.
    private var cachedParameterSets: [Data] = []
    private var loggedMissingFormat = false

    /// - Parameters:
    ///   - codec: the codec the incoming stream is encoded with (from the negotiated
    ///     `DeviceConfig`). Determines how NAL types and parameter sets are parsed.
    ///   - onDecodedFrame: receives each decoded `CVPixelBuffer` and its timestamp (micros).
    public init(codec: VideoCodec, onDecodedFrame: @escaping DecodedFrameHandler) {
        self.codec = codec
        self.onDecodedFrame = onDecodedFrame
    }

    /// Redirects decoded frames to a new handler. Used by `SinkCoordinator` to route the
    /// decoder's output to its own `onFrame` consumer after construction.
    public func setFrameHandler(_ handler: @escaping DecodedFrameHandler) {
        lock.withLock { onDecodedFrame = handler }
    }

    deinit {
        teardownSession()
    }

    // MARK: - Public API

    /// Decodes one Annex-B access unit. Safe to call from the Rust `decode` callback thread.
    public func decode(nal: Data, isKeyframe: Bool, timestampMicros: UInt64) {
        let nalUnits = Self.splitAnnexB(nal)
        guard !nalUnits.isEmpty else { return }

        lock.lock()

        if isKeyframe {
            // A keyframe carries the parameter sets. Extract them and (re)build the format
            // description + session if they changed from what we last saw.
            let paramSets = nalUnits.filter { isParameterSet($0) }
            if !paramSets.isEmpty {
                do {
                    try ensureFormatDescription(paramSets: paramSets)
                } catch {
                    lock.unlock()
                    print("[VideoToolboxDecoder] Failed to build format description: \(error)")
                    return
                }
            }
        }

        guard let formatDescription = self.formatDescription, let session = self.session else {
            let alreadyLogged = loggedMissingFormat
            loggedMissingFormat = true
            lock.unlock()
            if !alreadyLogged {
                print("[VideoToolboxDecoder] Dropping frame: no format description yet "
                    + "(waiting for first keyframe with parameter sets).")
            }
            return
        }

        // Slice/VCL NALs are everything that is not a parameter set. Convert to AVCC.
        let vclUnits = nalUnits.filter { !isParameterSet($0) }
        lock.unlock()

        guard !vclUnits.isEmpty else { return }

        do {
            let sampleBuffer = try makeSampleBuffer(
                vclUnits: vclUnits,
                formatDescription: formatDescription,
                timestampMicros: timestampMicros
            )
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                print("[VideoToolboxDecoder] DecodeFrame failed: \(status)")
            }
        } catch {
            print("[VideoToolboxDecoder] Failed to build/submit sample buffer: \(error)")
        }
    }

    /// Blocks until all in-flight async decodes have been delivered. Useful for tests/teardown.
    public func flush() {
        let session = lock.withLock { self.session }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    // MARK: - Format description / session

    /// (Re)builds the `CMVideoFormatDescription` and `VTDecompressionSession` from parameter
    /// sets, but only if they differ from the cached set. Caller holds `lock`.
    private func ensureFormatDescription(paramSets: [Data]) throws {
        if paramSets == cachedParameterSets, formatDescription != nil, session != nil {
            return
        }

        let formatDesc = try Self.makeFormatDescription(codec: codec, parameterSets: paramSets)

        // Recreate the session whenever the format description changes.
        teardownSessionLocked()

        let session = try makeSession(formatDescription: formatDesc)

        self.formatDescription = formatDesc
        self.session = session
        self.cachedParameterSets = paramSets
        print("[VideoToolboxDecoder] Format description ready "
            + "(\(codec), \(paramSets.count) parameter set(s)); decode session created.")
    }

    private static func makeFormatDescription(
        codec: VideoCodec,
        parameterSets: [Data]
    ) throws -> CMVideoFormatDescription {
        // Gather stable pointers + sizes for the C API. `withUnsafeBytes` regions must all be
        // live simultaneously, so build the arrays via a recursive borrow.
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []

        func withAll(_ index: Int, _ body: () throws -> CMVideoFormatDescription?) rethrows -> CMVideoFormatDescription? {
            if index == parameterSets.count {
                return try body()
            }
            return try parameterSets[index].withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return try withAll(index + 1, body)
                }
                pointers.append(base)
                sizes.append(raw.count)
                return try withAll(index + 1, body)
            }
        }

        var result: CMVideoFormatDescription?
        var status: OSStatus = noErr

        _ = try withAll(0) {
            var formatDesc: CMFormatDescription?
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
            result = formatDesc
            return formatDesc
        }

        guard status == noErr, let result else {
            throw VideoDecoderError.formatDescriptionCreationFailed(status)
        }
        return result
    }

    private func makeSession(formatDescription: CMVideoFormatDescription) throws -> VTDecompressionSession {
        // 32BGRA output, IOSurface-backed — matches the encoder's input surface so the render
        // path (Metal / AVSampleBufferDisplayLayer) can consume it zero-copy.
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoDecoderError.sessionCreationFailed(status)
        }
        return session
    }

    /// Delivers a decoded pixel buffer to the handler. Called from the C output callback.
    fileprivate func deliver(_ pixelBuffer: CVPixelBuffer, presentation: CMTime) {
        let micros: UInt64
        if presentation.isValid, presentation.timescale != 0 {
            let seconds = CMTimeGetSeconds(presentation)
            micros = seconds.isFinite && seconds >= 0 ? UInt64(seconds * 1_000_000) : 0
        } else {
            micros = 0
        }
        let handler = lock.withLock { onDecodedFrame }
        handler(pixelBuffer, micros)
    }

    // MARK: - Sample buffer assembly

    private func makeSampleBuffer(
        vclUnits: [Data],
        formatDescription: CMVideoFormatDescription,
        timestampMicros: UInt64
    ) throws -> CMSampleBuffer {
        // Annex-B -> AVCC: each NAL prefixed with its 4-byte big-endian length.
        var avcc = Data(capacity: vclUnits.reduce(0) { $0 + $1.count + 4 })
        for unit in vclUnits {
            var len = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        let mutableAVCC = avcc // capture a stable copy for memcpy
        let dataStatus = mutableAVCC.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            var bb: CMBlockBuffer?
            // Allocate a managed block buffer and copy the AVCC bytes into it so the buffer owns
            // its memory (the Data's storage must not be required to outlive this call).
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: raw.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: raw.count,
                flags: 0,
                blockBufferOut: &bb
            )
            guard createStatus == kCMBlockBufferNoErr, let bb else { return createStatus }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: raw.count
            )
            blockBuffer = bb
            return copyStatus
        }
        guard dataStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoDecoderError.blockBufferCreationFailed(dataStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = mutableAVCC.count
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw VideoDecoderError.sampleBufferCreationFailed(sbStatus)
        }
        return sampleBuffer
    }

    // MARK: - NAL helpers

    /// True if the NAL is a parameter set for the configured codec (HEVC: VPS/SPS/PPS,
    /// H.264: SPS/PPS). Caller-independent; reads only the NAL header byte(s).
    private func isParameterSet(_ nal: Data) -> Bool {
        guard let type = Self.nalType(nal, codec: codec) else { return false }
        switch codec {
        case .hevc:
            return type == 32 || type == 33 || type == 34 // VPS, SPS, PPS
        case .h264:
            return type == 7 || type == 8 // SPS, PPS
        }
    }

    /// Extracts the NAL unit type from the header byte(s).
    ///   H.264: `nal_unit_type = firstByte & 0x1F`
    ///   HEVC:  `nal_unit_type = (firstByte >> 1) & 0x3F`
    static func nalType(_ nal: Data, codec: VideoCodec) -> UInt8? {
        guard let first = nal.first else { return nil }
        switch codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    /// Splits an Annex-B byte stream into raw NAL units (start codes removed). Handles both
    /// 4-byte (`00 00 00 01`) and 3-byte (`00 00 01`) start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 3 else { return units }

        // Find every start-code offset (the index just past the start code).
        var starts: [Int] = []
        var i = 0
        while i + 3 <= n {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                } else if i + 4 <= n && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }

        for (idx, startOfPayload) in starts.enumerated() {
            // The payload runs until the next start code begins. Locate that by scanning from
            // this payload to the next recorded start (minus its start-code length).
            let end: Int
            if idx + 1 < starts.count {
                // Next start-code start index: back up from the next payload offset over its
                // start code (3 or 4 bytes). Recompute by scanning backwards for the zeros.
                var nextStart = starts[idx + 1]
                // start code is 3 or 4 bytes ending in 01 right before nextStart
                if nextStart >= 4 && bytes[nextStart - 4] == 0 && bytes[nextStart - 3] == 0
                    && bytes[nextStart - 2] == 0 && bytes[nextStart - 1] == 1 {
                    nextStart -= 4
                } else {
                    nextStart -= 3
                }
                end = nextStart
            } else {
                end = n
            }
            if end > startOfPayload {
                units.append(Data(bytes[startOfPayload..<end]))
            }
        }
        return units
    }

    // MARK: - Teardown

    private func teardownSession() {
        lock.withLock { teardownSessionLocked() }
    }

    /// Caller holds `lock`.
    private func teardownSessionLocked() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }
}

/// C output callback: recovers the decoder from `decompressionOutputRefCon` and forwards the
/// decoded image buffer. Captures nothing, so it converts to a `@convention(c)` pointer.
private let decompressionOutputCallback: VTDecompressionOutputCallback = {
    (refcon, _, status, _, imageBuffer, presentation, _) in
    guard let refcon else { return }
    let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(refcon).takeUnretainedValue()
    guard status == noErr, let imageBuffer else {
        if status != noErr { print("[VideoToolboxDecoder] Decode callback status: \(status)") }
        return
    }
    decoder.deliver(imageBuffer, presentation: presentation)
}
