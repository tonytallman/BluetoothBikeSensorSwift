import Foundation

package struct CharacteristicProperties: OptionSet, Sendable, Equatable {
    package let rawValue: UInt

    package init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    package static let read = CharacteristicProperties(rawValue: 1 << 0)
    package static let write = CharacteristicProperties(rawValue: 1 << 1)
    package static let notify = CharacteristicProperties(rawValue: 1 << 2)
    package static let indicate = CharacteristicProperties(rawValue: 1 << 3)
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
    package let characteristics: [PeripheralCharacteristic]

    package init(
        uuid: UUID,
        characteristics: [PeripheralCharacteristic],
    ) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}
