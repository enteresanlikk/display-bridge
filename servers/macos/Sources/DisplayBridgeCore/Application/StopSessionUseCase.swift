import Foundation

public struct StopSessionUseCase: Sendable {
    private let coordinator: SessionCoordinator

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    public func execute() async {
        await coordinator.stopSession()
    }
}
