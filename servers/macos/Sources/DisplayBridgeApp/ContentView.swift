import SwiftUI
import Network

struct ContentView: View {
    @EnvironmentObject var serverManager: ServerManager

    @State private var editablePort: String = "7878"
    @State private var localAddresses: [NetworkAddress] = allNetworkAddresses()
    @State private var pathMonitor: NWPathMonitor?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display")
                    .font(.title2)
                Text("DisplayBridge")
                    .font(.title2.bold())
                Spacer()
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(serverManager.isRunning ? "Running" : "Stopped")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Server Control
            GroupBox("Server") {
                VStack(spacing: 8) {
                    HStack {
                        Text("Port:")
                        TextField("Port", text: $editablePort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(serverManager.isRunning)

                        Spacer()

                        Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                            Task {
                                if serverManager.isRunning {
                                    await serverManager.stopServer()
                                } else {
                                    if let p = UInt16(editablePort) {
                                        serverManager.port = p
                                    }
                                    await serverManager.startServer()
                                }
                            }
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(serverManager.isRunning ? .red : .accentColor)
                    }

                    if serverManager.isRunning {
                        ForEach(localAddresses) { addr in
                            HStack {
                                Image(systemName: "network")
                                    .foregroundStyle(.green)
                                Text("\(addr.name):")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                Text("\(addr.ip):\(String(serverManager.port))")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(addr.ip, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy IP")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Error message
            if let error = serverManager.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Connected Clients
            GroupBox("Connected Clients (\(serverManager.connectedClients.count))") {
                if serverManager.connectedClients.isEmpty {
                    Text("No clients connected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(serverManager.connectedClients) { client in
                            HStack {
                                Image(systemName: client.transportType == "USB" ? "cable.connector" : "wifi")
                                    .foregroundStyle(client.transportType == "USB" ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(client.deviceName)
                                            .font(.body)
                                        Text(client.transportType)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(client.transportType == "USB" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                            .foregroundStyle(client.transportType == "USB" ? .orange : .blue)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                    HStack(spacing: 8) {
                                        Text(client.connectedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if client.sentFPS > 0 {
                                            Text("\(Int(client.sentFPS)) fps")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.green)
                                            Text(String(format: "%.1fms", client.avgLatencyMs))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(client.avgLatencyMs < 8 ? .blue : .orange)
                                        }
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task {
                                        await serverManager.disconnectClient(client.id)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Disconnect")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()
        }
        .onAppear {
            editablePort = String(serverManager.port)
            localAddresses = allNetworkAddresses()
            startNetworkMonitor()
        }
        .onDisappear {
            pathMonitor?.cancel()
            pathMonitor = nil
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            DispatchQueue.main.async {
                localAddresses = allNetworkAddresses()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }
}

struct NetworkAddress: Identifiable {
    let name: String
    let ip: String
    var id: String { "\(name)-\(ip)" }
}

/// Returns all local IPv4 network addresses (excluding loopback).
private func allNetworkAddresses() -> [NetworkAddress] {
    var results: [NetworkAddress] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family
        guard addrFamily == UInt8(AF_INET) else { continue }

        let name = String(cString: interface.ifa_name)
        guard name != "lo0" else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(
            interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
            &hostname, socklen_t(hostname.count),
            nil, 0, NI_NUMERICHOST
        )
        let ip = String(cString: hostname)
        results.append(NetworkAddress(name: name, ip: ip))
    }
    return results
}
