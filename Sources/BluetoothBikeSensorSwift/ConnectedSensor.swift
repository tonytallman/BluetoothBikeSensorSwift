import Foundation

/// A connected CSCS sensor emitting live speed and/or cadence measurements.
///
/// Created only by ``DiscoveredSensor/connect()``. Set ``wheelCircumference`` before or
/// during streaming so speed values reflect your wheel size. Streams finish when the
/// sensor disconnects unexpectedly; call ``disconnect()`` to release the connection.
public final class ConnectedSensor: Sendable {
    package static let defaultWheelCircumference = Measurement(value: 2.105, unit: UnitLength.meters)

    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var wheelCircumference: Measurement<UnitLength>
        var measurementState: CSCMeasurementState

        init(
            wheelCircumference: Measurement<UnitLength>,
            measurementState: CSCMeasurementState,
        ) {
            self.wheelCircumference = wheelCircumference
            self.measurementState = measurementState
        }

        func readMeasurementContext() -> (circumferenceMeters: Double, state: CSCMeasurementState) {
            lock.lock()
            defer { lock.unlock() }
            return (
                wheelCircumference.converted(to: .meters).value,
                measurementState,
            )
        }

        func writeMeasurementState(_ state: CSCMeasurementState) {
            lock.lock()
            measurementState = state
            lock.unlock()
        }
    }

    private let stateBox = StateBox(
        wheelCircumference: ConnectedSensor.defaultWheelCircumference,
        measurementState: CSCMeasurementState(),
    )

    private let speedBroadcaster = StreamBroadcaster<Speed>()
    private let cadenceBroadcaster = StreamBroadcaster<Cadence>()
    private let wheelSampleBroadcaster = StreamBroadcaster<WheelSample>()
    private let crankSampleBroadcaster = StreamBroadcaster<CrankSample>()

    private let id: UUID
    private let name: String?
    private let manufacturer: String?
    private let hasSpeed: Bool
    private let hasCadence: Bool
    private let central: any BluetoothCentral
    private let loopOwner: MeasurementLoopOwner

    /// Wheel circumference used for speed calculation. Client-managed; not persisted by the library.
    ///
    /// Default is 2.105 m (700×25C). Changes apply to subsequent speed calculations.
    public var wheelCircumference: Measurement<UnitLength> {
        get {
            stateBox.lock.lock()
            defer { stateBox.lock.unlock() }
            return stateBox.wheelCircumference
        }
        set {
            stateBox.lock.lock()
            stateBox.wheelCircumference = newValue
            stateBox.lock.unlock()
        }
    }

    /// Live speed stream, or `nil` when the sensor does not support wheel data.
    ///
    /// Emits ``Speed`` values while connected. The stream finishes on disconnect.
    public var speed: AsyncStream<Speed>? {
        get async {
            guard hasSpeed else {
                return nil
            }
            return await speedBroadcaster.makeStream()
        }
    }

    /// Live cadence stream, or `nil` when the sensor does not support crank data.
    ///
    /// Emits ``Cadence`` values in revolutions per minute while connected. The stream
    /// finishes on disconnect.
    public var cadence: AsyncStream<Cadence>? {
        get async {
            guard hasCadence else {
                return nil
            }
            return await cadenceBroadcaster.makeStream()
        }
    }

    /// Wheel delta-sample stream, or `nil` when the sensor does not support wheel data.
    ///
    /// Emits ``WheelSample`` values with distance and time deltas derived from CSC
    /// wheel event timestamps. The stream finishes on disconnect.
    public var wheelSamples: AsyncStream<WheelSample>? {
        get async {
            guard hasSpeed else {
                return nil
            }
            return await wheelSampleBroadcaster.makeStream()
        }
    }

    /// Crank delta-sample stream, or `nil` when the sensor does not support crank data.
    ///
    /// Emits ``CrankSample`` values with revolution and time deltas derived from CSC
    /// crank event timestamps. The stream finishes on disconnect.
    public var crankSamples: AsyncStream<CrankSample>? {
        get async {
            guard hasCadence else {
                return nil
            }
            return await crankSampleBroadcaster.makeStream()
        }
    }

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        hasSpeed: Bool,
        hasCadence: Bool,
        central: any BluetoothCentral,
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.hasSpeed = hasSpeed
        self.hasCadence = hasCadence
        self.central = central
        loopOwner = MeasurementLoopOwner(
            central: central,
            id: id,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            speedBroadcaster: speedBroadcaster,
            cadenceBroadcaster: cadenceBroadcaster,
            wheelSampleBroadcaster: wheelSampleBroadcaster,
            crankSampleBroadcaster: crankSampleBroadcaster,
            stateBox: stateBox,
        )
    }

    /// Disconnects from the sensor and returns a ``DiscoveredSensor`` for reconnection.
    ///
    /// - Returns: A rediscovered sensor representing the same peripheral.
    /// - Throws: ``DisconnectError`` when the disconnect operation fails.
    public func disconnect() async throws -> DiscoveredSensor {
        loopOwner.cancel()
        await finishStreams()

        try? await central.setNotifyValue(
            id: id,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.measurementUUID,
            enabled: false,
        )

        do {
            try await central.disconnect(id: id)
        } catch let error as BluetoothCentralError {
            throw BluetoothCentralErrorMapping.disconnectError(from: error)
        } catch {
            throw DisconnectError.failed(reason: error.localizedDescription)
        }

        return DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: central,
        )
    }

    private func finishStreams() async {
        await speedBroadcaster.finish()
        await cadenceBroadcaster.finish()
        await wheelSampleBroadcaster.finish()
        await crankSampleBroadcaster.finish()
    }

    private static func runMeasurementLoop(
        central: any BluetoothCentral,
        id: UUID,
        hasSpeed: Bool,
        hasCadence: Bool,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
        wheelSampleBroadcaster: StreamBroadcaster<WheelSample>,
        crankSampleBroadcaster: StreamBroadcaster<CrankSample>,
        stateBox: StateBox,
    ) async {
        async let gattLoop: Void = consumeGATTEvents(
            central: central,
            id: id,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            speedBroadcaster: speedBroadcaster,
            cadenceBroadcaster: cadenceBroadcaster,
            wheelSampleBroadcaster: wheelSampleBroadcaster,
            crankSampleBroadcaster: crankSampleBroadcaster,
            stateBox: stateBox,
        )
        async let connectionLoop: Void = consumeConnectionEvents(
            central: central,
            id: id,
            speedBroadcaster: speedBroadcaster,
            cadenceBroadcaster: cadenceBroadcaster,
            wheelSampleBroadcaster: wheelSampleBroadcaster,
            crankSampleBroadcaster: crankSampleBroadcaster,
        )
        _ = await (gattLoop, connectionLoop)
    }

    private static func consumeGATTEvents(
        central: any BluetoothCentral,
        id: UUID,
        hasSpeed: Bool,
        hasCadence: Bool,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
        wheelSampleBroadcaster: StreamBroadcaster<WheelSample>,
        crankSampleBroadcaster: StreamBroadcaster<CrankSample>,
        stateBox: StateBox,
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
                hasSpeed: hasSpeed,
                hasCadence: hasCadence,
                speedBroadcaster: speedBroadcaster,
                cadenceBroadcaster: cadenceBroadcaster,
                wheelSampleBroadcaster: wheelSampleBroadcaster,
                crankSampleBroadcaster: crankSampleBroadcaster,
                stateBox: stateBox,
            )
        }
    }

    private static func consumeConnectionEvents(
        central: any BluetoothCentral,
        id: UUID,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
        wheelSampleBroadcaster: StreamBroadcaster<WheelSample>,
        crankSampleBroadcaster: StreamBroadcaster<CrankSample>,
    ) async {
        let connectionEvents = await central.connectionEvents
        for await event in connectionEvents {
            guard !Task.isCancelled else {
                return
            }

            if case let .disconnected(peripheralID, _) = event, peripheralID == id {
                await speedBroadcaster.finish()
                await cadenceBroadcaster.finish()
                await wheelSampleBroadcaster.finish()
                await crankSampleBroadcaster.finish()
                return
            }
        }
    }

    private static func processMeasurement(
        _ data: Data,
        hasSpeed: Bool,
        hasCadence: Bool,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
        wheelSampleBroadcaster: StreamBroadcaster<WheelSample>,
        crankSampleBroadcaster: StreamBroadcaster<CrankSample>,
        stateBox: StateBox,
    ) async {
        guard let sample = CSCMeasurementParser.parse(data) else {
            return
        }

        let context = stateBox.readMeasurementContext()
        var state = context.state

        let wheelDelta = hasSpeed
            ? CSCMeasurementParser.wheelDelta(
                from: sample,
                previous: &state,
                circumferenceMeters: context.circumferenceMeters,
            )
            : nil
        let crankDelta = hasCadence
            ? CSCMeasurementParser.crankDelta(from: sample, previous: &state)
            : nil

        stateBox.writeMeasurementState(state)

        if let wheelDelta {
            let speed = CSCMeasurementParser.speed(
                from: wheelDelta,
                circumferenceMeters: context.circumferenceMeters,
            )
            await speedBroadcaster.yield(speed)
            await wheelSampleBroadcaster.yield(
                WheelSample(
                    deltaDistance: Measurement(
                        value: Double(wheelDelta.deltaRevolutions) * context.circumferenceMeters,
                        unit: .meters,
                    ),
                    deltaTime: Measurement(value: wheelDelta.deltaTimeSeconds, unit: .seconds),
                ),
            )
        }

        if let crankDelta {
            await cadenceBroadcaster.yield(CSCMeasurementParser.cadence(from: crankDelta))
            await crankSampleBroadcaster.yield(
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
            hasSpeed: Bool,
            hasCadence: Bool,
            speedBroadcaster: StreamBroadcaster<Speed>,
            cadenceBroadcaster: StreamBroadcaster<Cadence>,
            wheelSampleBroadcaster: StreamBroadcaster<WheelSample>,
            crankSampleBroadcaster: StreamBroadcaster<CrankSample>,
            stateBox: StateBox,
        ) {
            task = Task {
                await ConnectedSensor.runMeasurementLoop(
                    central: central,
                    id: id,
                    hasSpeed: hasSpeed,
                    hasCadence: hasCadence,
                    speedBroadcaster: speedBroadcaster,
                    cadenceBroadcaster: cadenceBroadcaster,
                    wheelSampleBroadcaster: wheelSampleBroadcaster,
                    crankSampleBroadcaster: crankSampleBroadcaster,
                    stateBox: stateBox,
                )
            }
        }

        func cancel() {
            task.cancel()
        }
    }
}
