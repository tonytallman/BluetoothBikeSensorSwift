import Foundation

/// `CBPeripheral.state` reduced to the four values cancel-teardown cares about, taken on the
/// manager queue so the actor can branch without reading CoreBluetooth.
package enum PeripheralLinkSnapshot: Sendable, Equatable {
    case connected
    case disconnected
    case connecting
    case disconnecting
}

/// What ``CoreBluetoothCentral`` should do when `didConnect` arrives.
package enum ConnectCancelConnectedOutcome: Sendable, Equatable {
    /// No cancel is outstanding. Complete the in-flight connect if this id is still the one
    /// `CBCentralManager.connect` was called for.
    case completeConnect
    /// A cancel is outstanding and the link came up anyway. Cancel it again. Do not complete
    /// a waiter: the cancelled connect has already failed, and a replacement connect must wait
    /// until the link is actually down.
    case reCancelWhilePending
}

/// What ``CoreBluetoothCentral`` should do when `didFailToConnect` or `didDisconnect` arrives
/// for an id whose cancel is still outstanding.
package enum ConnectCancelTeardownOutcome: Sendable, Equatable {
    /// This id is not pending cancel, or the link is still `.connecting` / `.disconnecting`.
    /// Leave the flag set and wait for a later callback. `.connecting` and `.disconnecting`
    /// are not terminal, so clearing the flag here would let a new connect race the teardown.
    case ignore
    /// The callback says the peripheral is `.connected` while a cancel is outstanding. Cancel
    /// again. A stale failure must not clear the flag while the link is up.
    case reCancelWhilePending
    /// The link is `.disconnected`. The flag was cleared. If a replacement connect is waiting,
    /// it may call `connect` now.
    case clearedRetryConnect
}

/// Tracks peripherals whose connect was cancelled before the link reached `.disconnected`.
///
/// ``CoreBluetoothCentral/cancelConnect(id:)`` fails the waiting caller immediately, then sets
/// this flag if the radio still has to tear the link down. While the flag is set, a
/// `didConnect` is not success, and a replacement ``BluetoothCentral/connect(id:)`` does not
/// start until ``teardownOutcome(for:snapshot:)`` reports ``ConnectCancelTeardownOutcome/clearedRetryConnect``.
/// The flag is per peripheral. ``clearAllCancelPending()`` drops every id when Bluetooth
/// leaves the powered-on states that can still complete a connect.
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

    /// `didConnect` while the flag is set must cancel again. Otherwise the connect may complete.
    package func connectedOutcome(for id: UUID) -> ConnectCancelConnectedOutcome {
        if cancelPending.contains(id) {
            return .reCancelWhilePending
        }
        return .completeConnect
    }

    /// Decides how a fail-to-connect or disconnect callback interacts with an outstanding cancel.
    /// Only ``PeripheralLinkSnapshot/disconnected`` clears the flag.
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
