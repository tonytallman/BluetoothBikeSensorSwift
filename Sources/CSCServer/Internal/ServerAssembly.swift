internal import CSCWire

enum ServerAssembly {
    private static let maximumMultipleSensorLocations = 17 // 3 + 17 = 20 default-MTU payload bytes

    static func assemble(
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
    ) -> Server {
        precondition(wheel != nil || crankRevolutions != nil, "At least one revolution source is required")

        if case let .multiple(configuration) = location {
            let supported = configuration.supported
            let current = configuration.current
            precondition(!supported.isEmpty, "Multiple sensor locations require a non-empty supported list")
            precondition(
                Set(supported).count == supported.count,
                "Multiple sensor locations require unique supported entries",
            )
            precondition(
                supported.count <= maximumMultipleSensorLocations,
                "Multiple sensor locations support at most \(maximumMultipleSensorLocations) entries",
            )
            precondition(
                supported.contains(current),
                "Multiple sensor locations require current to be in supported",
            )
        }

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

        let service = PeripheralService(
            uuid: CSCS.serviceUUID,
            isPrimary: true,
            characteristics: characteristics,
        )

        return Server(
            feature: feature,
            service: service,
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }
}
