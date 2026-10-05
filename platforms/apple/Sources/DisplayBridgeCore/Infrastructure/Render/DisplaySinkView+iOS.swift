#if os(iOS)
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// The UIKit counterpart of the AppKit `DisplaySinkView`: shows decoded frames through an
/// `AVSampleBufferDisplayLayer` and turns touches into pointer events for the source.
///
/// Call `enqueue(_:timestampMicros:)` from any thread. Set `onInput` to forward input.
public final class DisplaySinkView: UIView {
    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    /// Cached format description, rebuilt only when the pixel buffer's dimensions change.
    private var formatDescription: CMVideoFormatDescription?
    private var gestures = TouchGestureTranslator()

    /// Receives pointer events in the source display's normalized coordinates.
    public var onInput: ((InputEvent) -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
    }

    /// Enqueues one decoded frame for display. Callable from any thread: it always hops
    /// to the main thread, where the layer lives.
    public nonisolated func enqueue(_ pixelBuffer: CVPixelBuffer, timestampMicros: UInt64) {
        // The decoder hands each buffer over and never touches it again, so passing it to
        // the main thread is safe even though the type is not marked Sendable.
        nonisolated(unsafe) let frame = pixelBuffer
        DispatchQueue.main.async { [weak self] in
            self?.enqueueOnMain(frame, timestampMicros: timestampMicros)
        }
    }

    private func enqueueOnMain(_ pixelBuffer: CVPixelBuffer, timestampMicros: UInt64) {
        guard let sampleBuffer = SampleBuffers.make(
            pixelBuffer: pixelBuffer,
            cachedFormat: &formatDescription,
            timestampMicros: timestampMicros
        ) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Input forwarding

    /// Where the picture actually sits inside the view (`.resizeAspect` letterboxes it).
    private var videoRect: CGRect {
        guard let fmt = formatDescription else { return bounds }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        return AVMakeRect(
            aspectRatio: CGSize(width: Int(dims.width), height: Int(dims.height)), insideRect: bounds
        )
    }

    private func forward(_ phase: TouchGestureTranslator.Phase, _ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let onInput else { return }
        let rect = videoRect
        let active = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
        // The touches this update is about come first; the rest follow so a two-finger
        // gesture always sees both fingers.
        let ordered = Array(touches) + active.filter { !touches.contains($0) }
        let points = ordered.map { touch -> CGPoint in
            let p = touch.location(in: self)
            return CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
        }
        let pen = touches.first?.type == .pencil
        let force = touches.first.map { $0.maximumPossibleForce > 0 ? Float($0.force / $0.maximumPossibleForce) : 1 } ?? 1
        gestures.handle(
            phase, points: points, remaining: active.count, in: rect.size,
            precise: pen, pressure: pen ? force : 1
        ).forEach(onInput)
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(.began, touches, event) }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(.moved, touches, event) }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(.ended, touches, event) }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(.cancelled, touches, event) }
}
#endif
