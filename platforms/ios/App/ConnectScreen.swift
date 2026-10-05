import DisplayBridgeCore
import SwiftUI

/// Where to connect: sources found on the network, or an address typed by hand.
struct ConnectScreen: View {
    @EnvironmentObject private var model: SinkModel

    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 7878
    @AppStorage("pairingCode") private var pairingCode = ""

    var body: some View {
        Form {
            Section("Found on this network") {
                if model.sources.isEmpty {
                    Text("Looking for a DisplayBridge server…")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    Button("\(source.name)  (\(source.host):\(String(source.port)))") {
                        host = source.host
                        port = Int(source.port)
                    }
                }
            }

            Section("Server") {
                TextField("Host", text: $host)
                    .autocorrectionDisabled()
                    .addressKeyboard()
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .numberKeyboard()
                TextField("Pairing code (shown on the server)", text: $pairingCode)
                    .autocorrectionDisabled()
                    .addressKeyboard()
            }

            Section {
                Button("Connect") {
                    model.connect(host: host, port: UInt16(clamping: port), pairingCode: pairingCode)
                }
                .disabled(host.isEmpty)
                if !model.status.isEmpty {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.startBrowsing() }
        .onDisappear { model.stopBrowsing() }
    }
}

private extension View {
    /// No capital letters or word suggestions while typing an address or a code.
    func addressKeyboard() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        return self
        #endif
    }

    func numberKeyboard() -> some View {
        #if os(iOS)
        return keyboardType(.numberPad)
        #else
        return self
        #endif
    }
}
