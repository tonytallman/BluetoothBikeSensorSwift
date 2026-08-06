import Foundation

package enum BluetoothCentralError: Error, Sendable, Equatable {
    case peripheralNotFound(UUID)
    case notPoweredOn
    case connectionFailed(UUID, reason: String)
    case disconnected(UUID, reason: String?)
    case serviceNotFound(UUID, serviceUUID: UUID)
    case characteristicNotFound(UUID, serviceUUID: UUID, characteristicUUID: UUID)
}

package struct DiscoveredPeripheralEvent: Sendable, Equatable {
    package let id: UUID
    package let name: String?
    package let manufacturerData: Data?
    package let serviceUUIDs: [UUID]
    package let rssi: Int

    package init(
        id: UUID,
        name: String?,
        manufacturerData: Data?,
        serviceUUIDs: [UUID],
        rssi: Int,
    ) {
        self.id = id
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.rssi = rssi
    }
}

package enum ConnectionEvent: Sendable, Equatable {
    case connected(id: UUID)
    case disconnected(id: UUID, reason: String?)
    case failed(id: UUID, reason: String)
}

package enum GATTEvent: Sendable, Equatable {
    case servicesDiscovered(id: UUID, serviceUUIDs: [UUID])
    case characteristicsDiscovered(id: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID])
    case characteristicValue(id: UUID, serviceUUID: UUID, characteristicUUID: UUID, value: Data)
    case notificationStateChanged(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool,
    )
}
