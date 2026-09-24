import Foundation

package protocol BluetoothPeripheral: Sendable {
    var currentState: BluetoothState { get async }
    /// Used only by the startup power wait. Running sessions read state changes from ``events``.
    var stateUpdates: AsyncStream<BluetoothState> { get async }
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
