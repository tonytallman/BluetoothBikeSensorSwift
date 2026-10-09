internal import CSCWire
import Foundation

/// Errors thrown by ``ConnectedSensor/disconnect()``.
///
/// An unexpected link loss does not throw. It finishes the measurement streams. Only an
/// explicit ``ConnectedSensor/disconnect()`` that fails throws.
public enum DisconnectError: Error, Sendable, Equatable {
    /// Disconnect failed for a reason other than the peripheral already being gone.
    ///
    /// `reason` is diagnostic text, not user-facing copy.
    case failed(reason: String)
    /// The central no longer has this peripheral. A peripheral that is already
    /// `.disconnected` but still known returns success instead of this case.
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
/// Created only by ``DiscoveredSensor/connect()``. Wheel, crank, and location support come from
/// CSC Feature (`0x2A5C`) read at connect time. Advertisement data is not a fallback. Set
/// ``WheelRevolutions/wheelCircumference`` before or during streaming so speed matches the wheel.
///
/// Releasing the instance finishes the measurement streams. It does not disconnect the radio —
/// ``deinit`` cannot await, so it only cancels the measurement task. Call ``disconnect()`` to
/// drop the link. An unexpected disconnect also finishes the streams and does not throw.
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

    /// Discovers CSCS, enables the notifications this sensor needs, then starts the measurement loop.
    ///
    /// Control-point indications are turned on before Request Supported Sensor Locations, because
    /// that procedure's result arrives as an indication. ``BluetoothCentral/events`` is subscribed
    /// before measurement notifications are enabled. The stream does not replay, and it buffers
    /// until the loop iterates, so a notification that arrives during the rest of setup is kept.
    ///
    /// A missing SC Control Point is allowed when the multiple-locations bit is clear. Set
    /// Cumulative Value then throws ``ControlPointError/controlPointUnavailable``. Multiple
    /// locations still require both Sensor Location and SC Control Point.
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
        } catch let error as BluetoothCentralError {
            throw BluetoothCentralConnectErrorMapping.connectError(from: error)
        } catch {
            throw ConnectError.serviceDiscoveryFailed(reason: "\(error)")
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

    /// Cancels the measurement loop so its streams finish. Does not disconnect; see the type
    /// comment.
    deinit {
        eventLoop.cancel()
    }

    /// Disconnects and returns the same ``DiscoveredSensor`` for a later ``DiscoveredSensor/connect()``.
    ///
    /// Cancels the measurement loop and finishes speed, cadence, and sample streams before
    /// touching the radio, so consumers unblock even if notify teardown is slow. Disabling
    /// notifications is best-effort: errors are ignored, and a peripheral that has already
    /// dropped fails that call immediately. If the central no longer knows the peripheral, this
    /// throws ``DisconnectError/alreadyDisconnected``. A peripheral that is already disconnected
    /// but still known is success.
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
            throw DisconnectError.failed(reason: "\(error)")
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

    /// Multiple-locations requires Sensor Location and SC Control Point, reads the current
    /// location, then Request Supported Sensor Locations. Connect fails if the current value is
    /// not in that supported list. Without the multiple-locations bit, a present Sensor Location
    /// characteristic is ``ResolvedLocation/fixed``; a missing one is ``ResolvedLocation/unavailable``.
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

    /// Runs the connect-time supported-locations procedure. ``ControlPointError`` is rewritten
    /// into ``ConnectError/serviceDiscoveryFailed`` so connect has one error type.
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
            throw ConnectError.serviceDiscoveryFailed(reason: "\(error)")
        }

        return response.parameter.map { SensorLocation(assignedNumber: $0) }
    }

    /// ``BluetoothCentralError/peripheralNotFound`` means the central already dropped the
    /// peripheral, which ``disconnect()`` reports as ``DisconnectError/alreadyDisconnected``.
    /// Every other central error becomes ``DisconnectError/failed(reason:)`` with diagnostic text.
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

    /// One task per connection. ``BluetoothCentral/events`` is shared by every peripheral on
    /// this central and by every in-flight control-point listener, so this loop keeps only this
    /// id's CSC Measurement values.
    ///
    /// An unexpected `.disconnected` for this id finishes the measurement streams and returns.
    /// Cancellation, from ``disconnect()`` or ``deinit``, does the same on the way out, including
    /// when the loop is parked waiting for the next event. ``disconnect()`` also finishes the
    /// streams itself; finishing twice is safe.
    private static func runMeasurementLoop(
        events: AsyncStream<CentralEvent>,
        id: UUID,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
    ) async {
        for await event in events {
            if Task.isCancelled {
                break
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

        if Task.isCancelled {
            if let wheelRevolutions {
                await wheelRevolutions.finishStreams()
            }
            if let crankRevolutions {
                await crankRevolutions.finishStreams()
            }
        }
    }

    /// Drops a payload that does not decode. Each present half is delivered to its
    /// ``WheelRevolutions`` or ``CrankRevolutions``; a combined notification can update one
    /// side, both, or neither, depending on which fields the payload carries and which sides
    /// this connection exposes.
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

/// Feature-bit names used at connect. Wheel support is the wheel-revolution bit; cadence is
/// the crank-revolution bit.
private extension CSCFeature {
    var hasSpeed: Bool { contains(.wheelRevolutionData) }
    var hasCadence: Bool { contains(.crankRevolutionData) }
    var hasMultipleSensorLocations: Bool { contains(.multipleSensorLocations) }
}
