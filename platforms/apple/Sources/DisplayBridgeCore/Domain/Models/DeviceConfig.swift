import Foundation

public enum VideoCodec: String, Codable, Sendable {
    case hevc
    case h264
}

/// What a sink runs on. Mirrors the Rust `Platform`; the raw values are the wire names.
public enum ClientPlatform: String, Codable, Sendable {
    case macos, windows, linux, android, ios, ipados

    /// The name to show a person.
    public var displayName: String {
        switch self {
        case .macos: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .android: return "Android"
        case .ios: return "iOS"
        case .ipados: return "iPadOS"
        }
    }
}

public struct DeviceConfig: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let refreshRate: Int
    public let codec: VideoCodec
    public let deviceName: String?
    /// What the sink runs on; nil when it did not say. A sink can leave it nil: the core
    /// reports the platform it was built for.
    public let platform: ClientPlatform?

    public init(width: Int, height: Int, refreshRate: Int, codec: VideoCodec, deviceName: String? = nil, platform: ClientPlatform? = nil) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.codec = codec
        self.deviceName = deviceName
        self.platform = platform
    }
}
