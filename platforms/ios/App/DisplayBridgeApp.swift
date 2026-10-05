import SwiftUI

/// DisplayBridge for iPhone and iPad: turns the device into a second monitor (a sink).
/// Everything that is not screen layout lives in DisplayBridgeCore, shared with the Mac.
@main
struct DisplayBridgeApp: App {
    @StateObject private var model = SinkModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isStreaming {
                    StreamScreen()
                } else {
                    ConnectScreen()
                }
            }
            .environmentObject(model)
        }
    }
}
