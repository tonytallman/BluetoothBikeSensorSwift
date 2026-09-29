import Foundation
package import CSCWire

/// Pairs the wheel revolution source with the delegate that handles Set Cumulative Value.
package struct WheelConfiguration: Sendable {
    package let revolutions: AnyAsyncSequence<WheelRevolution>
    package let delegate: any CumulativeWheelRevolutionsDelegate
}

/// Snapshot of ``MultipleSensorLocationsDelegate/supported`` and `.current` taken once at
/// `build()`, paired with the delegate that handles Update Sensor Location.
package struct MultipleSensorLocationsConfiguration: Sendable {
    package let supported: [SensorLocationKind]
    package let current: SensorLocationKind
    package let delegate: any MultipleSensorLocationsDelegate
}

/// Build-time sensor-location configuration, fixed for the life of the `Server`.
package enum SensorLocationConfiguration: Sendable {
    case none
    /// Cached, read-only Sensor Location (`0x2A5D`) value; no SC Control Point involvement.
    case staticLocation(SensorLocationKind)
    /// Dynamic Sensor Location served from `ServedSensorLocationBox`, updated via SC Control
    /// Point's Update Sensor Location procedure.
    case multiple(MultipleSensorLocationsConfiguration)

    var multipleLocations: MultipleSensorLocationsConfiguration? {
        if case let .multiple(configuration) = self {
            return configuration
        }
        return nil
    }
}

/// The result of `ServerBuilder.build()`: computes CSC Feature bits and the fixed characteristic
/// inventory (order: Measurement, Feature, Sensor Location, Control Point) from the builder's
/// configuration. Everything here is fixed for the `Server`'s lifetime, including across
/// `stop()`/`start()` and Bluetooth recovery — to change shape, build a new `Server`.
package struct ServerConfiguration: Sendable {
    package let wheel: WheelConfiguration?
    package let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    package let location: SensorLocationConfiguration
    package let feature: CSCFeature
    package let service: PeripheralService
    /// GATT truth for the write gate in `ServerSession.handleWrite(_:)`, independent of
    /// `wheel != nil` (though currently derived from it, together with `location`).
    let includesControlPoint: Bool

    /// `ServerBuilder.build()` is only available for wheel-only, crank-only, or wheel-and-crank
    /// configurations. This `precondition` remains because the wheel/crank type-state markers are
    /// not stored on these optionals (e.g. the module-internal `ServerBuilder` initializer can still
    /// be called with both sources nil).
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

        // SC Control Point is included for Set Cumulative Value (needs wheel data) or Update /
        // Request Supported Sensor Locations (needs multiple locations) — CSCS 1.0 §3.4 / Table
        // 3.3. Crank-only and crank-plus-static builds omit it entirely.
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
