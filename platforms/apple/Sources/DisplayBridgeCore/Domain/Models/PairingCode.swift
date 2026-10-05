import Foundation

/// The code a network sink must present before a source will stream to it or accept
/// its input. Generated once and persisted, so a sink only has to be told it once;
/// the CLI and the menu bar app share it.
public enum PairingCode {
    /// Shorter codes are refused: with 5 guesses a minute allowed, six digits already
    /// take months to guess, and anything shorter falls fast.
    public static let minimumLength = 6

    private static let defaults = UserDefaults(suiteName: "com.displaybridge") ?? .standard
    private static let key = "pairingCode"

    public static func current() -> String {
        if let code = defaults.string(forKey: key), !code.isEmpty {
            return code
        }
        return regenerate()
    }

    /// Replaces the code with one the user chose. Returns false (and changes nothing)
    /// if it is too short.
    @discardableResult
    public static func set(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count >= minimumLength else { return false }
        defaults.set(code, forKey: key)
        return true
    }

    /// Replaces the code with a fresh random one and returns it. Sinks that know the
    /// old code can no longer connect.
    @discardableResult
    public static func regenerate() -> String {
        // Int.random draws from the system CSPRNG.
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        defaults.set(code, forKey: key)
        return code
    }
}
