import Foundation

/// Conditions `Server`/`ServerSession` test hooks can block on via `waitUntil(_:)`, so tests
/// synchronize on internal state deterministically instead of sleeping or polling.
///
/// `Server.waitUntil(_:)` and `ServerLifecycle.waitUntil(_:)` are no-ops unless the session is
/// `.running`; ``ServerSession/waitUntil(_:)`` is the one that actually evaluates these.
package enum ServerTestCondition: Sendable {
    case measurementSubscribers(Set<UUID>)
    case controlPointSubscribers(Set<UUID>)
    case acceptedMeasurementCount(atLeast: Int)
    case outboundCount(atLeast: Int)
    case readyToUpdateWaiterParked
    case controlPointProcedureIdle
    /// Whether some waiter is currently parked on a `.measurementSubscribers` condition — used
    /// to synchronize with the outbound-pump-adjacent subscriber logic rather than the
    /// subscriber set's value itself.
    case measurementSubscriberWaiterParked
    case bluetoothRecoveryIdle

    /// Whether a closed session should be treated as satisfying this condition, so a test that
    /// raced shutdown does not park forever on a value `close()` may settle only later (e.g. the
    /// subscriber sets are cleared in `tearDown(stoppingAdvertising:)`, after `beginShutdown()`
    /// already resumed waiters). The three cases returning `false` are excluded deliberately —
    /// they describe activity (an in-progress procedure, a parked subscriber waiter, an
    /// in-progress recovery) that a test may specifically be waiting to see settle, so shutdown
    /// does not short-circuit them.
    var isSatisfiedByClose: Bool {
        switch self {
        case .measurementSubscribers,
             .controlPointSubscribers,
             .acceptedMeasurementCount,
             .outboundCount,
             .readyToUpdateWaiterParked:
            return true
        case .controlPointProcedureIdle,
             .measurementSubscriberWaiterParked,
             .bluetoothRecoveryIdle:
            return false
        }
    }
}
