import Foundation

/// Errors from ``BluetoothPeripheral`` conformers.
package enum BluetoothPeripheralError: Error, Sendable, Equatable {
    case notPoweredOn
    case serviceNotFound
    case characteristicNotFound
    /// `respond(to:with:value:)` was called with an id that has no outstanding request.
    case unknownRequest
    case addServiceFailed(serviceUUID: UUID, reason: String)
    case advertisingFailed(reason: String)
    /// A second `add` was issued while one was already in flight.
    case addInProgress
    /// A second `startAdvertising` was issued while one was already in flight.
    case advertisingInProgress
    /// The peripheral was deinitialized with continuations still pending.
    case peripheralInvalidated
}

/// Result for `respond(to:with:value:)`. `error(code:)` passes the raw ATT error byte through,
/// so application-specific codes (e.g. `0x80`/`0x81`) survive unchanged.
package enum ATTResult: Sendable, Equatable {
    case success
    case error(code: UInt8)
}

/// Abstraction over the peripheral (GATT server) role of a Bluetooth LE stack.
///
/// ``CoreBluetoothPeripheral`` is the production conformer; ``FakeBluetoothPeripheral`` is the
/// test double. Inbound traffic (power state, reads, writes, CCCD subscriptions, ready-to-update
/// signals) arrives in callback order on the single ``events`` stream. While not powered on,
/// `add`, `startAdvertising`, `updateValue`, and `respond` throw
/// ``BluetoothPeripheralError/notPoweredOn``.
package protocol BluetoothPeripheral: Sendable {
    var currentState: BluetoothState { get async }
    /// Used only by the startup power wait, before the session subscribes to ``events``. Once
    /// running, the session reads state changes from ``events`` instead.
    var stateUpdates: AsyncStream<BluetoothState> { get async }
    /// Incremented each time the state becomes something other than `.poweredOn`, in the same
    /// step that publishes the `.stateUpdated` event.
    var powerLossCount: Int { get async }

    /// At most one `add` may be in flight at a time; a second call throws `.addInProgress`.
    func add(_ service: PeripheralService) async throws
    func removeService(uuid: UUID) async throws

    /// At most one `startAdvertising` may be in flight at a time; a second call throws
    /// `.advertisingInProgress`.
    func startAdvertising(serviceUUIDs: [UUID]) async throws
    func stopAdvertising() async

    /// Inbound state changes, reads, writes, CCCD changes, and ready signals in arrival order.
    /// Does not replay; subscribe before issuing `add`/`startAdvertising` so no event is lost.
    var events: AsyncStream<PeripheralEvent> { get async }

    /// Completes one read or write transaction. Exactly one call per `requestID`/transaction id.
    func respond(
        to requestID: UUID,
        with result: ATTResult,
        value: Data?,
    ) async throws

    /// Notifies or indicates subscribed centrals. `nil` centralIDs targets every subscriber.
    ///
    /// - Returns: `false` when the transmit queue is full; the caller must wait for a
    ///   `.readyToUpdateSubscribers` event on ``events`` and retry the same payload.
    func updateValue(
        _ value: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        onSubscribedCentrals centralIDs: [UUID]?,
    ) async throws -> Bool
}
