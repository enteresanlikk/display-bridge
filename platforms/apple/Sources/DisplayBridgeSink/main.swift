// Launches this Mac as a SINK: it dials a remote source, receives its encoded screen,
// decodes it in hardware, and shows it in a window. Mouse and trackpad input over the
// window is sent back to the source. Pass --headless to only log decoded-frame stats.
//
//   swift run DisplayBridgeSink --host 192.168.1.42 --port 7878 --pairing-code 123456
//
import AppKit
import CoreVideo
import Foundation
import DisplayBridgeCore

// ---- Arg parsing ------------------------------------------------------------

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let host = argValue("--host") ?? "127.0.0.1"
let port = UInt16(argValue("--port") ?? "7878") ?? 7878
let width = Int(argValue("--width") ?? "1280") ?? 1280
let height = Int(argValue("--height") ?? "720") ?? 720
let refresh = Int(argValue("--refresh") ?? "60") ?? 60
let pairingCode = argValue("--pairing-code")
let headless = CommandLine.arguments.contains("--headless")
let codec: VideoCodec = (argValue("--codec") ?? "hevc").lowercased() == "h264" ? .h264 : .hevc

let config = DeviceConfig(width: width, height: height, refreshRate: refresh, codec: codec, deviceName: "Mac Sink")

// ---- Decoded-frame stats ----------------------------------------------------

final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastLog = Date()
    private var lastW = 0
    private var lastH = 0

    func record(_ pb: CVPixelBuffer) {
        lock.lock()
        count += 1
        lastW = CVPixelBufferGetWidth(pb)
        lastH = CVPixelBufferGetHeight(pb)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastLog)
        if elapsed >= 1.0 {
            let fps = Double(count) / elapsed
            print(String(format: "[DisplayBridgeSink] %.1f fps  %dx%d", fps, lastW, lastH))
            count = 0
            lastLog = now
        }
        lock.unlock()
    }
}

let stats = FrameStats()
let decoder = VideoToolboxDecoder(codec: codec) { pixelBuffer, _ in
    stats.record(pixelBuffer)
}

let view: DisplaySinkView? = headless ? nil : DisplaySinkView(
    frame: NSRect(x: 0, y: 0, width: width / 2, height: height / 2)
)

let coordinator = SinkCoordinator(
    decoder: decoder,
    onFrame: { [weak view] pixelBuffer, timestamp in
        stats.record(pixelBuffer)
        view?.enqueue(pixelBuffer, timestampMicros: timestamp)
    },
    onStateChange: { state in print("[DisplayBridgeSink] state -> \(state)") },
    onError: { message in print("[DisplayBridgeSink] Source refused: \(message)") }
)

print("[DisplayBridgeSink] Connecting to \(host):\(port) as \(width)x\(height)@\(refresh) \(codec)...")

do {
    try coordinator.start(host: host, port: port, config: config, pairingCode: pairingCode)
} catch {
    print("[DisplayBridgeSink] Failed to start: \(error)")
    exit(1)
}

print("[DisplayBridgeSink] Connected. Receiving frames (Ctrl-C to stop)...")

// Park the main thread; the Rust reader thread drives decode callbacks.
signal(SIGINT) { _ in
    print("\n[DisplayBridgeSink] Stopping...")
    exit(0)
}
guard let view else {
    RunLoop.main.run()
    exit(0)
}

view.onInput = { coordinator.sendInput($0) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: view.frame,
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false
)
window.title = "DisplayBridge — \(host)"
window.contentView = view
window.contentAspectRatio = NSSize(width: width, height: height)
window.collectionBehavior = [.fullScreenPrimary]
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)

NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: window, queue: .main
) { _ in
    coordinator.stop()
    exit(0)
}

app.activate(ignoringOtherApps: true)
app.run()
