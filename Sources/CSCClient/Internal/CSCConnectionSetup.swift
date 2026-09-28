internal import CSCWire
import Foundation

package enum ResolvedRevolutions: Sendable {
    case wheel
    case crank
    case wheelAndCrank
}

package struct CSCConnectionResult: Sendable {
    package let revolutions: ResolvedRevolutions
    package let location: ResolvedLocation
    package let controlPointAvailable: Bool
    package let controlPoint: ControlPoint?
    package let centralEvents: AsyncStream<CentralEvent>
}

package enum ResolvedLocation: Sendable {
    case unavailable
    case fixed(SensorLocation)
    case multiple(supported: [SensorLocation], current: SensorLocation)
}

enum CSCConnectionSetup {
    static func prepare(
        central: any BluetoothCentral,
        id: UUID,
        controlPointProcedure: Duration,
    ) async throws -> CSCConnectionResult {
        let discovered = try await central.discoverCharacteristics(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUIDs: [
                CSCS.measurementUUID,
                CSCS.featureUUID,
                CSCS.sensorLocationUUID,
                CSCS.controlPointUUID,
            ],
        )

        let featureData: Data
        do {
            featureData = try await central.readValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
            )
        } catch {
            throw ConnectError.serviceDiscoveryFailed(reason: "CSC Feature read failed")
        }

        guard let feature = CSCFeature.decode(featureData) else {
            throw ConnectError.serviceDiscoveryFailed(reason: "Invalid CSC Feature value")
        }

        guard feature.hasSpeed || feature.hasCadence else {
            throw ConnectError.serviceDiscoveryFailed(reason: "Sensor supports neither wheel nor crank data")
        }

        let controlPointAvailable = discovered.contains(CSCS.controlPointUUID)
        let sensorLocationAvailable = discovered.contains(CSCS.sensorLocationUUID)

        var controlPoint: ControlPoint?
        if controlPointAvailable {
            try await central.setNotifyValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                enabled: true,
            )
            controlPoint = ControlPoint(
                central: central,
                peripheralID: id,
                timeout: controlPointProcedure,
            )
        }

        let location = try await resolveLocation(
            controlPoint: controlPoint,
            central: central,
            id: id,
            feature: feature,
            sensorLocationAvailable: sensorLocationAvailable,
            controlPointAvailable: controlPointAvailable,
        )

        let centralEvents = await central.events

        try await central.setNotifyValue(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
            enabled: true,
        )

        let revolutions: ResolvedRevolutions
        switch (feature.hasSpeed, feature.hasCadence) {
        case (true, true):
            revolutions = .wheelAndCrank
        case (true, false):
            revolutions = .wheel
        case (false, true):
            revolutions = .crank
        case (false, false):
            throw ConnectError.serviceDiscoveryFailed(reason: "Sensor supports neither wheel nor crank data")
        }

        return CSCConnectionResult(
            revolutions: revolutions,
            location: location,
            controlPointAvailable: controlPointAvailable,
            controlPoint: controlPoint,
            centralEvents: centralEvents,
        )
    }

    private static func resolveLocation(
        controlPoint: ControlPoint?,
        central: any BluetoothCentral,
        id: UUID,
        feature: CSCFeature,
        sensorLocationAvailable: Bool,
        controlPointAvailable: Bool,
    ) async throws -> ResolvedLocation {
        if feature.hasMultipleSensorLocations {
            guard sensorLocationAvailable else {
                throw ConnectError.serviceDiscoveryFailed(reason: "Sensor Location characteristic missing")
            }
            guard controlPointAvailable else {
                throw ConnectError.serviceDiscoveryFailed(reason: "SC Control Point characteristic missing")
            }

            let currentData = try await central.readValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.sensorLocationUUID,
            )
            guard let wireLocation = CSCSensorLocation.decode(currentData) else {
                throw ConnectError.serviceDiscoveryFailed(reason: "Invalid Sensor Location value")
            }
            let current = SensorLocation.fromAssignedNumber(wireLocation.assignedNumber)

            let supported = try await requestSupportedSensorLocations(
                controlPoint: controlPoint,
            )

            guard supported.contains(current) else {
                throw ConnectError.serviceDiscoveryFailed(reason: "Current sensor location is not supported")
            }

            return .multiple(supported: supported, current: current)
        }

        if sensorLocationAvailable {
            let locationData = try await central.readValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.sensorLocationUUID,
            )
            guard let wireLocation = CSCSensorLocation.decode(locationData) else {
                throw ConnectError.serviceDiscoveryFailed(reason: "Invalid Sensor Location value")
            }
            return .fixed(SensorLocation.fromAssignedNumber(wireLocation.assignedNumber))
        }

        return .unavailable
    }

    private static func requestSupportedSensorLocations(
        controlPoint: ControlPoint?,
    ) async throws -> [SensorLocation] {
        guard let controlPoint else {
            throw ConnectError.serviceDiscoveryFailed(reason: "SC Control Point characteristic missing")
        }

        let response: CSCControlPointResponse
        do {
            response = try await controlPoint.perform(.requestSupportedSensorLocations)
        } catch let error as ControlPointError {
            throw ConnectError.serviceDiscoveryFailed(reason: String(describing: error))
        } catch {
            throw ConnectError.serviceDiscoveryFailed(reason: error.localizedDescription)
        }

        guard let supported = CSCControlPointClient.supportedLocations(from: response) else {
            throw ConnectError.serviceDiscoveryFailed(reason: "Request Supported Sensor Locations failed")
        }
        return supported
    }
}
