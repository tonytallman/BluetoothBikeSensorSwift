import Foundation

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

    private let id: UUID
    private let name: String?
    private let manufacturer: String?
    private let central: any BluetoothCentral
    private let controlPointSession: CSCControlPointSession
    private let controlPointIndicationsEnabled: Bool
    private let loopOwner: MeasurementLoopOwner

    private let wheelRevolutions: WheelRevolutions?
    private let crankRevolutions: CrankRevolutions?

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        revolutions: RevolutionData,
        location: LocationSupport,
        central: any BluetoothCentral,
        controlPointSession: CSCControlPointSession,
        controlPointIndicationsEnabled: Bool,
        stateBox: MeasurementStateBox,
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.revolutions = revolutions
        self.location = location
        self.central = central
        self.controlPointSession = controlPointSession
        self.controlPointIndicationsEnabled = controlPointIndicationsEnabled

        switch revolutions {
        case let .wheel(wheel):
            wheelRevolutions = wheel
            crankRevolutions = nil
        case let .crank(crank):
            wheelRevolutions = nil
            crankRevolutions = crank
        case let .wheelAndCrank(wheel, crank):
            wheelRevolutions = wheel
            crankRevolutions = crank
        }

        loopOwner = MeasurementLoopOwner(
            central: central,
            id: id,
            wheelRevolutions: wheelRevolutions,
            crankRevolutions: crankRevolutions,
            stateBox: stateBox,
        )
    }

    deinit {
        loopOwner.cancel()
    }

    /// Disconnects from the sensor and returns a ``DiscoveredSensor`` for reconnection.
    public func disconnect() async throws -> DiscoveredSensor {
        loopOwner.cancel()
        await controlPointSession.cancel()
        await finishStreams()

        try? await central.setNotifyValue(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
            enabled: false,
        )

        if controlPointIndicationsEnabled {
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
            throw BluetoothCentralErrorMapping.disconnectError(from: error)
        } catch {
            throw DisconnectError.failed(reason: error.localizedDescription)
        }

        let (hasSpeed, hasCadence) = Self.capabilityFlags(for: revolutions)
        return DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: central,
        )
    }

    private static func capabilityFlags(for revolutions: RevolutionData) -> (hasSpeed: Bool, hasCadence: Bool) {
        switch revolutions {
        case .wheel:
            return (true, false)
        case .crank:
            return (false, true)
        case .wheelAndCrank:
            return (true, true)
        }
    }

    private func finishStreams() async {
        if let wheelRevolutions {
            await wheelRevolutions.finishStreams()
        }
        if let crankRevolutions {
            await crankRevolutions.finishStreams()
        }
    }

    private static func runMeasurementLoop(
        central: any BluetoothCentral,
        id: UUID,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
        stateBox: MeasurementStateBox,
    ) async {
        async let gattLoop: Void = consumeGATTEvents(
            central: central,
            id: id,
            wheelRevolutions: wheelRevolutions,
            crankRevolutions: crankRevolutions,
            stateBox: stateBox,
        )
        async let connectionLoop: Void = consumeConnectionEvents(
            central: central,
            id: id,
            wheelRevolutions: wheelRevolutions,
            crankRevolutions: crankRevolutions,
        )
        _ = await (gattLoop, connectionLoop)
    }

    private static func consumeGATTEvents(
        central: any BluetoothCentral,
        id: UUID,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
        stateBox: MeasurementStateBox,
    ) async {
        let gattEvents = await central.gattEvents
        for await event in gattEvents {
            guard !Task.isCancelled else {
                return
            }

            guard case let .characteristicValue(
                peripheralID,
                serviceUUID,
                characteristicUUID,
                value,
            ) = event,
                peripheralID == id,
                serviceUUID == CSCS.serviceUUID,
                characteristicUUID == CSCS.measurementUUID
            else {
                continue
            }

            await processMeasurement(
                value,
                wheelRevolutions: wheelRevolutions,
                crankRevolutions: crankRevolutions,
                stateBox: stateBox,
            )
        }
    }

    private static func consumeConnectionEvents(
        central: any BluetoothCentral,
        id: UUID,
        wheelRevolutions: WheelRevolutions?,
        crankRevolutions: CrankRevolutions?,
    ) async {
        let connectionEvents = await central.connectionEvents
        for await event in connectionEvents {
            guard !Task.isCancelled else {
                return
            }

            if case let .disconnected(peripheralID, _) = event, peripheralID == id {
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
        stateBox: MeasurementStateBox,
    ) async {
        guard let sample = CSCMeasurementParser.parse(data) else {
            return
        }

        let context = stateBox.readMeasurementContext()
        var state = context.state

        let wheelDelta = wheelRevolutions != nil
            ? CSCMeasurementParser.wheelDelta(
                from: sample,
                previous: &state,
                circumferenceMeters: context.circumferenceMeters,
            )
            : nil
        let crankDelta = crankRevolutions != nil
            ? CSCMeasurementParser.crankDelta(from: sample, previous: &state)
            : nil

        stateBox.writeMeasurementState(state)

        if let wheelDelta, let wheelRevolutions {
            let speed = CSCMeasurementParser.speed(
                from: wheelDelta,
                circumferenceMeters: context.circumferenceMeters,
            )
            await wheelRevolutions.yieldSpeed(speed)
            await wheelRevolutions.yieldWheelSample(
                WheelSample(
                    deltaDistance: Measurement(
                        value: Double(wheelDelta.deltaRevolutions) * context.circumferenceMeters,
                        unit: .meters,
                    ),
                    deltaTime: Measurement(value: wheelDelta.deltaTimeSeconds, unit: .seconds),
                ),
            )
        }

        if let crankDelta, let crankRevolutions {
            await crankRevolutions.yieldCadence(CSCMeasurementParser.cadence(from: crankDelta))
            await crankRevolutions.yieldCrankSample(
                CrankSample(
                    deltaRevolutions: Int(crankDelta.deltaRevolutions),
                    deltaTime: Measurement(value: crankDelta.deltaTimeSeconds, unit: .seconds),
                ),
            )
        }
    }

    private final class MeasurementLoopOwner: @unchecked Sendable {
        private let task: Task<Void, Never>

        init(
            central: any BluetoothCentral,
            id: UUID,
            wheelRevolutions: WheelRevolutions?,
            crankRevolutions: CrankRevolutions?,
            stateBox: MeasurementStateBox,
        ) {
            task = Task {
                await ConnectedSensor.runMeasurementLoop(
                    central: central,
                    id: id,
                    wheelRevolutions: wheelRevolutions,
                    crankRevolutions: crankRevolutions,
                    stateBox: stateBox,
                )
            }
        }

        func cancel() {
            task.cancel()
        }
    }
}
