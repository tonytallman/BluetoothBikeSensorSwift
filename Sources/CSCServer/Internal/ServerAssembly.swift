internal import CSCWire

/// The only place that turns a completed builder configuration into a `Server`: computes CSC
/// Feature bits and the fixed characteristic inventory (order: Measurement, Feature, Sensor
/// Location, Control Point), re-validates the multiple-location invariants the builder already
/// checked (belt and suspenders for the internal `Server` initializer), and constructs the
/// `Server`. Everything decided here is fixed for the `Server`'s lifetime.
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

        // SC Control Point is included for Set Cumulative Value (needs wheel data) or Update /
        // Request Supported Sensor Locations (needs multiple locations) — CSCS 1.0 §3.4 / Table
        // 3.3. Crank-only and crank-plus-static builds omit it entirely.
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
