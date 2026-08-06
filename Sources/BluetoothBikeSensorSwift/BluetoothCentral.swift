import Foundation

package protocol BluetoothCentral: Sendable {
    var stateUpdates: AsyncStream<BluetoothState> { get async }
    var currentState: BluetoothState { get async }

    func startScanning(serviceUUIDs: [UUID]?) async
    func stopScanning() async

    var discoveries: AsyncStream<DiscoveredPeripheralEvent> { get async }

    func connect(id: UUID) async throws
    func disconnect(id: UUID) async throws

    var connectionEvents: AsyncStream<ConnectionEvent> { get async }

    func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws
    func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws

    var gattEvents: AsyncStream<GATTEvent> { get async }

    func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws

    func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data
}
