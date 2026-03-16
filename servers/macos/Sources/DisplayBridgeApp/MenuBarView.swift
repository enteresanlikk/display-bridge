import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(serverManager.isRunning ? "Running on port \(String(serverManager.port))" : "Stopped")
            }

            Divider()

            // Start/Stop
            Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                Task {
                    if serverManager.isRunning {
                        await serverManager.stopServer()
                    } else {
                        await serverManager.startServer()
                    }
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }
}
