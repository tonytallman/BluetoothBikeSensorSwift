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
    }

    private static func runMeasurementLoop(
        central: any BluetoothCentral,
        id: UUID,
        hasSpeed: Bool,
        hasCadence: Bool,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
        stateBox: StateBox,
    ) async {
        async let gattLoop: Void = consumeGATTEvents(
            central: central,
            id: id,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            speedBroadcaster: speedBroadcaster,
            cadenceBroadcaster: cadenceBroadcaster,
            stateBox: stateBox,
        )
        async let connectionLoop: Void = consumeConnectionEvents(
            central: central,
            id: id,
            speedBroadcaster: speedBroadcaster,
            cadenceBroadcaster: cadenceBroadcaster,
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
                stateBox: stateBox,
            )
        }
    }

    private static func consumeConnectionEvents(
        central: any BluetoothCentral,
        id: UUID,
        speedBroadcaster: StreamBroadcaster<Speed>,
        cadenceBroadcaster: StreamBroadcaster<Cadence>,
    ) async {
        let connectionEvents = await central.connectionEvents
        for await event in connectionEvents {
            guard !Task.isCancelled else {
                return
            }

            if case let .disconnected(peripheralID, _) = event, peripheralID == id {
                await speedBroadcaster.finish()
                await cadenceBroadcaster.finish()
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
        stateBox: StateBox,
    ) async {
        guard let sample = CSCMeasurementParser.parse(data) else {
            return
        }

        let context = stateBox.readMeasurementContext()
        var state = context.state

        var speedToYield: Speed?
        var cadenceToYield: Cadence?

        if hasSpeed,
           let speed = CSCMeasurementParser.speed(
               from: sample,
               previous: &state,
               circumferenceMeters: context.circumferenceMeters,
           ) {
            speedToYield = speed
        }

        if hasCadence,
           let cadence = CSCMeasurementParser.cadence(
               from: sample,
               previous: &state,
           ) {
            cadenceToYield = cadence
        }

        if let speedToYield {
            await speedBroadcaster.yield(speedToYield)
        }

        if let cadenceToYield {
            await cadenceBroadcaster.yield(cadenceToYield)
        }

        stateBox.writeMeasurementState(state)
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
                    stateBox: stateBox,
                )
            }
        }

        func cancel() {
            task.cancel()
        }
    }
}
