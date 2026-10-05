import DisplayBridgeCore
import SwiftUI

/// Owns the connection to a source and the surface its picture is drawn on.
///
/// `@unchecked Sendable`: the published state is only touched on the main thread; the
/// session's callbacks arrive on the core's threads and hop there first.
final class SinkModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var isStreaming = false
    @Published private(set) var status = ""
    @Published private(set) var sources: [DiscoveredSource] = []

    /// The view the stream is rendered into; `StreamScreen` puts it on screen.
    let surface = DisplaySinkView(frame: .zero)

    private var coordinator: SinkCoordinator?
    private var browser: SourceBrowser?

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = SourceBrowser { [weak self] in self?.sources = $0 }
        self.browser = browser
        browser.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    // MARK: - Session

    func connect(host: String, port: UInt16, pairingCode: String) {
        disconnect()
        status = "Connecting to \(host)…"

        let screen = Self.screen()
        let config = DeviceConfig(
            width: screen.width, height: screen.height, refreshRate: screen.refreshRate,
            codec: .hevc, deviceName: screen.name
        )
        let surface = self.surface
        let coordinator = SinkCoordinator(
            decoder: VideoToolboxDecoder(codec: .hevc) { _, _ in },
            onFrame: { [weak surface] pixelBuffer, timestamp in
                surface?.enqueue(pixelBuffer, timestampMicros: timestamp)
            },
            onStateChange: { [weak self] state in
                DispatchQueue.main.async { self?.sessionChanged(to: state) }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async { self?.status = message }
            }
        )
        surface.onInput = { [weak coordinator] event in
            _ = coordinator?.sendInput(event)
        }
        self.coordinator = coordinator

        // Dialing blocks until the socket is up or the attempt fails: keep it off the UI.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try coordinator.start(
                    host: host, port: port, config: config,
                    pairingCode: pairingCode.isEmpty ? nil : pairingCode
                )
            } catch {
                DispatchQueue.main.async {
                    self?.status = "Could not connect to \(host):\(port)"
                    self?.coordinator = nil
                }
            }
        }
    }

    func disconnect() {
        coordinator?.stop()
        coordinator = nil
        isStreaming = false
        Self.keepAwake(false)
    }

    private func sessionChanged(to state: SessionState) {
        switch state {
        case .streaming:
            status = ""
            isStreaming = true
            Self.keepAwake(true)
        case .disconnected:
            // Keep a refusal message (wrong pairing code) on screen; otherwise say why we are back.
            if status.isEmpty || status.hasPrefix("Connecting") { status = "Disconnected" }
            disconnect()
        default:
            break
        }
    }

    // MARK: - Device

    /// The display to ask the source for: this screen, in landscape, at its native pixels.
    private static func screen() -> (width: Int, height: Int, refreshRate: Int, name: String) {
        #if os(iOS)
        let pixels = UIScreen.main.nativeBounds.size // always portrait-up
        return (
            Int(max(pixels.width, pixels.height)), Int(min(pixels.width, pixels.height)),
            UIScreen.main.maximumFramesPerSecond, UIDevice.current.name
        )
        #else
        return (1920, 1080, 60, "Sink")
        #endif
    }

    /// A monitor must not dim or lock while it is showing something.
    private static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
