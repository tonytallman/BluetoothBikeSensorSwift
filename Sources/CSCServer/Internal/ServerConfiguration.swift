import Foundation
package import CSCWire

package struct WheelConfiguration: Sendable {
    package let revolutions: AnyAsyncSequence<WheelRevolution>
    package let delegate: any CumulativeWheelRevolutionsDelegate
}

package struct MultipleSensorLocationsConfiguration: Sendable {
    package let supported: [SensorLocationKind]
    package let current: SensorLocationKind
    package let delegate: any MultipleSensorLocationsDelegate
}

package enum SensorLocationConfiguration: Sendable {
    case none
    case staticLocation(SensorLocationKind)
    case multiple(MultipleSensorLocationsConfiguration)
}

package struct ServerConfiguration: Sendable {
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    package let location: SensorLocationConfiguration
    package let feature: CSCFeature
    package let service: PeripheralService

    package init(
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: SensorLocationConfiguration,
    ) {
        precondition(wheel != nil || crankRevolutions != nil, "At least one revolution source is required")

        var feature: CSCFeature = []
        if wheel != nil {
            feature.insert(.wheelRevolutionData)
        }
        if crankRevolutions != nil {
            feature.insert(.crankRevolutionData)
        }
        if case .multiple = location {
            feature.insert(.multipleSensorLocations)
        }

        let encodedFeature = feature.encode()
        var characteristics: [PeripheralCharacteristic] = [
            PeripheralCharacteristic(
                uuid: CSCS.measurementUUID,
                properties: [.notify],
                permissions: [],
                value: nil,
            ),
            PeripheralCharacteristic(
                uuid: CSCS.featureUUID,
                properties: [.read],
                permissions: [.readable],
                value: encodedFeature,
            ),
        ]

        switch location {
        case .none:
            break
        case let .staticLocation(kind):
            let value = CSCSensorLocation(assignedNumber: kind.assignedNumber).encode()
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.sensorLocationUUID,
                    properties: [.read],
                    permissions: [.readable],
                    value: value,
                ),
            )
        case .multiple:
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.sensorLocationUUID,
                    properties: [.read],
                    permissions: [.readable],
                    value: nil,
                ),
            )
        }

        let includesControlPoint = wheel != nil || {
            if case .multiple = location {
                return true
            }
            return false
        }()

        if includesControlPoint {
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.controlPointUUID,
                    properties: [.write, .indicate],
                    permissions: [.writeable],
                    value: nil,
                ),
            )
        }

        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
        self.feature = feature
        self.service = PeripheralService(
            uuid: CSCS.serviceUUID,
            isPrimary: true,
            characteristics: characteristics,
        )
    }

    package var multipleLocations: MultipleSensorLocationsConfiguration? {
        if case let .multiple(configuration) = location {
            return configuration
        }
        return nil
    }

    package var includesControlPoint: Bool {
        wheel != nil || multipleLocations != nil
    }
}
