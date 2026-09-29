import Foundation

package enum PeripheralLinkSnapshot: Sendable, Equatable {
    case connected
    case disconnected
    case connecting
    case disconnecting
}

package enum ConnectCancelConnectedOutcome: Sendable, Equatable {
    case completeConnect
    case reCancelWhilePending
}

package enum ConnectCancelTeardownOutcome: Sendable, Equatable {
    case ignore
    case reCancelWhilePending
    case clearedRetryConnect
}

package struct ConnectCancelCoordinator: Sendable {
    private(set) var cancelPending: Set<UUID> = []

    package init() {}

    package func isCancelPending(_ id: UUID) -> Bool {
        cancelPending.contains(id)
    }

    package mutating func markCancelPending(_ id: UUID) {
        cancelPending.insert(id)
    }

    package mutating func clearCancelPending(_ id: UUID) {
        cancelPending.remove(id)
    }

    package mutating func clearAllCancelPending() {
        cancelPending.removeAll()
    }

    package func connectedOutcome(for id: UUID) -> ConnectCancelConnectedOutcome {
        if cancelPending.contains(id) {
            return .reCancelWhilePending
        }
        return .completeConnect
    }

    package mutating func teardownOutcome(
        for id: UUID,
        snapshot: PeripheralLinkSnapshot,
    ) -> ConnectCancelTeardownOutcome {
        guard cancelPending.contains(id) else {
            return .ignore
        }
        switch snapshot {
        case .connected:
            return .reCancelWhilePending
        case .connecting, .disconnecting:
            return .ignore
        case .disconnected:
            cancelPending.remove(id)
            return .clearedRetryConnect
        }
    }
}
