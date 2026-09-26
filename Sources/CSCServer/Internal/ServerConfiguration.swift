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

    var multipleLocations: MultipleSensorLocationsConfiguration? {
        if case let .multiple(configuration) = self {
            return configuration
        }
        return nil
    }
}

package struct ServerConfiguration: Sendable {
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    package let location: SensorLocationConfiguration
    package let feature: CSCFeature
    package let service: PeripheralService
    let includesControlPoint: Bool

    init(
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

        let includesControlPoint = wheel != nil || location.multipleLocations != nil

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
        self.includesControlPoint = includesControlPoint
        self.service = PeripheralService(
            uuid: CSCS.serviceUUID,
            characteristics: characteristics,
        )
    }
}
