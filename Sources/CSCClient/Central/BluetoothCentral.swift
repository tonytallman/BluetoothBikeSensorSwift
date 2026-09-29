import Foundation

package enum BluetoothState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

package enum BluetoothCentralError: Error, Sendable, Equatable {
    case peripheralNotFound(UUID)
    case notPoweredOn
    case connectionFailed(UUID, reason: String)
    case disconnected(UUID, reason: String?)
    case serviceNotFound(UUID, serviceUUID: UUID)
    case characteristicNotFound(UUID, serviceUUID: UUID, characteristicUUID: UUID)
    case attApplicationError(code: UInt8)
}

package struct DiscoveredPeripheral: Sendable, Equatable {
    package let id: UUID
    package let name: String?
    package let manufacturerData: Data?
    package let serviceUUIDs: [UUID]

    package init(
        id: UUID,
        name: String?,
        manufacturerData: Data?,
        serviceUUIDs: [UUID],
    ) {
        self.id = id
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
    }
}

package enum CentralEvent: Sendable, Equatable {
    case valueUpdated(peripheralID: UUID, serviceUUID: UUID, characteristicUUID: UUID, value: Data)
    case disconnected(peripheralID: UUID)
}

package protocol BluetoothCentral: Sendable {
    var stateUpdates: AsyncStream<BluetoothState> { get async }
    var currentState: BluetoothState { get async }

    /// Subscribes to ``stateUpdates`` and returns ``currentState`` in one central turn.
    func stateSubscriptionSnapshot() async -> (AsyncStream<BluetoothState>, BluetoothState)

    func startScanning(serviceUUIDs: [UUID]?) async
    func stopScanning() async

    var discoveries: AsyncStream<DiscoveredPeripheral> { get async }

    func connect(id: UUID) async throws
    func disconnect(id: UUID) async throws

    var events: AsyncStream<CentralEvent> { get async }

    func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws
    func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID]

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

    func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws
}
