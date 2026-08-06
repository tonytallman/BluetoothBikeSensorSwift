import Foundation

public enum BluetoothCentralError: Error, Sendable, Equatable {
    case peripheralNotFound(UUID)
    case notPoweredOn
    case connectionFailed(UUID, reason: String)
    case disconnected(UUID, reason: String?)
    case serviceNotFound(UUID, serviceUUID: UUID)
    case characteristicNotFound(UUID, serviceUUID: UUID, characteristicUUID: UUID)
}

public struct DiscoveredPeripheralEvent: Sendable, Equatable {
    public let id: UUID
    public let name: String?
    public let manufacturerData: Data?
    public let serviceUUIDs: [UUID]
    public let rssi: Int

    public init(
        id: UUID,
        name: String?,
        manufacturerData: Data?,
        serviceUUIDs: [UUID],
        rssi: Int
    ) {
        self.id = id
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.rssi = rssi
    }
}

public enum ConnectionEvent: Sendable, Equatable {
    case connected(id: UUID)
    case disconnected(id: UUID, reason: String?)
    case failed(id: UUID, reason: String)
}

public enum GATTEvent: Sendable, Equatable {
    case servicesDiscovered(id: UUID, serviceUUIDs: [UUID])
    case characteristicsDiscovered(id: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID])
    case characteristicValue(id: UUID, serviceUUID: UUID, characteristicUUID: UUID, value: Data)
    case notificationStateChanged(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool
    )
}
