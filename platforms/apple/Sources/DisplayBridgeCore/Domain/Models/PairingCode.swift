import Foundation

/// The code a network sink must present before a source will stream to it or accept
/// its input. Generated once and persisted, so a sink only has to be told it once;
/// the CLI and the menu bar app share it.
public enum PairingCode {
    public static func current() -> String {
        let defaults = UserDefaults(suiteName: "com.displaybridge") ?? .standard
        if let code = defaults.string(forKey: "pairingCode"), !code.isEmpty {
            return code
        }
        // Int.random draws from the system CSPRNG.
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        defaults.set(code, forKey: "pairingCode")
        return code
    }
}
