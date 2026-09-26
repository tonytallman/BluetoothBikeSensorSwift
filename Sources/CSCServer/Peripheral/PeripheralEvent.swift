import Foundation

package struct PeripheralReadRequest: Sendable, Equatable {
    package let id: UUID
    package let centralID: UUID
    package let serviceUUID: UUID
    package let characteristicUUID: UUID
    package let offset: Int

    package init(
        id: UUID,
        centralID: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        offset: Int,
    ) {
        self.id = id
        self.centralID = centralID
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.offset = offset
    }
}

package struct PeripheralWriteRequest: Sendable, Equatable {
    package let centralID: UUID
    package let serviceUUID: UUID
    package let characteristicUUID: UUID
    package let offset: Int
    package let value: Data

    package init(
        centralID: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        offset: Int,
        value: Data,
    ) {
        self.centralID = centralID
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.offset = offset
        self.value = value
    }
}

package struct PeripheralWriteTransaction: Sendable, Equatable {
    package let id: UUID
    package let requests: [PeripheralWriteRequest]

    package init(id: UUID, requests: [PeripheralWriteRequest]) {
        self.id = id
        self.requests = requests
    }
}

package enum SubscriptionChange: Sendable, Equatable {
    case subscribed(centralID: UUID, serviceUUID: UUID, characteristicUUID: UUID)
    case unsubscribed(centralID: UUID, serviceUUID: UUID, characteristicUUID: UUID)
}

/// One inbound peripheral event, delivered in the order the peripheral observed it.
package enum PeripheralEvent: Sendable, Equatable {
    case stateUpdated(BluetoothState)
    case read(PeripheralReadRequest)
    case writeTransaction(PeripheralWriteTransaction)
    case subscription(SubscriptionChange)
    case readyToUpdateSubscribers
}
