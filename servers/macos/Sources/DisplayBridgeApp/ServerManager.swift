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
        let transportType: String  // "USB" or "Network"
        let width: Int
        let height: Int
        let refreshRate: Int
        var sentFPS: Double = 0
        var avgLatencyMs: Double = 0
        var droppedPercent: Double = 0
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

        eng.onClientConnected = { [weak self] clientID, deviceName, transportType, width, height, refreshRate in
            guard let self else { return }
            Task { @MainActor in
                let info = ClientInfo(id: clientID, deviceName: deviceName, transportType: transportType, width: width, height: height, refreshRate: refreshRate)
                self.connectedClients.append(info)
            }
        }

        eng.onClientDisconnected = { [weak self] clientID in
            guard let self else { return }
            Task { @MainActor in
                self.connectedClients.removeAll { $0.id == clientID }
            }
        }

        eng.onClientStatsUpdated = { [weak self] clientID, stats in
            guard let self else { return }
            Task { @MainActor in
                if let idx = self.connectedClients.firstIndex(where: { $0.id == clientID }) {
                    self.connectedClients[idx].sentFPS = stats.sentFPS
                    self.connectedClients[idx].avgLatencyMs = stats.avgLatencyMs
                    self.connectedClients[idx].droppedPercent = stats.droppedPercent
                }
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
            codec: .hevc
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
