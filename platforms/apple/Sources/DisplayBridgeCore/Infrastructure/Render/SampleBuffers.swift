import CoreMedia
import CoreVideo

/// Turns decoded pixel buffers into sample buffers an `AVSampleBufferDisplayLayer` shows
/// immediately. Shared by the AppKit and UIKit sink views.
enum SampleBuffers {
    /// Wraps a `CVPixelBuffer` in a display-ready `CMSampleBuffer`, reusing a cached format
    /// description when the buffer's dimensions/format are unchanged.
    static func make(
        pixelBuffer: CVPixelBuffer,
        cachedFormat: inout CMVideoFormatDescription?,
        timestampMicros: UInt64
    ) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var needsNewFormat = true
        if let fmt = cachedFormat {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            needsNewFormat = Int(dims.width) != width || Int(dims.height) != height
        }
        if needsNewFormat {
            var fmt: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmt
            )
            guard status == noErr, let fmt else { return nil }
            cachedFormat = fmt
        }
        guard let formatDescription = cachedFormat else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }

        // Ask the layer to display immediately (low latency, no reordering).
        if let sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self),
                unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self)
            )
        }
        return sampleBuffer
    }
}
