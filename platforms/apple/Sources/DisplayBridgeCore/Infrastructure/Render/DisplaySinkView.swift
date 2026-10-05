#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

/// A minimal, low-latency AppKit view that renders decoded `CVPixelBuffer`s from a
/// `SinkCoordinator` / `VideoToolboxDecoder`.
///
/// It is backed by an `AVSampleBufferDisplayLayer`: each incoming pixel buffer is wrapped in
/// a `CMSampleBuffer` (with a format description derived from the buffer itself) and enqueued.
/// The layer handles GPU compositing and vsync, which is the simplest correct on-screen path
/// for a stream of already-decoded frames. An alternative would be a `CAMetalLayer` +
/// `CVMetalTextureCache` draw; the sample-buffer layer is chosen for brevity and because it
/// needs no shader/pipeline setup.
///
/// This is the on-screen path only; it is exercised at runtime, not in the headless proof.
/// Call `enqueue(_:)` from any thread — it hops to the main thread and enqueues.
///
/// Set `onInput` to forward mouse / trackpad events over the picture back to the source.
public final class DisplaySinkView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    /// Cached format description, rebuilt only when the pixel buffer's dimensions/format change.
    private var formatDescription: CMVideoFormatDescription?

    /// Receives pointer events in the source display's normalized coordinates.
    public var onInput: ((InputEvent) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    // MARK: - Input forwarding

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    /// Where the picture actually sits inside the view (`.resizeAspect` letterboxes it).
    private var videoRect: CGRect {
        guard let fmt = formatDescription else { return bounds }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        return AVMakeRect(
            aspectRatio: CGSize(width: Int(dims.width), height: Int(dims.height)), insideRect: bounds
        )
    }

    private func forward(_ kind: InputEvent.Kind, _ event: NSEvent, button: UInt8 = 0) {
        guard let onInput else { return }
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        var input = InputEvent(
            kind: kind, button: button,
            x: Float((p.x - rect.minX) / rect.width),
            // AppKit's origin is bottom-left; the wire format's is top-left.
            y: Float(1 - (p.y - rect.minY) / rect.height)
        )
        switch kind {
        case .down, .move:
            input.pressure = event.pressure
        case .scroll:
            // A wheel reports lines, a trackpad reports points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            input.dx = Float(event.scrollingDeltaX * scale / rect.width)
            input.dy = Float(event.scrollingDeltaY * scale / rect.height)
            input.pressure = 0
        case .up, .hover:
            input.pressure = 0
        }
        onInput(input)
    }

    public override func mouseDown(with event: NSEvent) { forward(.down, event) }
    public override func mouseDragged(with event: NSEvent) { forward(.move, event) }
    public override func mouseUp(with event: NSEvent) { forward(.up, event) }
    public override func rightMouseDown(with event: NSEvent) { forward(.down, event, button: 1) }
    public override func rightMouseDragged(with event: NSEvent) { forward(.move, event, button: 1) }
    public override func rightMouseUp(with event: NSEvent) { forward(.up, event, button: 1) }
    public override func mouseMoved(with event: NSEvent) { forward(.hover, event) }
    public override func scrollWheel(with event: NSEvent) { forward(.scroll, event) }

    /// Enqueues one decoded frame for display. Thread-safe.
    public func enqueue(_ pixelBuffer: CVPixelBuffer, timestampMicros: UInt64) {
        // Marshal to the main thread; layer mutation must happen there.
        if Thread.isMainThread {
            enqueueOnMain(pixelBuffer, timestampMicros: timestampMicros)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.enqueueOnMain(pixelBuffer, timestampMicros: timestampMicros)
            }
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
}
#endif
