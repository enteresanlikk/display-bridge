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

            // Connected clients
            if serverManager.connectedClients.isEmpty {
                Text("No clients connected")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connected Clients:")
                    .font(.caption.bold())
                ForEach(serverManager.connectedClients) { client in
                    HStack {
                        Image(systemName: "iphone")
                        Text(client.deviceName)
                        Spacer()
                        Text(client.id.uuidString.prefix(8))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
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

            Button("Open Window") {
                // Dispatch async so the menu dismisses first,
                // then activation policy change + window focus can take effect
                DispatchQueue.main.async {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showWindow()
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
