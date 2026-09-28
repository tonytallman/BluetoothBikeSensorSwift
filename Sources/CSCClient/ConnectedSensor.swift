internal import CSCWire
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
    private let controlPoint: ControlPoint?
    private let controlPointIndicationsEnabled: Bool
    private let timeouts: Timeouts
    private let eventLoop: Task<Void, Never>

    private let wheelRevolutions: WheelRevolutions?
    private let crankRevolutions: CrankRevolutions?

    package init(
        id: UUID,
        name: String?,
        manufacturer: String?,
        revolutions: RevolutionData,
        location: LocationSupport,
        central: any BluetoothCentral,
        controlPoint: ControlPoint?,
        controlPointIndicationsEnabled: Bool,
        timeouts: Timeouts,
        centralEvents: AsyncStream<CentralEvent>,
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.revolutions = revolutions
        self.location = location
        self.central = central
        self.controlPoint = controlPoint
        self.controlPointIndicationsEnabled = controlPointIndicationsEnabled
        self.timeouts = timeouts

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

        let loopID = id
        let events = centralEvents
        eventLoop = Task {
            await Self.runMeasurementLoop(
                events: events,
                id: loopID,
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

        return DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: manufacturer,
            central: central,
            timeouts: timeouts,
        )
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
