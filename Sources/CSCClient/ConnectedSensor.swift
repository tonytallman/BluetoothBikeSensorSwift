internal import CSCWire
import Foundation

/// Errors thrown by ``ConnectedSensor/disconnect()``.
public enum DisconnectError: Error, Sendable, Equatable {
    /// Disconnect failed for a reason other than already being disconnected.
    case failed(reason: String)
    /// The sensor was already disconnected.
    case alreadyDisconnected
}

/// Wheel and/or crank revolution support exposed by a connected sensor.
public enum RevolutionData: Sendable {
    case wheel(WheelRevolutions)
    case crank(CrankRevolutions)
    case wheelAndCrank(WheelRevolutions, CrankRevolutions)

    package var wheel: WheelRevolutions? {
        switch self {
        case let .wheel(wheel):
            wheel
        case let .wheelAndCrank(wheel, _):
            wheel
        case .crank:
            nil
        }
    }

    package var crank: CrankRevolutions? {
        switch self {
        case let .crank(crank):
            crank
        case let .wheelAndCrank(_, crank):
            crank
        case .wheel:
            nil
        }
    }
}

/// A connected CSCS sensor emitting live speed and/or cadence measurements.
///
/// Created only by ``DiscoveredSensor/connect()``. Set ``WheelRevolutions/wheelCircumference``
/// before or during streaming so speed values reflect your wheel size. Streams finish when the
/// sensor disconnects unexpectedly; call ``disconnect()`` to release the connection.
public final class ConnectedSensor: Sendable {
    /// Supported revolution data and live measurement streams.
    public let revolutions: RevolutionData

    /// Sensor location support for this connection.
    public let location: LocationSupport

    private let sensor: DiscoveredSensor
    private let central: any BluetoothCentral
    private let controlPoint: ControlPoint?
    private let eventLoop: Task<Void, Never>

    private let wheelRevolutions: WheelRevolutions?
    private let crankRevolutions: CrankRevolutions?

    init(connecting sensor: DiscoveredSensor) async throws {
        self.sensor = sensor
        central = sensor.central
        let id = sensor.id
        let timeouts = sensor.timeouts

        try await central.discoverServices(id: id, serviceUUIDs: [CSCS.serviceUUID])

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
                timeout: timeouts.controlPointProcedure,
            )
        }
        self.controlPoint = controlPoint

        let resolvedLocation = try await Self.resolveLocation(
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

        let revolutions: RevolutionData
        if feature.hasSpeed, feature.hasCadence {
            revolutions = .wheelAndCrank(
                WheelRevolutions(controlPoint: controlPoint),
                CrankRevolutions(),
            )
        } else if feature.hasSpeed {
            revolutions = .wheel(WheelRevolutions(controlPoint: controlPoint))
        } else {
            revolutions = .crank(CrankRevolutions())
        }
        self.revolutions = revolutions

        switch resolvedLocation {
        case .unavailable:
            location = .unavailable
        case let .fixed(sensorLocation):
            location = .fixed(sensorLocation)
        case let .multiple(supported, current):
            guard let controlPoint else {
                throw ConnectError.serviceDiscoveryFailed(reason: "SC Control Point characteristic missing")
            }
            location = .multiple(
                MultipleSensorLocations(
                    supported: supported,
                    current: current,
                    controlPoint: controlPoint,
                ),
            )
        }

        let loopWheel: WheelRevolutions?
        let loopCrank: CrankRevolutions?
        switch revolutions {
        case let .wheel(wheel):
            loopWheel = wheel
            loopCrank = nil
        case let .crank(crank):
            loopWheel = nil
            loopCrank = crank
        case let .wheelAndCrank(wheel, crank):
            loopWheel = wheel
            loopCrank = crank
        }
        wheelRevolutions = loopWheel
        crankRevolutions = loopCrank

        eventLoop = Task {
            await Self.runMeasurementLoop(
                events: centralEvents,
                id: id,
                wheelRevolutions: loopWheel,
                crankRevolutions: loopCrank,
            )
        }
    }

    deinit {
        eventLoop.cancel()
    }

    /// Disconnects from the sensor and returns a ``DiscoveredSensor`` for reconnection.
    public func disconnect() async throws -> DiscoveredSensor {
        eventLoop.cancel()
        await finishStreams()

        let id = sensor.id

        try? await central.setNotifyValue(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
            enabled: false,
        )

        if controlPoint != nil {
            try? await central.setNotifyValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                enabled: false,
            )
        }

        do {
            try await central.disconnect(id: id)
        } catch let error as BluetoothCentralError {
            throw Self.disconnectError(from: error)
        } catch {
            throw DisconnectError.failed(reason: error.localizedDescription)
        }

        return sensor
    }

    private func finishStreams() async {
        if let wheelRevolutions {
            await wheelRevolutions.finishStreams()
        }
        if let crankRevolutions {
            await crankRevolutions.finishStreams()
        }
    }

    private enum ResolvedLocation {
        case unavailable
        case fixed(SensorLocation)
        case multiple(supported: [SensorLocation], current: SensorLocation)
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
            let current = SensorLocation(assignedNumber: wireLocation.assignedNumber)

            let supported = try await requestSupportedSensorLocations(controlPoint: controlPoint)

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
            return .fixed(SensorLocation(assignedNumber: wireLocation.assignedNumber))
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

        return response.parameter.map { SensorLocation(assignedNumber: $0) }
    }

    private static func disconnectError(from error: BluetoothCentralError) -> DisconnectError {
        switch error {
        case .peripheralNotFound:
            return .alreadyDisconnected
        case let .disconnected(_, reason):
            return .failed(reason: reason ?? "Disconnected")
        case let .connectionFailed(_, reason):
            return .failed(reason: reason)
        case .notPoweredOn:
            return .failed(reason: "Bluetooth is not powered on")
        case let .serviceNotFound(_, serviceUUID):
            return .failed(reason: "Service not found: \(serviceUUID)")
        case let .characteristicNotFound(_, serviceUUID, characteristicUUID):
            return .failed(reason: "Characteristic not found: \(characteristicUUID) on \(serviceUUID)")
        case let .attApplicationError(code):
            return .failed(reason: "ATT error \(code)")
        }
    }

    private static func runMeasurementLoop(
        events: AsyncStream<CentralEvent>,
        id: UUID,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
    ) async {
        for await event in events {
            guard !Task.isCancelled else {
                return
            }

            switch event {
            case let .valueUpdated(peripheralID, serviceUUID, characteristicUUID, value):
                guard peripheralID == id,
                    serviceUUID == CSCS.serviceUUID,
                    characteristicUUID == CSCS.measurementUUID
                else {
                    continue
                }

                await processMeasurement(
                    value,
                    wheelRevolutions: wheelRevolutions,
                    crankRevolutions: crankRevolutions,
                )

            case let .disconnected(peripheralID):
                guard peripheralID == id else {
                    continue
                }

                if let wheelRevolutions {
                    await wheelRevolutions.finishStreams()
                }
                if let crankRevolutions {
                    await crankRevolutions.finishStreams()
                }
                return
            }
        }
    }

    private static func processMeasurement(
        _ data: Data,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
    ) async {
        guard let sample = CSCMeasurement.decode(data) else {
            return
        }

        if let wheelRevolutions,
           let revolutions = sample.cumulativeWheelRevolutions,
           let eventTime = sample.lastWheelEventTime
        {
            await wheelRevolutions.receive(revolutions: revolutions, eventTime: eventTime)
        }

        if let crankRevolutions,
           let revolutions = sample.cumulativeCrankRevolutions,
           let eventTime = sample.lastCrankEventTime
        {
            await crankRevolutions.receive(revolutions: revolutions, eventTime: eventTime)
        }
    }
}

private extension CSCFeature {
    var hasSpeed: Bool { contains(.wheelRevolutionData) }
    var hasCadence: Bool { contains(.crankRevolutionData) }
    var hasMultipleSensorLocations: Bool { contains(.multipleSensorLocations) }
}
