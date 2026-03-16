import Foundation

public enum NegotiateConfigError: Error, Sendable {
    case invalidJSON
    case unsupportedResolution(width: Int, height: Int)
    case unsupportedRefreshRate(Int)
    case unsupportedCodec(String)
}

public struct NegotiateConfigUseCase: Sendable {
    private static let maxWidth = 3840
    private static let maxHeight = 2160
    private static let supportedRefreshRates = [30, 60, 90, 120]

    public init() {}

    public func execute(handshakeData: Data) throws -> DeviceConfig {
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(DeviceConfig.self, from: handshakeData) else {
            throw NegotiateConfigError.invalidJSON
        }

        guard config.width > 0, config.width <= Self.maxWidth,
              config.height > 0, config.height <= Self.maxHeight else {
            throw NegotiateConfigError.unsupportedResolution(width: config.width, height: config.height)
        }

        guard Self.supportedRefreshRates.contains(config.refreshRate) else {
            throw NegotiateConfigError.unsupportedRefreshRate(config.refreshRate)
        }

        return config
    }
}
