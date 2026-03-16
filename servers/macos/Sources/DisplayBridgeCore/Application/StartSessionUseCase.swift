import Foundation

public struct StartSessionUseCase: Sendable {
    private let coordinator: SessionCoordinator

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    public func execute(config: DeviceConfig) async throws {
        try await coordinator.startSession(config: config)
    }
}
