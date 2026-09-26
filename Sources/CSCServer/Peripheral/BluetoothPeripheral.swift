import Foundation

package enum BluetoothPeripheralError: Error, Sendable, Equatable {
    case notPoweredOn
    case serviceNotFound
    case characteristicNotFound
    case unknownRequest
    case addServiceFailed(serviceUUID: UUID, reason: String)
    case advertisingFailed(reason: String)
    case conflictingProperties
    case cachedValueNotReadOnly
    case addInProgress
    case advertisingInProgress
    case missingReadValue
    case unexpectedResponseValue
    case peripheralInvalidated
}

package enum ATTResult: Sendable, Equatable {
    case success
    case error(code: UInt8)
}

package protocol BluetoothPeripheral: Sendable {
    var currentState: BluetoothState { get async }
    /// Used only by the startup power wait. Running sessions read state changes from ``events``.
    var stateUpdates: AsyncStream<BluetoothState> { get async }
    /// Incremented each time the state becomes something other than `.poweredOn`, in the same
    /// step that publishes the `.stateUpdated` event.
    var powerLossCount: Int { get async }
    var isAdvertising: Bool { get async }

    func add(_ service: PeripheralService) async throws
    func removeService(uuid: UUID) async throws
    func removeAllServices() async

    func startAdvertising(_ advertisement: Advertisement) async throws
    func stopAdvertising() async

    /// Inbound state changes, reads, writes, CCCD changes, and ready signals in arrival order.
    var events: AsyncStream<PeripheralEvent> { get async }

    func respond(
        to requestID: UUID,
        with result: ATTResult,
        value: Data?,
    ) async throws

    func updateValue(
        _ value: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        onSubscribedCentrals centralIDs: [UUID]?,
    ) async throws -> Bool
}
