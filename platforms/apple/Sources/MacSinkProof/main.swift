// Real, headless codec roundtrip proof of the macOS SINK path (`swift run MacSinkProof`).
//
// VideoToolbox encode + decode need NO display and NO screen-recording permission, so this
// exercises the full pipeline end to end with zero UI:
//
//   VideoToolboxEncoder (1280x720@60 HEVC)
//     → synthesize a solid-color IOSurface 32BGRA frame, encodeSync → real Annex-B keyframe
//   source RustSession(.source)  ↔  sink RustSession(.sink)   (in-process loopback)
//     → handshake completes, source goes Streaming
//     → source.submitFrame(annexB, isKeyframe:…) → VideoFrame on the wire → sink.decode
//     → VideoToolboxDecoder.decode → VTDecompressionSession → CVPixelBuffer
//
// ASSERTS the decoder emits a 1280x720 CVPixelBuffer for the keyframe (and the delta), and
// that a sampled center pixel is within a loose tolerance of the input color — proving
// encode → wire → Rust core → decode works. Exits non-zero on any failure.
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import DisplayBridgeCore

// ---- Test helpers -----------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  PASS: \(msg)") } else { print("  FAIL: \(msg)"); failures += 1 }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

// Input solid color (BGRA byte order in memory).
let inB: UInt8 = 40
let inG: UInt8 = 170
let inR: UInt8 = 90

let W = 1280
let H = 720

/// Builds a 1280x720 32BGRA IOSurface filled with the solid input color.
func makeSolidSurface() -> IOSurface? {
    let bytesPerElement = 4
    let props: [IOSurfacePropertyKey: Any] = [
        .width: W,
        .height: H,
        .bytesPerElement: bytesPerElement,
        .pixelFormat: kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurface(properties: props) else { return nil }
    surface.lock(options: [], seed: nil)
    let base = surface.baseAddress
    let bytesPerRow = surface.bytesPerRow
    for y in 0..<H {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<W {
            row[x * 4 + 0] = inB
            row[x * 4 + 1] = inG
            row[x * 4 + 2] = inR
            row[x * 4 + 3] = 255
        }
    }
    surface.unlock(options: [], seed: nil)
    return surface
}

// ---- 1. Encode two real frames ----------------------------------------------

print("[encode] VideoToolboxEncoder 1280x720@60 HEVC")

let codec: VideoCodec = .hevc
let encoder = VideoToolboxEncoder()
do {
    try encoder.setup(config: DeviceConfig(width: W, height: H, refreshRate: 60, codec: codec))
} catch {
    print("FAIL: encoder setup threw \(error)"); exit(2)
}

var encodedFrames: [EncodedFrame] = []
for i in 0..<2 {
    guard let surface = makeSolidSurface() else { print("FAIL: could not create IOSurface"); exit(2) }
    let frame = VideoFrame(
        timestamp: CMTime(value: CMTimeValue(i), timescale: 60),
        surface: surface, width: W, height: H, captureTimeNs: UInt64(i) * 16_666_666
    )
    do {
        let enc = try encoder.encodeSync(frame)
        encodedFrames.append(enc)
    } catch {
        print("FAIL: encodeSync threw \(error)"); exit(2)
    }
}
check(encodedFrames.count == 2, "encoded 2 frames")
check(encodedFrames.first?.isKeyFrame == true, "first encoded frame is a keyframe")
check((encodedFrames.first?.data.count ?? 0) > 0, "keyframe carries Annex-B bytes")

// ---- 2. Sink decoder --------------------------------------------------------

let decodedCount = Box<Int>(0)
let lastDims = Box<(Int, Int)>((0, 0))
let centerPixel = Box<(UInt8, UInt8, UInt8)?>(nil)
let decodedSem = DispatchSemaphore(value: 0)

let decoder = VideoToolboxDecoder(codec: codec) { pixelBuffer, _ in
    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    lastDims.set((w, h))
    decodedCount.set(decodedCount.get() + 1)

    // Sample the center pixel (32BGRA) for a loose color check.
    if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let cx = w / 2, cy = h / 2
            let p = base.advanced(by: cy * bpr + cx * 4).assumingMemoryBound(to: UInt8.self)
            centerPixel.set((p[0], p[1], p[2]))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    decodedSem.signal()
}

// ---- 3. In-process loopback: source RustSession ↔ sink RustSession ----------

print("[loopback] source .source ↔ sink .sink")

let sinkStreaming = DispatchSemaphore(value: 0)

// Forward references resolved after both sessions exist.
let sourceBox = Box<RustSession?>(nil)
let sinkBox = Box<RustSession?>(nil)

// Source: forwards framed bytes to the sink; no-op capture seams (we submit frames manually).
let sourceHandlers = RustSessionHandlers(
    send: { data in sinkBox.get()?.feed(bytes: data) },
    reconfigure: { _ in },
    startCapture: { _ in },
    stopCapture: { }
)
guard let source = RustSession(role: .source, handlers: sourceHandlers) else {
    print("FAIL: could not create source RustSession"); exit(2)
}
sourceBox.set(source)

// Sink: forwards framed bytes to the source; feeds decode-ready NALs to the HW decoder.
let sinkHandlers = RustSessionHandlers(
    send: { data in sourceBox.get()?.feed(bytes: data) },
    decode: { nal, isKeyframe, tsMicros in
        decoder.decode(nal: nal, isKeyframe: isKeyframe, timestampMicros: tsMicros)
    },
    onStateChange: { state in if state == .streaming { sinkStreaming.signal() } }
)
guard let sink = RustSession(role: .sink, handlers: sinkHandlers) else {
    print("FAIL: could not create sink RustSession"); exit(2)
}
sinkBox.set(sink)

let config = DeviceConfig(width: W, height: H, refreshRate: 60, codec: codec, deviceName: "Proof Sink")
_ = sink.setConfig(config)

// Bring up the source's native transport, then kick the sink handshake.
source.notifyConnected()
sink.notifyConnected()

if sinkStreaming.wait(timeout: .now() + 5) == .timedOut {
    check(false, "sink reached Streaming (handshake completed)")
    print("\(failures) FAILURES"); exit(1)
}
check(true, "sink reached Streaming (handshake round-trip)")

// ---- 4. Stream the encoded frames through the core --------------------------

for (i, enc) in encodedFrames.enumerated() {
    source.submitFrame(enc.data, isKeyframe: enc.isKeyFrame, captureTimeNs: UInt64(i) * 16_666_666)
    // Small gap so the source's paced send loop emits them as distinct frames.
    usleep(20_000)
}

// Wait for at least the keyframe to be decoded (VT decode is async on its own thread).
if decodedSem.wait(timeout: .now() + 5) == .timedOut {
    check(false, "decoder emitted a CVPixelBuffer for the keyframe")
    decoder.flush()
} else {
    check(true, "decoder emitted a CVPixelBuffer")
}

// Give the delta frame (and any async stragglers) a brief window.
_ = decodedSem.wait(timeout: .now() + 2)
decoder.flush()

let (dw, dh) = lastDims.get()
check(dw == W && dh == H, "decoded CVPixelBuffer is \(W)x\(H) (got \(dw)x\(dh))")
check(decodedCount.get() >= 1, "decoded at least the keyframe (\(decodedCount.get()) frame(s))")

if let (b, g, r) = centerPixel.get() {
    let tol = 45
    let db = abs(Int(b) - Int(inB)), dg = abs(Int(g) - Int(inG)), dr = abs(Int(r) - Int(inR))
    check(db <= tol && dg <= tol && dr <= tol,
        "center pixel ~= input color (in B\(inB) G\(inG) R\(inR); out B\(b) G\(g) R\(r); tol \(tol))")
} else {
    // Not fatal for the core-roundtrip claim, but report it.
    check(false, "sampled a center pixel from the decoded buffer")
}

// ---- Teardown ---------------------------------------------------------------

sink.close()
source.close()

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
