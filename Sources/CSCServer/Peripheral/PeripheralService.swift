import Foundation

package struct CharacteristicProperties: OptionSet, Sendable, Equatable {
    package let rawValue: UInt

    package init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    package static let read = CharacteristicProperties(rawValue: 1 << 0)
    package static let write = CharacteristicProperties(rawValue: 1 << 1)
    package static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)
    package static let notify = CharacteristicProperties(rawValue: 1 << 3)
    package static let indicate = CharacteristicProperties(rawValue: 1 << 4)
}

package struct CharacteristicPermissions: OptionSet, Sendable, Equatable {
    package let rawValue: UInt

    package init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    package static let readable = CharacteristicPermissions(rawValue: 1 << 0)
    package static let writeable = CharacteristicPermissions(rawValue: 1 << 1)
}

package struct PeripheralCharacteristic: Sendable, Equatable {
    package let uuid: UUID
    package let properties: CharacteristicProperties
    package let permissions: CharacteristicPermissions
    package let value: Data?

    package init(
        uuid: UUID,
        properties: CharacteristicProperties,
        permissions: CharacteristicPermissions,
        value: Data?,
    ) {
        self.uuid = uuid
        self.properties = properties
        self.permissions = permissions
        self.value = value
    }
}

package struct PeripheralService: Sendable, Equatable {
    package let uuid: UUID
    package let isPrimary: Bool
    package let characteristics: [PeripheralCharacteristic]

    package init(
        uuid: UUID,
        isPrimary: Bool,
        characteristics: [PeripheralCharacteristic],
    ) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

package struct Advertisement: Sendable, Equatable {
    package let localName: String?
    package let serviceUUIDs: [UUID]

    package init(localName: String?, serviceUUIDs: [UUID]) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
    }
}

enum PeripheralServiceValidation {
    static func validate(_ service: PeripheralService) throws {
        for characteristic in service.characteristics {
            if characteristic.properties.contains(.write),
               characteristic.properties.contains(.writeWithoutResponse)
            {
                throw BluetoothPeripheralError.conflictingProperties
            }
            if characteristic.properties.contains(.notify),
               characteristic.properties.contains(.indicate)
            {
                throw BluetoothPeripheralError.conflictingProperties
            }
            if characteristic.value != nil {
                let isReadOnlyReadable = characteristic.properties == [.read]
                    && characteristic.permissions == [.readable]
                if !isReadOnlyReadable {
                    throw BluetoothPeripheralError.cachedValueNotReadOnly
                }
            }
        }
    }
}
