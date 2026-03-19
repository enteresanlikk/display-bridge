import Foundation

/// Client → Server handshake request matching PROTOCOL.md format.
public struct HandshakeRequest: Codable, Sendable {
    public let clientPlatform: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let refreshRate: Int
    public let supportedCodecs: [String]
    public let protocolVersion: Int

    public init(
        clientPlatform: String,
        screenWidth: Int,
        screenHeight: Int,
        refreshRate: Int,
        supportedCodecs: [String],
        protocolVersion: Int = 1
    ) {
        self.clientPlatform = clientPlatform
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.refreshRate = refreshRate
        self.supportedCodecs = supportedCodecs
        self.protocolVersion = protocolVersion
    }
}

/// Server → Client handshake acknowledgment matching PROTOCOL.md format.
public struct HandshakeAck: Codable, Sendable {
    public let accepted: Bool
    public let negotiatedWidth: Int
    public let negotiatedHeight: Int
    public let negotiatedRefreshRate: Int
    public let codec: String
    public let bitrate: Int
    public let protocolVersion: Int

    public init(
        accepted: Bool,
        negotiatedWidth: Int,
        negotiatedHeight: Int,
        negotiatedRefreshRate: Int,
        codec: String,
        bitrate: Int,
        protocolVersion: Int = 1
    ) {
        self.accepted = accepted
        self.negotiatedWidth = negotiatedWidth
        self.negotiatedHeight = negotiatedHeight
        self.negotiatedRefreshRate = negotiatedRefreshRate
        self.codec = codec
        self.bitrate = bitrate
        self.protocolVersion = protocolVersion
    }
}
