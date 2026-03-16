import Foundation
import SwiftUI
import DisplayBridgeCore

@MainActor
final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var connectedClients: [ClientInfo] = []
    @Published var port: UInt16 = 7878
    @Published var errorMessage: String?

    private var engine: ServerEngine?

    struct ClientInfo: Identifiable {
        let id: UUID
        let deviceName: String
        let connectedAt: Date
    }

    func startServer() async {
        guard !isRunning else { return }
        errorMessage = nil

        let eng = ServerEngine(port: port)

        eng.onStateChanged = { [weak self] running in
            guard let self else { return }
            Task { @MainActor in
                self.isRunning = running
            }
        }

        eng.onClientConnected = { [weak self] clientID, deviceName in
            guard let self else { return }
            Task { @MainActor in
                let info = ClientInfo(id: clientID, deviceName: deviceName, connectedAt: Date())
                self.connectedClients.append(info)
            }
        }

        eng.onClientDisconnected = { [weak self] clientID in
            guard let self else { return }
            Task { @MainActor in
                self.connectedClients.removeAll { $0.id == clientID }
            }
        }

        eng.onError = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.errorMessage = message
            }
        }

        engine = eng

        let config = DeviceConfig(
            width: 2960,
            height: 1848,
            refreshRate: 120,
            codec: .hevc,
            colorSpace: .p3
        )

        await eng.start(defaultConfig: config)
    }

    func disconnectClient(_ id: UUID) async {
        await engine?.disconnectClient(id)
    }

    func stopServer() async {
        await engine?.stop()
        engine = nil
        connectedClients.removeAll()
    }
}
