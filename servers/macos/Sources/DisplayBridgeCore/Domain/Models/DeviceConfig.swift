import Foundation

public enum VideoCodec: String, Codable, Sendable {
    case hevc
    case h264
}

public enum ColorSpace: String, Codable, Sendable {
    case p3
    case sRGB = "srgb"
}

public struct DeviceConfig: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let refreshRate: Int
    public let codec: VideoCodec
    public let colorSpace: ColorSpace
    public let deviceName: String?

    public init(width: Int, height: Int, refreshRate: Int, codec: VideoCodec, colorSpace: ColorSpace, deviceName: String? = nil) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.codec = codec
        self.colorSpace = colorSpace
        self.deviceName = deviceName
    }
}
