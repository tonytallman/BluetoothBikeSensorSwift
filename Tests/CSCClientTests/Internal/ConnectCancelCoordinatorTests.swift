import CSCClient
import Foundation
import Testing

@Suite struct ConnectCancelCoordinatorTests {
    @Test func connectedWhileCancelPendingRequestsReCancel() {
        var coordinator = ConnectCancelCoordinator()
        let id = UUID()
        coordinator.markCancelPending(id)

        #expect(coordinator.connectedOutcome(for: id) == .reCancelWhilePending)
    }

    @Test func connectedWithoutCancelPendingCompletes() {
        let coordinator = ConnectCancelCoordinator()
        let id = UUID()

        #expect(coordinator.connectedOutcome(for: id) == .completeConnect)
    }

    @Test func teardownWhileConnectedKeepsCancelPending() {
        var coordinator = ConnectCancelCoordinator()
        let id = UUID()
        coordinator.markCancelPending(id)

        let outcome = coordinator.teardownOutcome(for: id, snapshot: .connected)
        #expect(outcome == .reCancelWhilePending)
        #expect(coordinator.isCancelPending(id))
    }

    @Test func teardownWhileConnectingDoesNotClearCancelPending() {
        var coordinator = ConnectCancelCoordinator()
        let id = UUID()
        coordinator.markCancelPending(id)

        let outcome = coordinator.teardownOutcome(for: id, snapshot: .connecting)
        #expect(outcome == .ignore)
        #expect(coordinator.isCancelPending(id))
    }

    @Test func teardownWhileDisconnectedClearsAndRetries() {
        var coordinator = ConnectCancelCoordinator()
        let id = UUID()
        coordinator.markCancelPending(id)

        let outcome = coordinator.teardownOutcome(for: id, snapshot: .disconnected)
        #expect(outcome == .clearedRetryConnect)
        #expect(!coordinator.isCancelPending(id))
    }

    @Test func clearAllCancelPendingRemovesEveryId() {
        var coordinator = ConnectCancelCoordinator()
        let first = UUID()
        let second = UUID()
        coordinator.markCancelPending(first)
        coordinator.markCancelPending(second)

        coordinator.clearAllCancelPending()

        #expect(!coordinator.isCancelPending(first))
        #expect(!coordinator.isCancelPending(second))
    }
}
