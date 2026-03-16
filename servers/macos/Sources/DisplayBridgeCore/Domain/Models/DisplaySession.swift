import Foundation

public enum SessionState: Sendable {
    case idle
    case connecting
    case negotiating
    case streaming
    case disconnected
}

public struct DisplaySession: Sendable {
    public let id: UUID
    public private(set) var config: DeviceConfig
    public private(set) var state: SessionState

    public init(id: UUID = UUID(), config: DeviceConfig, state: SessionState = .idle) {
        self.id = id
        self.config = config
        self.state = state
    }

    public mutating func transition(to newState: SessionState) {
        self.state = newState
    }

    public mutating func updateConfig(_ newConfig: DeviceConfig) {
        self.config = newConfig
    }
}
