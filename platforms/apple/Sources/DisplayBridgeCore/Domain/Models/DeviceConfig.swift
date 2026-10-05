import Foundation

public enum VideoCodec: String, Codable, Sendable {
    case hevc
    case h264
}

public struct DeviceConfig: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let refreshRate: Int
    public let codec: VideoCodec
    public let deviceName: String?

    public init(width: Int, height: Int, refreshRate: Int, codec: VideoCodec, deviceName: String? = nil) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.codec = codec
        self.deviceName = deviceName
    }
}
